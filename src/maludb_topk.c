/* maludb_topk.c — R1.1-15 parallel-safe top-K vector aggregate.
 *
 * Exposed as the SQL aggregate topk_vector_search(...). PG's parallel
 * sequential scan splits malu$vector_chunk across worker backends,
 * each maintains its own top-K max-heap, the COMBINEFUNC merges
 * worker heaps into the leader, and FINALFUNC emits the top-K as
 * an array of malu$topk_result composites.
 *
 * State lives in the aggregate's memory context as a TopKState
 * (INTERNAL type). Workers serialize via topk_serialize → bytea on
 * hand-back; the leader deserializes via topk_deserialize. Per-row
 * cost: one heap update (O(log K)). Total: O(N log K) work,
 * parallelized across workers.
 *
 * Doctrine (transcript §6 / §7): relational filter first. Exact
 * scoring second. Top-K heap third. The aggregate operates ONLY on
 * rows the planner has already filtered (typically
 * compartment_id = $1).
 */

#include "postgres.h"
#include "maludb_varlena.h"
#include "fmgr.h"
#include "funcapi.h"
#include "libpq/pqformat.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/bytea.h"
#include "utils/jsonb.h"
#include "utils/json.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/typcache.h"
#include "miscadmin.h"

#include <math.h>
#include <string.h>

#define MALUDB_VEC_BYTES_PER_ELEMENT 4
#define MALUDB_METRIC_COSINE   1
#define MALUDB_METRIC_L2       2
#define MALUDB_METRIC_INNER    3

typedef struct HeapEntry {
    int64  chunk_id;
    char  *source_text;       /* palloc'd in state->mcxt */
    int    source_len;
    double distance;
    double similarity;
} HeapEntry;

typedef struct TopKState {
    int            capacity;        /* K */
    int            n;                /* current count */
    int            metric;
    int32          qdim;             /* dimension of normalized query */
    float         *qvec;             /* palloc'd in state->mcxt; cached after first sfunc */
    HeapEntry     *heap;             /* palloc0(sizeof(HeapEntry) * capacity) */
    MemoryContext  mcxt;             /* state's owning memory context */
} TopKState;

/* Decode varlena into float pointer + dim. */
static inline int32
decode_vec(bytea *vb, const float **out)
{
    int32 len = VARSIZE_ANY_EXHDR(vb);
    if (len % MALUDB_VEC_BYTES_PER_ELEMENT != 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                 errmsg("vector length %d not multiple of %d",
                        len, MALUDB_VEC_BYTES_PER_ELEMENT)));
    *out = (const float *) maludb_varlena_aligned(vb);
    return len / MALUDB_VEC_BYTES_PER_ELEMENT;
}

static inline double
compute_distance(int metric, const float *a, int32 da,
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
        return sum;
    } else {
        double dot = 0.0;
        for (int32 i = 0; i < da; i++)
            dot += (double) a[i] * (double) b[i];
        if (metric == MALUDB_METRIC_COSINE) return 1.0 - dot;
        return -dot;
    }
}

static inline void
heap_swap(HeapEntry *h, int i, int j)
{
    HeapEntry t = h[i]; h[i] = h[j]; h[j] = t;
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
    if (ea->chunk_id  < eb->chunk_id)  return -1;
    if (ea->chunk_id  > eb->chunk_id)  return  1;
    return 0;
}

static int
parse_metric(const char *m)
{
    if (strcmp(m, "cosine")        == 0) return MALUDB_METRIC_COSINE;
    if (strcmp(m, "l2")            == 0) return MALUDB_METRIC_L2;
    if (strcmp(m, "inner_product") == 0) return MALUDB_METRIC_INNER;
    ereport(ERROR,
            (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
             errmsg("unknown distance metric: %s", m)));
    return MALUDB_METRIC_COSINE;        /* unreachable */
}

/* Convert a malu_vector (binary-compat with bytea) to a private copy
 * of float32 in the state's memory context. */
static void
state_set_query(TopKState *state, bytea *qb)
{
    MemoryContext  save = MemoryContextSwitchTo(state->mcxt);
    const float   *src;
    int32          dim = decode_vec(qb, &src);
    state->qdim = dim;
    state->qvec = (float *) palloc(sizeof(float) * dim);
    memcpy(state->qvec, src, sizeof(float) * dim);
    MemoryContextSwitchTo(save);
}

