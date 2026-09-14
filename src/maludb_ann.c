/* maludb_ann.c — R1.1-16 local ANN per compartment.
 *
 * Single-layer NSW (Navigable Small-World) graph stored as one BYTEA
 * blob per compartment. Build is a single-pass insertion: for each new
 * node, find ef_construction nearest existing nodes via greedy search,
 * take top-M as bidirectional edges, evict the worst edge on any
 * over-full neighbor.
 *
 * Search is a greedy + beam search with ef_search candidates. The PG
 * SQL wrapper merges these with exact-search over malu$ann_delta and
 * filters out tombstones — that part lives in the migration's
 * exact_vector_search_sql dispatcher.
 *
 * Blob layout (all integers little-endian, host-order is x86_64/aarch64
 * little-endian for the Ubuntu 24.04 target):
 *
 *   header (32 bytes):
 *     magic[4]       "ANN1"
 *     metric         int32 (1=cosine, 2=l2, 3=inner_product)
 *     dim            int32
 *     m              int32
 *     ef_construct   int32
 *     n_nodes        int32
 *     entry_node     int32
 *     reserved       int32
 *
 *   chunk_ids       n_nodes × int64 = 8 bytes/node
 *   edges           n_nodes × m × int32 = 4m bytes/node (-1 = unused)
 *   embeddings      n_nodes × dim × float32 = 4*dim bytes/node
 *
 * Total size: 32 + n_nodes × (8 + 4m + 4*dim).
 */

#include "postgres.h"
#include "maludb_varlena.h"
#include "fmgr.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/bytea.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/tuplestore.h"
#include "miscadmin.h"

#include <math.h>
#include <string.h>
#include <stdlib.h>

#define ANN_HEADER_BYTES 32
#define ANN_MAGIC        "ANN1"
#define ANN_VEC_F32      4

#define ANN_METRIC_COSINE 1
#define ANN_METRIC_L2     2
#define ANN_METRIC_INNER  3

#define EDGE_NONE (-1)

/* ---------- distance ----------------------------------------------- */

static inline double
ann_distance(int metric, const float *a, const float *b, int32 dim)
{
    if (metric == ANN_METRIC_L2) {
        double s = 0.0;
        for (int32 i = 0; i < dim; i++) {
            double d = (double) a[i] - (double) b[i];
            s += d * d;
        }
        return s;
    } else {
        double dot = 0.0;
        for (int32 i = 0; i < dim; i++)
            dot += (double) a[i] * (double) b[i];
        if (metric == ANN_METRIC_COSINE) return 1.0 - dot;
        return -dot;          /* inner: smaller distance = larger dot */
    }
}

static int
ann_parse_metric(const char *m)
{
    if (strcmp(m, "cosine")        == 0) return ANN_METRIC_COSINE;
    if (strcmp(m, "l2")            == 0) return ANN_METRIC_L2;
    if (strcmp(m, "inner_product") == 0) return ANN_METRIC_INNER;
    ereport(ERROR,
            (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
             errmsg("unknown distance metric: %s", m)));
    return ANN_METRIC_COSINE;     /* unreachable */
}

/* ---------- in-memory graph representation ------------------------- */

typedef struct AnnGraph {
    int32   metric;
    int32   dim;
    int32   m;
    int32   ef_construct;
    int32   n_nodes;
    int32   entry_node;
    int64  *chunk_ids;        /* [n_nodes] */
    int32  *edges;            /* [n_nodes * m]; -1 = unused */
    float  *embeddings;       /* [n_nodes * dim] */
    /* working storage used during build only */
    double *edge_dists;       /* [n_nodes * m]; parallel to edges */
} AnnGraph;

static inline const float *
ann_emb(const AnnGraph *g, int32 i)
{
    return g->embeddings + (size_t) i * g->dim;
}

static inline int32 *
ann_edges(const AnnGraph *g, int32 i)
{
    return g->edges + (size_t) i * g->m;
}

static inline double *
ann_edge_dists(const AnnGraph *g, int32 i)
{
    return g->edge_dists + (size_t) i * g->m;
}

