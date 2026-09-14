/* maludb_search.c — R1.1-13 C set-returning exact-vector-search with
 * a bounded top-K heap. Replaces the PL/pgSQL prototype in
 * exact_vector_search_sql which sorts every candidate before LIMIT.
 *
 * Same SQL signature; same result shape; faster on compartments above
 * a few hundred vectors. The PL/pgSQL prototype is retained under
 * exact_vector_search_plpgsql for cross-validation.
 *
 * Heap discipline: max-heap of size K keyed on `distance`. Root is
 * the WORST element among our current top-K. New candidate replaces
 * root iff its distance is strictly smaller; sift-down to restore.
 * After scan, sort the heap ascending by distance and emit via
 * tuplestore.
 *
 * Doctrine reminder (transcript §6 / §7): relational filter first.
 * Exact vector scoring second. Top-K heap third. The compartment scan
 * uses SPI; no global table walk.
 */

#include "postgres.h"
#include "maludb_varlena.h"
#include "fmgr.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/tuplestore.h"
#include "miscadmin.h"

#include <math.h>
#include <string.h>

#define MALUDB_VEC_BYTES_PER_ELEMENT 4
#define MALUDB_METRIC_COSINE   1
#define MALUDB_METRIC_L2       2
#define MALUDB_METRIC_INNER    3

typedef struct HeapEntry {
    int64  chunk_id;
    char  *source_text;       /* palloc'd in per_query_ctx */
    double distance;          /* lower = better; we keep K smallest */
    double similarity;
} HeapEntry;

/* Decode embedding BYTEA into float pointer + dim. Mirrors the helper
 * in src/maludb_vector.c. We don't share a header to keep the two
 * files independent. */
static inline int32
decode_vec(bytea *vb, const float **out)
{
    int32 len = VARSIZE_ANY_EXHDR(vb);
    if (len % MALUDB_VEC_BYTES_PER_ELEMENT != 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                 errmsg("vector bytea length %d not multiple of %d",
                        len, MALUDB_VEC_BYTES_PER_ELEMENT)));
    *out = (const float *) maludb_varlena_aligned(vb);
    return len / MALUDB_VEC_BYTES_PER_ELEMENT;
}

static inline double
compute_distance(int metric,
                 const float *a, int32 da,
                 const float *b, int32 db)
{
    if (da != db)
        ereport(ERROR,
                (errcode(ERRCODE_DATA_EXCEPTION),
                 errmsg("vector dim mismatch: %d vs %d", da, db)));
    if (metric == MALUDB_METRIC_L2) {
        double sum = 0.0;
        for (int32 i = 0; i < da; i++) {
            double d = (double) a[i] - (double) b[i];
            sum += d * d;
        }
        return sum;                                       /* squared L2 */
    } else {
        /* cosine and inner_product both rank by dot product on
         * normalized vectors. cosine_distance = 1 - dot;
         * inner_product "distance" = -dot (we negate so smaller
         * distance still means better match in the heap). */
        double dot = 0.0;
        for (int32 i = 0; i < da; i++)
            dot += (double) a[i] * (double) b[i];
        if (metric == MALUDB_METRIC_COSINE)
            return 1.0 - dot;
        return -dot;
    }
}

/* Max-heap of size K keyed on .distance. The root is heap[0] and is
 * the WORST element in our current top-K. Standard sift-up / sift-down
 * over a 0-indexed array. */
static inline void
heap_swap(HeapEntry *h, int i, int j)
{
    HeapEntry t = h[i];
    h[i] = h[j];
    h[j] = t;
}

static void
sift_up(HeapEntry *h, int i)
{
    while (i > 0) {
        int parent = (i - 1) / 2;
        if (h[i].distance > h[parent].distance) {
            heap_swap(h, i, parent);
            i = parent;
        } else break;
    }
}

static void
sift_down(HeapEntry *h, int n, int i)
{
    for (;;) {
        int l = 2 * i + 1, r = 2 * i + 2, m = i;
        if (l < n && h[l].distance > h[m].distance) m = l;
        if (r < n && h[r].distance > h[m].distance) m = r;
        if (m == i) break;
        heap_swap(h, i, m);
        i = m;
    }
}

static int
cmp_distance_asc(const void *a, const void *b)
{
    const HeapEntry *ea = (const HeapEntry *) a;
    const HeapEntry *eb = (const HeapEntry *) b;
    if (ea->distance < eb->distance) return -1;
    if (ea->distance > eb->distance) return  1;
    /* Tie-break on chunk_id for deterministic ordering. */
    if (ea->chunk_id  < eb->chunk_id)  return -1;
    if (ea->chunk_id  > eb->chunk_id)  return  1;
    return 0;
}