static TopKState *
state_new(MemoryContext mcxt, int k, int metric)
{
    MemoryContext  save = MemoryContextSwitchTo(mcxt);
    TopKState     *state = (TopKState *) palloc0(sizeof(TopKState));
    state->capacity     = k;
    state->n            = 0;
    state->metric       = metric;
    state->qdim         = 0;
    state->qvec         = NULL;
    state->heap         = (HeapEntry *) palloc0(sizeof(HeapEntry) * (k > 0 ? k : 1));
    state->mcxt         = mcxt;
    MemoryContextSwitchTo(save);
    return state;
}

static void
state_offer(TopKState *state, int64 chunk_id, const char *txt, int txt_len,
            double dist, double sim)
{
    if (state->n < state->capacity) {
        MemoryContext save = MemoryContextSwitchTo(state->mcxt);
        state->heap[state->n].chunk_id   = chunk_id;
        if (txt && txt_len > 0) {
            state->heap[state->n].source_text = (char *) palloc(txt_len + 1);
            memcpy(state->heap[state->n].source_text, txt, txt_len);
            state->heap[state->n].source_text[txt_len] = '\0';
            state->heap[state->n].source_len = txt_len;
        } else {
            state->heap[state->n].source_text = NULL;
            state->heap[state->n].source_len  = 0;
        }
        state->heap[state->n].distance   = dist;
        state->heap[state->n].similarity = sim;
        MemoryContextSwitchTo(save);
        sift_up(state->heap, state->n);
        state->n++;
    } else if (state->capacity > 0 && dist < state->heap[0].distance) {
        MemoryContext save = MemoryContextSwitchTo(state->mcxt);
        if (state->heap[0].source_text) pfree(state->heap[0].source_text);
        state->heap[0].chunk_id   = chunk_id;
        if (txt && txt_len > 0) {
            state->heap[0].source_text = (char *) palloc(txt_len + 1);
            memcpy(state->heap[0].source_text, txt, txt_len);
            state->heap[0].source_text[txt_len] = '\0';
            state->heap[0].source_len = txt_len;
        } else {
            state->heap[0].source_text = NULL;
            state->heap[0].source_len  = 0;
        }
        state->heap[0].distance   = dist;
        state->heap[0].similarity = sim;
        MemoryContextSwitchTo(save);
        sift_down(state->heap, state->n, 0);
    }
}

/* ---------------------------------------------------------------------
 * topk_vector_sfunc(state, embedding, chunk_id, source_text,
 *                   query, k, metric)
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_topk_vector_sfunc);
Datum
maludb_topk_vector_sfunc(PG_FUNCTION_ARGS)
{
    MemoryContext   agg_cxt;
    TopKState      *state;
    bytea          *emb;
    int64           chunk_id;
    text           *src_txt;
    bytea          *q;
    int32           k;
    text           *metric_txt;
    const char     *src_str;
    int             src_len;
    const float    *evec;
    int32           edim;
    double          dist, sim;

    if (!AggCheckCallContext(fcinfo, &agg_cxt))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("topk_vector_sfunc called outside aggregate context")));

    if (PG_ARGISNULL(1) || PG_ARGISNULL(2) || PG_ARGISNULL(4)
        || PG_ARGISNULL(5) || PG_ARGISNULL(6)) {
        /* Drop rows where required fields are NULL. Return state unchanged. */
        if (PG_ARGISNULL(0)) PG_RETURN_NULL();
        PG_RETURN_POINTER(PG_GETARG_POINTER(0));
    }

    if (PG_ARGISNULL(0)) {
        k = PG_GETARG_INT32(5);
        metric_txt = PG_GETARG_TEXT_PP(6);
        if (k <= 0)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                     errmsg("topk_vector_search: limit must be positive")));
        state = state_new(agg_cxt, k, parse_metric(text_to_cstring(metric_txt)));
        q = PG_GETARG_BYTEA_PP(4);
        state_set_query(state, q);
    } else {
        state = (TopKState *) PG_GETARG_POINTER(0);
    }

    emb      = PG_GETARG_BYTEA_PP(1);
    chunk_id = PG_GETARG_INT64(2);
    src_txt  = PG_ARGISNULL(3) ? NULL : PG_GETARG_TEXT_PP(3);

    if (src_txt) {
        src_str = VARDATA_ANY(src_txt);
        src_len = VARSIZE_ANY_EXHDR(src_txt);
    } else {
        src_str = NULL;
        src_len = 0;
    }

    edim = decode_vec(emb, &evec);
    dist = compute_distance(state->metric, state->qvec, state->qdim, evec, edim);
    switch (state->metric) {
        case MALUDB_METRIC_COSINE: sim = 1.0 - dist; break;
        case MALUDB_METRIC_L2:     sim = -dist;      break;
        default:                   sim = -dist;      break;
    }
    state_offer(state, chunk_id, src_str, src_len, dist, sim);
    CHECK_FOR_INTERRUPTS();
    PG_RETURN_POINTER(state);
}