/* ---------- candidate queues --------------------------------------- */

typedef struct CandEntry {
    int32  idx;
    double dist;
} CandEntry;

/* Min-heap (smallest distance at root) — used for the "candidates to
 * expand" queue. */
static void
minheap_push(CandEntry *h, int *n, CandEntry e)
{
    int i = (*n)++;
    h[i] = e;
    while (i > 0) {
        int parent = (i - 1) / 2;
        if (h[i].dist < h[parent].dist) {
            CandEntry t = h[i]; h[i] = h[parent]; h[parent] = t;
            i = parent;
        } else break;
    }
}

static CandEntry
minheap_pop(CandEntry *h, int *n)
{
    CandEntry top = h[0];
    int last = --(*n);
    h[0] = h[last];
    int i = 0;
    for (;;) {
        int l = 2 * i + 1, r = 2 * i + 2, m = i;
        if (l < last && h[l].dist < h[m].dist) m = l;
        if (r < last && h[r].dist < h[m].dist) m = r;
        if (m == i) break;
        CandEntry t = h[i]; h[i] = h[m]; h[m] = t;
        i = m;
    }
    return top;
}

/* Max-heap (largest distance at root) — used for the "best results
 * so far" of size ef. New candidate replaces root iff strictly smaller. */
static void
maxheap_push(CandEntry *h, int *n, int cap, CandEntry e)
{
    if (*n < cap) {
        int i = (*n)++;
        h[i] = e;
        while (i > 0) {
            int parent = (i - 1) / 2;
            if (h[i].dist > h[parent].dist) {
                CandEntry t = h[i]; h[i] = h[parent]; h[parent] = t;
                i = parent;
            } else break;
        }
    } else if (cap > 0 && e.dist < h[0].dist) {
        h[0] = e;
        int i = 0;
        for (;;) {
            int l = 2 * i + 1, r = 2 * i + 2, m = i;
            if (l < *n && h[l].dist > h[m].dist) m = l;
            if (r < *n && h[r].dist > h[m].dist) m = r;
            if (m == i) break;
            CandEntry t = h[i]; h[i] = h[m]; h[m] = t;
            i = m;
        }
    }
}

/* ---------- bitset for visited ------------------------------------- */

typedef struct Bitset {
    uint64 *bits;
    int     nwords;
} Bitset;

static Bitset *
bitset_new(int n)
{
    Bitset *b = palloc(sizeof *b);
    b->nwords = (n + 63) / 64;
    b->bits = palloc0((size_t) b->nwords * sizeof(uint64));
    return b;
}

static inline void
bitset_reset(Bitset *b)
{
    memset(b->bits, 0, (size_t) b->nwords * sizeof(uint64));
}

static inline bool
bitset_test(const Bitset *b, int i)
{
    return (b->bits[i >> 6] >> (i & 63)) & 1ULL;
}

static inline void
bitset_set(Bitset *b, int i)
{
    b->bits[i >> 6] |= (1ULL << (i & 63));
}

/* ---------- search ------------------------------------------------- */

/* Greedy + beam search.
 *
 *   query:    normalized query embedding (dim floats)
 *   ef:       beam width (>= k)
 *   k:        number of results requested (<= ef)
 *   visited:  scratch bitset of size >= g->n_nodes
 *   cand:     scratch min-heap, capacity >= g->n_nodes
 *   results:  scratch max-heap, capacity >= ef
 *
 * Fills `out` (CandEntry[k]) with the top-k by ascending distance.
 * Returns the count actually written (<= k).
 */