PG_FUNCTION_INFO_V1(maludb_exact_vector_search_c);
Datum
maludb_exact_vector_search_c(PG_FUNCTION_ARGS)
{
    int64        compartment_id = PG_GETARG_INT64(0);
    bytea       *qbytea         = PG_GETARG_BYTEA_PP(1);
    int32        k              = PG_GETARG_INT32(2);
    text        *metric_arg     = PG_ARGISNULL(3) ? NULL : PG_GETARG_TEXT_PP(3);
    const float *qvec;
    int32        qdim           = decode_vec(qbytea, &qvec);
    int          metric         = MALUDB_METRIC_COSINE;
    HeapEntry   *heap;
    int          heap_n         = 0;
    int          ret;
    int64        compartment_arg;

    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc       tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext   per_query_ctx;
    MemoryContext   oldctx;

    if (k <= 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("limit must be positive")));

    if (metric_arg) {
        const char *m = text_to_cstring(metric_arg);
        if (strcmp(m, "cosine")        == 0) metric = MALUDB_METRIC_COSINE;
        else if (strcmp(m, "l2")       == 0) metric = MALUDB_METRIC_L2;
        else if (strcmp(m, "inner_product") == 0) metric = MALUDB_METRIC_INNER;
        else
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("unknown distance metric: %s", m)));
    }

    if (!rsinfo || !(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept materialized set")));

    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("function returning record called without column definitions")));

    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldctx        = MemoryContextSwitchTo(per_query_ctx);
    tupdesc       = CreateTupleDescCopy(tupdesc);
    tupstore      = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tupstore;
    rsinfo->setDesc    = tupdesc;
    MemoryContextSwitchTo(oldctx);

    /* SPI scan of all chunks in the compartment. We hold the rows in
     * the SPI memory context until heap selection is done; HeapEntry
     * keeps a copy of source_text in the per-query context. */
    if ((ret = SPI_connect()) != SPI_OK_CONNECT)
        ereport(ERROR,
                (errmsg("SPI_connect failed: %d", ret)));

    {
        const char *q =
            "SELECT c.chunk_id, c.source_text, c.embedding "
            "FROM maludb_core.malu$vector_chunk c "
            "WHERE c.compartment_id = $1";
        Oid     argtypes[1] = { INT8OID };
        Datum   args[1];

        compartment_arg = compartment_id;
        args[0] = Int64GetDatum(compartment_arg);

        ret = SPI_execute_with_args(q, 1, argtypes, args, NULL, true, 0);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR,
                    (errmsg("SPI scan failed: %d", ret)));
    }

    {
        uint64 nrows = SPI_processed;
        int    cap   = (k < (int) nrows) ? k : (int) nrows;
        if (cap < 0) cap = 0;
        oldctx = MemoryContextSwitchTo(per_query_ctx);
        heap = palloc0(sizeof(HeapEntry) * (cap > 0 ? cap : 1));
        MemoryContextSwitchTo(oldctx);

        for (uint64 i = 0; i < nrows; i++) {
            HeapTuple   row     = SPI_tuptable->vals[i];
            TupleDesc   spidesc = SPI_tuptable->tupdesc;
            bool        isnull;
            Datum       d_id    = SPI_getbinval(row, spidesc, 1, &isnull);
            int64       chunk_id = isnull ? 0 : DatumGetInt64(d_id);
            char       *txt     = SPI_getvalue(row, spidesc, 2);
            Datum       d_emb   = SPI_getbinval(row, spidesc, 3, &isnull);
            bytea      *eb;
            const float *evec;
            int32        edim;
            double       dist, sim;

            if (isnull) continue;
            eb = DatumGetByteaPP(d_emb);
            edim = decode_vec(eb, &evec);
            dist = compute_distance(metric, qvec, qdim, evec, edim);
            switch (metric) {
                case MALUDB_METRIC_COSINE: sim = 1.0 - dist; break;
                case MALUDB_METRIC_L2:     sim = -dist;      break;
                default:                   sim = -dist;      break;
            }

            if (heap_n < k) {
                /* Heap not yet full — insert + sift_up. Keep a copy
                 * of source_text in the per-query context (which is
                 * what tuplestore_putvalues will outlive into). */
                MemoryContext save = MemoryContextSwitchTo(per_query_ctx);
                heap[heap_n].chunk_id    = chunk_id;
                heap[heap_n].source_text = txt ? pstrdup(txt) : NULL;
                heap[heap_n].distance    = dist;
                heap[heap_n].similarity  = sim;
                MemoryContextSwitchTo(save);
                sift_up(heap, heap_n);
                heap_n++;
            } else if (dist < heap[0].distance) {
                /* Replace root + sift_down. */
                MemoryContext save = MemoryContextSwitchTo(per_query_ctx);
                if (heap[0].source_text) pfree(heap[0].source_text);
                heap[0].chunk_id    = chunk_id;
                heap[0].source_text = txt ? pstrdup(txt) : NULL;
                heap[0].distance    = dist;
                heap[0].similarity  = sim;
                MemoryContextSwitchTo(save);
                sift_down(heap, heap_n, 0);
            }
            if (txt) pfree(txt);
            CHECK_FOR_INTERRUPTS();
        }
    }

    SPI_finish();

    /* Sort heap ascending by distance (best first) and emit. */
    qsort(heap, heap_n, sizeof(HeapEntry), cmp_distance_asc);

    {
        Datum  values[5];
        bool   nulls[5]   = { false, false, false, false, false };

        for (int i = 0; i < heap_n; i++) {
            values[0] = Int64GetDatum(heap[i].chunk_id);
            if (heap[i].source_text) {
                values[1] = CStringGetTextDatum(heap[i].source_text);
                nulls[1]  = false;
            } else {
                values[1] = (Datum) 0;
                nulls[1]  = true;
            }
            values[2] = Float8GetDatum(heap[i].distance);
            values[3] = Float8GetDatum(heap[i].similarity);
            values[4] = Int32GetDatum(i + 1);
            tuplestore_putvalues(tupstore, tupdesc, values, nulls);
        }
    }

    return (Datum) 0;
}