/* ---------------------------------------------------------------------
 * topk_vector_combine(a, b) — merge two worker states into the leader.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_topk_vector_combine);
Datum
maludb_topk_vector_combine(PG_FUNCTION_ARGS)
{
    MemoryContext  agg_cxt;
    TopKState     *a, *b;

    if (!AggCheckCallContext(fcinfo, &agg_cxt))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("topk_vector_combine called outside aggregate context")));

    if (PG_ARGISNULL(0) && PG_ARGISNULL(1)) PG_RETURN_NULL();
    if (PG_ARGISNULL(0)) PG_RETURN_POINTER(PG_GETARG_POINTER(1));
    if (PG_ARGISNULL(1)) PG_RETURN_POINTER(PG_GETARG_POINTER(0));

    a = (TopKState *) PG_GETARG_POINTER(0);
    b = (TopKState *) PG_GETARG_POINTER(1);

    /* Offer every entry of b into a's heap. */
    for (int i = 0; i < b->n; i++) {
        state_offer(a, b->heap[i].chunk_id,
                    b->heap[i].source_text, b->heap[i].source_len,
                    b->heap[i].distance, b->heap[i].similarity);
    }
    PG_RETURN_POINTER(a);
}

/* ---------------------------------------------------------------------
 * topk_vector_serialize: TopKState* → bytea (sent to leader)
 *
 * Layout:
 *   int32 capacity
 *   int32 n
 *   int32 metric
 *   int32 qdim
 *   float[qdim] qvec
 *   for i in 0..n:
 *       int64 chunk_id
 *       float8 distance
 *       float8 similarity
 *       int32 source_len
 *       char[source_len] source_text
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_topk_vector_serialize);
Datum
maludb_topk_vector_serialize(PG_FUNCTION_ARGS)
{
    TopKState      *state;
    StringInfoData  buf;

    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("topk_vector_serialize: NULL state")));

    state = (TopKState *) PG_GETARG_POINTER(0);
    pq_begintypsend(&buf);
    pq_sendint32(&buf, state->capacity);
    pq_sendint32(&buf, state->n);
    pq_sendint32(&buf, state->metric);
    pq_sendint32(&buf, state->qdim);
    if (state->qdim > 0 && state->qvec)
        pq_sendbytes(&buf, (const char *) state->qvec,
                     state->qdim * sizeof(float));
    for (int i = 0; i < state->n; i++) {
        pq_sendint64(&buf, state->heap[i].chunk_id);
        pq_sendfloat8(&buf, state->heap[i].distance);
        pq_sendfloat8(&buf, state->heap[i].similarity);
        pq_sendint32(&buf, state->heap[i].source_len);
        if (state->heap[i].source_len > 0)
            pq_sendbytes(&buf, state->heap[i].source_text,
                         state->heap[i].source_len);
    }
    PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}

/* ---------------------------------------------------------------------
 * topk_vector_deserialize(b, dummy): bytea → TopKState*
 * Dummy second arg is the PG convention for deserial functions.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_topk_vector_deserialize);
Datum
maludb_topk_vector_deserialize(PG_FUNCTION_ARGS)
{
    MemoryContext   agg_cxt;
    StringInfoData  buf;
    bytea          *sbytes;
    TopKState      *state;
    int             k, n, metric;
    int32           qdim;

    if (!AggCheckCallContext(fcinfo, &agg_cxt))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("topk_vector_deserialize called outside aggregate context")));
    if (PG_ARGISNULL(0))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("topk_vector_deserialize: NULL bytea")));

    sbytes = PG_GETARG_BYTEA_PP(0);
    initStringInfo(&buf);
    appendBinaryStringInfo(&buf, VARDATA_ANY(sbytes), VARSIZE_ANY_EXHDR(sbytes));

    k      = pq_getmsgint(&buf, 4);
    n      = pq_getmsgint(&buf, 4);
    metric = pq_getmsgint(&buf, 4);
    qdim   = pq_getmsgint(&buf, 4);
    state  = state_new(agg_cxt, k, metric);
    state->n    = n;
    state->qdim = qdim;
    if (qdim > 0) {
        MemoryContext save = MemoryContextSwitchTo(agg_cxt);
        state->qvec = (float *) palloc(sizeof(float) * qdim);
        MemoryContextSwitchTo(save);
        pq_copymsgbytes(&buf, (char *) state->qvec, qdim * sizeof(float));
    }
    for (int i = 0; i < n; i++) {
        int slen;
        state->heap[i].chunk_id   = pq_getmsgint64(&buf);
        state->heap[i].distance   = pq_getmsgfloat8(&buf);
        state->heap[i].similarity = pq_getmsgfloat8(&buf);
        slen = pq_getmsgint(&buf, 4);
        state->heap[i].source_len = slen;
        if (slen > 0) {
            MemoryContext save = MemoryContextSwitchTo(agg_cxt);
            state->heap[i].source_text = (char *) palloc(slen + 1);
            MemoryContextSwitchTo(save);
            pq_copymsgbytes(&buf, state->heap[i].source_text, slen);
            state->heap[i].source_text[slen] = '\0';
        } else {
            state->heap[i].source_text = NULL;
        }
    }
    pq_getmsgend(&buf);
    PG_RETURN_POINTER(state);
}

/* ---------------------------------------------------------------------
 * topk_vector_finalize(state) → jsonb
 *
 * Returns a JSON array of top-K entries, sorted by distance ascending:
 *   [
 *     {"chunk_id":1, "source_text":"...", "distance":0.1,
 *      "similarity":0.9, "rank_no":1},
 *     ...
 *   ]
 *
 * The SQL wrapper exact_vector_search_parallel_c() fans this out into
 * a SETOF row via jsonb_array_elements + ->> casts. Keeping the
 * composite-type assembly out of C avoids the tupledesc lookup dance
 * for what is just a structured-data return.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_topk_vector_finalize);
Datum
maludb_topk_vector_finalize(PG_FUNCTION_ARGS)
{
    TopKState      *state;
    StringInfoData  buf;

    if (PG_ARGISNULL(0)) PG_RETURN_NULL();
    state = (TopKState *) PG_GETARG_POINTER(0);

    /* Sort heap ascending by distance. */
    qsort(state->heap, state->n, sizeof(HeapEntry), cmp_distance_asc);

    initStringInfo(&buf);
    appendStringInfoChar(&buf, '[');
    for (int i = 0; i < state->n; i++) {
        if (i > 0) appendStringInfoChar(&buf, ',');
        appendStringInfoChar(&buf, '{');
        appendStringInfo(&buf,
                         "\"chunk_id\":%lld,\"distance\":%.17g,\"similarity\":%.17g,\"rank_no\":%d",
                         (long long) state->heap[i].chunk_id,
                         state->heap[i].distance,
                         state->heap[i].similarity,
                         i + 1);
        if (state->heap[i].source_text) {
            appendStringInfoString(&buf, ",\"source_text\":");
            escape_json(&buf, state->heap[i].source_text);
        } else {
            appendStringInfoString(&buf, ",\"source_text\":null");
        }
        appendStringInfoChar(&buf, '}');
    }
    appendStringInfoChar(&buf, ']');

    PG_RETURN_DATUM(DirectFunctionCall1(jsonb_in,
                    CStringGetDatum(buf.data)));
}