static int
nsw_search(const AnnGraph *g,
           const float    *query,
           int             k,
           int             ef,
           Bitset         *visited,
           CandEntry      *cand,
           int             cand_cap,
           CandEntry      *results,
           int             res_cap,
           CandEntry      *out)
{
    if (g->n_nodes == 0 || k == 0) return 0;
    if (ef < k) ef = k;
    if (res_cap < ef) ef = res_cap;

    int cand_n = 0;
    int res_n  = 0;
    bitset_reset(visited);

    int32 ep = g->entry_node;
    if (ep < 0 || ep >= g->n_nodes) ep = 0;
    double d0 = ann_distance(g->metric, query, ann_emb(g, ep), g->dim);
    CandEntry e0 = { .idx = ep, .dist = d0 };
    minheap_push(cand, &cand_n, e0);
    maxheap_push(results, &res_n, ef, e0);
    bitset_set(visited, ep);

    while (cand_n > 0) {
        CandEntry c = minheap_pop(cand, &cand_n);
        if (res_n >= ef && c.dist > results[0].dist) break;

        const int32 *ne = ann_edges(g, c.idx);
        for (int e = 0; e < g->m; e++) {
            int32 nb = ne[e];
            if (nb < 0) continue;
            if (bitset_test(visited, nb)) continue;
            bitset_set(visited, nb);
            double d = ann_distance(g->metric, query, ann_emb(g, nb), g->dim);
            if (res_n < ef || d < results[0].dist) {
                CandEntry nc = { .idx = nb, .dist = d };
                minheap_push(cand, &cand_n, nc);
                maxheap_push(results, &res_n, ef, nc);
            }
        }
        CHECK_FOR_INTERRUPTS();

        (void) cand_cap;
    }

    /* Sort the result heap ascending by distance into out[]. */
    int n = res_n;
    if (n > k) n = k;
    /* Simple sort: extract all into temp, sort, copy first k. */
    CandEntry *all = palloc(sizeof(CandEntry) * (res_n > 0 ? res_n : 1));
    memcpy(all, results, sizeof(CandEntry) * res_n);
    /* qsort by distance ascending */
    for (int i = 1; i < res_n; i++) {
        CandEntry x = all[i];
        int j = i - 1;
        while (j >= 0 && (all[j].dist > x.dist ||
                          (all[j].dist == x.dist && all[j].idx > x.idx))) {
            all[j + 1] = all[j];
            j--;
        }
        all[j + 1] = x;
    }
    memcpy(out, all, sizeof(CandEntry) * n);
    pfree(all);
    return n;
}

/* ---------- insert node during build ------------------------------- */

static void
ann_set_edge(AnnGraph *g, int32 a, int32 b, double dist)
{
    int32  *ea = ann_edges(g, a);
    double *da = ann_edge_dists(g, a);

    /* Find empty slot. */
    int empty = -1, worst = 0;
    for (int e = 0; e < g->m; e++) {
        if (ea[e] == EDGE_NONE) { empty = e; break; }
        if (da[e] > da[worst]) worst = e;
    }
    if (empty >= 0) {
        ea[empty] = b;
        da[empty] = dist;
        return;
    }
    /* Evict if new edge is strictly better than the worst. */
    if (dist < da[worst]) {
        ea[worst] = b;
        da[worst] = dist;
    }
}

/* ---------- public: build ------------------------------------------ */

PG_FUNCTION_INFO_V1(maludb_ann_build_c);
Datum
maludb_ann_build_c(PG_FUNCTION_ARGS)
{
    int64       compartment_id = PG_GETARG_INT64(0);
    int32       m              = PG_GETARG_INT32(1);
    int32       ef_construct   = PG_GETARG_INT32(2);
    text       *metric_arg     = PG_GETARG_TEXT_PP(3);
    int         metric         = ann_parse_metric(text_to_cstring(metric_arg));

    int   ret;
    bytea *out;
    int   n_nodes = 0;
    int   dim     = 0;
    MemoryContext caller_cxt = CurrentMemoryContext;

    if (m <= 0)              ereport(ERROR, (errmsg("ann_build: m must be > 0")));
    if (ef_construct <= 0)   ereport(ERROR, (errmsg("ann_build: ef_construct must be > 0")));

    if ((ret = SPI_connect()) != SPI_OK_CONNECT)
        ereport(ERROR, (errmsg("SPI_connect failed: %d", ret)));

    /* Pull chunks for this compartment that are NOT tombstoned, ordered
     * by chunk_id for determinism. */
    {
        const char *sql =
            "SELECT c.chunk_id, c.embedding "
            "FROM maludb_core.malu$vector_chunk c "
            "WHERE c.compartment_id = $1 "
            "  AND NOT EXISTS (SELECT 1 FROM maludb_core.malu$vector_tombstone t "
            "                  WHERE t.chunk_id = c.chunk_id) "
            "ORDER BY c.chunk_id";
        Oid     argtypes[1] = { INT8OID };
        Datum   args[1]     = { Int64GetDatum(compartment_id) };

        ret = SPI_execute_with_args(sql, 1, argtypes, args, NULL, true, 0);
        if (ret != SPI_OK_SELECT)
            ereport(ERROR, (errmsg("ann_build SPI scan failed: %d", ret)));
    }

    n_nodes = (int) SPI_processed;

    /* Edge cases: 0 or 1 nodes produce a minimal graph that the search
     * function handles gracefully. */
    if (n_nodes == 0) {
        SPI_finish();
        /* Empty header-only blob. */
        out = palloc(VARHDRSZ + ANN_HEADER_BYTES);
        SET_VARSIZE(out, VARHDRSZ + ANN_HEADER_BYTES);
        char *p = VARDATA(out);
        memcpy(p, ANN_MAGIC, 4);
        int32 *hdr = (int32 *) (p + 4);
        hdr[0] = metric;
        hdr[1] = 0;
        hdr[2] = m;
        hdr[3] = ef_construct;
        hdr[4] = 0;
        hdr[5] = -1;
        hdr[6] = 0;
        PG_RETURN_BYTEA_P(out);
    }

    /* Discover dim from the first chunk's embedding length. */
    {
        HeapTuple   row     = SPI_tuptable->vals[0];
        TupleDesc   spidesc = SPI_tuptable->tupdesc;
        bool        isnull;
        Datum       d_emb   = SPI_getbinval(row, spidesc, 2, &isnull);
        bytea      *eb;
        int32       elen;

        if (isnull)
            ereport(ERROR, (errmsg("ann_build: first chunk has NULL embedding")));
        eb   = DatumGetByteaPP(d_emb);
        elen = VARSIZE_ANY_EXHDR(eb);
        if (elen % ANN_VEC_F32 != 0)
            ereport(ERROR, (errmsg("ann_build: embedding length %d not multiple of %d",
                                   elen, ANN_VEC_F32)));
        dim = elen / ANN_VEC_F32;
    }

    /* Allocate working graph. The build context is anchored at the
     * CALLER's memory context (saved before SPI_connect switched us
     * into SPI's transient proc context). Anchoring under
     * CurrentMemoryContext here would attach build_cxt to the SPI
     * proc context, and SPI_finish below would free it under our feet
     * — exactly the use-after-free the early R1.1-16 builds tripped
     * on. */
    MemoryContext build_cxt = AllocSetContextCreate(caller_cxt,
                                  "ann_build", ALLOCSET_DEFAULT_SIZES);
    MemoryContext save      = MemoryContextSwitchTo(build_cxt);

    AnnGraph g;
    g.metric       = metric;
    g.dim          = dim;
    g.m            = m;
    g.ef_construct = ef_construct;
    g.n_nodes      = n_nodes;
    g.entry_node   = 0;
    g.chunk_ids    = palloc(sizeof(int64) * n_nodes);
    g.edges        = palloc(sizeof(int32) * (size_t) n_nodes * m);
    g.edge_dists   = palloc(sizeof(double) * (size_t) n_nodes * m);
    g.embeddings   = palloc(sizeof(float)  * (size_t) n_nodes * dim);

    /* Initialize edges to EDGE_NONE. */
    for (size_t i = 0; i < (size_t) n_nodes * m; i++)
        g.edges[i] = EDGE_NONE;

    /* Decode all rows. */
    for (int i = 0; i < n_nodes; i++) {
        HeapTuple   row     = SPI_tuptable->vals[i];
        TupleDesc   spidesc = SPI_tuptable->tupdesc;
        bool        isnull;
        int64       cid     = DatumGetInt64(SPI_getbinval(row, spidesc, 1, &isnull));
        Datum       d_emb   = SPI_getbinval(row, spidesc, 2, &isnull);
        bytea      *eb;
        int32       elen;

        if (isnull) continue;
        eb   = DatumGetByteaPP(d_emb);
        elen = VARSIZE_ANY_EXHDR(eb);
        if (elen / ANN_VEC_F32 != dim)
            ereport(ERROR, (errmsg("ann_build: dim mismatch at chunk %lld",
                                   (long long) cid)));
        g.chunk_ids[i] = cid;
        memcpy(g.embeddings + (size_t) i * dim, VARDATA_ANY(eb),
               (size_t) dim * ANN_VEC_F32);
    }
    SPI_finish();
    MemoryContextSwitchTo(save);

    /* Build: insert each node into the partial graph. Node 0 is the
     * seed (no edges). For 1..n-1, run greedy search against the
     * partial graph and link to M nearest. */
    save = MemoryContextSwitchTo(build_cxt);

    Bitset    *visited = bitset_new(n_nodes);
    CandEntry *cand    = palloc(sizeof(CandEntry) * (n_nodes + 1));
    CandEntry *results = palloc(sizeof(CandEntry) * (ef_construct + 1));
    CandEntry *topm    = palloc(sizeof(CandEntry) * (ef_construct + 1));

    for (int i = 1; i < n_nodes; i++) {
        /* The graph "as of right now" has nodes [0..i-1]. Search it
         * against the new node's embedding. Temporarily lower n_nodes
         * to limit search to the already-built subset. */
        int saved_n = g.n_nodes;
        g.n_nodes   = i;
        const float *q = ann_emb(&g, i);

        int found = nsw_search(&g, q, m, ef_construct,
                               visited, cand, n_nodes + 1,
                               results, ef_construct + 1, topm);
        g.n_nodes = saved_n;

        for (int j = 0; j < found; j++) {
            int32 nb = topm[j].idx;
            double d = topm[j].dist;
            ann_set_edge(&g, i, nb, d);
            ann_set_edge(&g, nb, i, d);    /* bidirectional */
        }
        CHECK_FOR_INTERRUPTS();
    }
    MemoryContextSwitchTo(save);

    /* Serialize the graph. */
    {
        size_t header_bytes = ANN_HEADER_BYTES;
        size_t ids_bytes    = (size_t) n_nodes * sizeof(int64);
        size_t edges_bytes  = (size_t) n_nodes * m * sizeof(int32);
        size_t emb_bytes    = (size_t) n_nodes * dim * ANN_VEC_F32;
        size_t total        = header_bytes + ids_bytes + edges_bytes + emb_bytes;

        out = palloc(VARHDRSZ + total);
        SET_VARSIZE(out, VARHDRSZ + total);
        char *p = VARDATA(out);
        memcpy(p, ANN_MAGIC, 4);
        int32 *hdr = (int32 *) (p + 4);
        hdr[0] = metric;
        hdr[1] = dim;
        hdr[2] = m;
        hdr[3] = ef_construct;
        hdr[4] = n_nodes;
        hdr[5] = g.entry_node;
        hdr[6] = 0;

        char *cur = p + ANN_HEADER_BYTES;
        memcpy(cur, g.chunk_ids,  ids_bytes);   cur += ids_bytes;
        memcpy(cur, g.edges,      edges_bytes); cur += edges_bytes;
        memcpy(cur, g.embeddings, emb_bytes);
    }

    MemoryContextDelete(build_cxt);
    PG_RETURN_BYTEA_P(out);
}

/* ---------- public: search ----------------------------------------- */

static void
ann_decode_blob(bytea *blob, AnnGraph *g)
{
    /* The graph holds int32 headers, int64 ids and float embeddings. */
    const char *p = maludb_varlena_aligned(blob);
    int32  len = VARSIZE_ANY_EXHDR(blob);
    if (len < ANN_HEADER_BYTES)
        ereport(ERROR, (errmsg("ann_search: blob too short (%d bytes)", len)));
    if (memcmp(p, ANN_MAGIC, 4) != 0)
        ereport(ERROR, (errmsg("ann_search: bad magic")));
    const int32 *hdr = (const int32 *) (p + 4);
    g->metric       = hdr[0];
    g->dim          = hdr[1];
    g->m            = hdr[2];
    g->ef_construct = hdr[3];
    g->n_nodes      = hdr[4];
    g->entry_node   = hdr[5];
    g->edge_dists   = NULL;

    size_t ids_bytes   = (size_t) g->n_nodes * sizeof(int64);
    size_t edges_bytes = (size_t) g->n_nodes * g->m * sizeof(int32);
    size_t emb_bytes   = (size_t) g->n_nodes * g->dim * ANN_VEC_F32;
    if ((size_t) len < ANN_HEADER_BYTES + ids_bytes + edges_bytes + emb_bytes)
        ereport(ERROR, (errmsg("ann_search: blob truncated")));

    char *cur     = (char *) p + ANN_HEADER_BYTES;  /* read-only use below */
    g->chunk_ids  = (int64 *) cur; cur += ids_bytes;
    g->edges      = (int32 *) cur; cur += edges_bytes;
    g->embeddings = (float *) cur;
}

PG_FUNCTION_INFO_V1(maludb_ann_search_c);
Datum
maludb_ann_search_c(PG_FUNCTION_ARGS)
{
    bytea       *blob       = PG_GETARG_BYTEA_PP(0);
    bytea       *qbytea     = PG_GETARG_BYTEA_PP(1);
    int32        k          = PG_GETARG_INT32(2);
    int32        ef_search  = PG_GETARG_INT32(3);
    text        *metric_arg = PG_ARGISNULL(4) ? NULL : PG_GETARG_TEXT_PP(4);
    AnnGraph     g;

    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc       tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext   per_query_ctx;
    MemoryContext   oldctx;

    if (k <= 0) ereport(ERROR, (errmsg("ann_search: k must be > 0")));
    if (ef_search < k) ef_search = k;

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

    ann_decode_blob(blob, &g);

    /* Validate query dim. */
    {
        int32 qlen = VARSIZE_ANY_EXHDR(qbytea);
        if (qlen / ANN_VEC_F32 != g.dim)
            ereport(ERROR,
                    (errcode(ERRCODE_DATA_EXCEPTION),
                     errmsg("ann_search: query dim %d != graph dim %d",
                            qlen / ANN_VEC_F32, g.dim)));
    }
    const float *qvec = (const float *) maludb_varlena_aligned(qbytea);

    /* Empty graph → return nothing. */
    if (g.n_nodes == 0) return (Datum) 0;

    /* If caller passed a metric override, parse and use; otherwise the
     * graph's own metric (the one used at build) is the truth. */
    int metric = g.metric;
    if (metric_arg) metric = ann_parse_metric(text_to_cstring(metric_arg));
    g.metric = metric;

    Bitset    *visited = bitset_new(g.n_nodes);
    CandEntry *cand    = palloc(sizeof(CandEntry) * (g.n_nodes + 1));
    CandEntry *results = palloc(sizeof(CandEntry) * (ef_search + 1));
    CandEntry *out     = palloc(sizeof(CandEntry) * (k + 1));

    int found = nsw_search(&g, qvec, k, ef_search,
                           visited, cand, g.n_nodes + 1,
                           results, ef_search + 1, out);

    Datum  values[4];
    bool   nulls[4] = { false, false, false, false };

    for (int i = 0; i < found; i++) {
        double dist = out[i].dist;
        double sim;
        switch (metric) {
            case ANN_METRIC_COSINE: sim = 1.0 - dist; break;
            case ANN_METRIC_L2:     sim = -dist;      break;
            default:                sim = -dist;      break;
        }
        values[0] = Int64GetDatum(g.chunk_ids[out[i].idx]);
        values[1] = Float8GetDatum(dist);
        values[2] = Float8GetDatum(sim);
        values[3] = Int32GetDatum(i + 1);
        tuplestore_putvalues(tupstore, tupdesc, values, nulls);
    }

    return (Datum) 0;
}
