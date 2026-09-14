/* maludb_vector.c — R1.1-12 vector primitives over BYTEA-packed float32.
 *
 * Storage format: a BYTEA whose length is exactly 4 * dim, with each
 * 4-byte slice holding one IEEE 754 single-precision value in the host
 * byte order. We don't try to be portable across mixed-endian setups
 * for R1.1-12 — Ubuntu 24.04 on x86_64 / arm64 is little-endian, and
 * cross-cluster vector portability lands with the malu_vector custom
 * type in R1.1-17.
 *
 * Design from docs/research/2026-05-06-compartmentalized-vector-search.md.
 * Doctrine: relational filter first, exact vector scoring second.
 */

#include "postgres.h"
#include "maludb_varlena.h"
#include "fmgr.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "catalog/pg_type.h"

#include <math.h>
#include <string.h>

#define MALUDB_VEC_BYTES_PER_ELEMENT 4

/* Common decode: validate that a BYTEA carries an integer number of
 * float32s, then return its element count and a pointer to the data.
 * The pointer is into the detoasted varlena and stays valid for the
 * scope of the caller's PG_FUNCTION. */
static inline int32
maludb_vec_decode(bytea *vb, const float **out)
{
    int32 len = VARSIZE_ANY_EXHDR(vb);
    if (len % MALUDB_VEC_BYTES_PER_ELEMENT != 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                 errmsg("vector bytea length %d is not a multiple of %d",
                        len, MALUDB_VEC_BYTES_PER_ELEMENT)));
    *out = (const float *) maludb_varlena_aligned(vb);
    return len / MALUDB_VEC_BYTES_PER_ELEMENT;
}

static inline void
maludb_vec_check_dims(int32 dim_a, int32 dim_b)
{
    if (dim_a != dim_b)
        ereport(ERROR,
                (errcode(ERRCODE_DATA_EXCEPTION),
                 errmsg("vector dimension mismatch: %d vs %d", dim_a, dim_b)));
}

/* ---------------------------------------------------------------------
 * vector_from_real_array(real[]) -> bytea
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_from_real_array);
Datum
maludb_vector_from_real_array(PG_FUNCTION_ARGS)
{
    ArrayType *arr = PG_GETARG_ARRAYTYPE_P(0);
    int        nelems;
    float4    *src;
    bytea     *out;
    int        out_len;
    char      *dst;

    if (ARR_NDIM(arr) > 1)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("vector_from_real_array: input must be a 1-D array")));
    if (ARR_HASNULL(arr))
        ereport(ERROR,
                (errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
                 errmsg("vector_from_real_array: input array must not contain NULLs")));
    if (ARR_ELEMTYPE(arr) != FLOAT4OID)
        ereport(ERROR,
                (errcode(ERRCODE_DATATYPE_MISMATCH),
                 errmsg("vector_from_real_array: input must be real[]")));

    nelems = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
    src    = (float4 *) ARR_DATA_PTR(arr);

    out_len = nelems * MALUDB_VEC_BYTES_PER_ELEMENT;
    out = (bytea *) palloc(VARHDRSZ + out_len);
    SET_VARSIZE(out, VARHDRSZ + out_len);
    dst = VARDATA(out);
    memcpy(dst, src, out_len);
    PG_RETURN_BYTEA_P(out);
}

/* ---------------------------------------------------------------------
 * vector_to_real_array(bytea) -> real[]
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_to_real_array);
Datum
maludb_vector_to_real_array(PG_FUNCTION_ARGS)
{
    bytea       *vb = PG_GETARG_BYTEA_PP(0);
    const float *vec;
    int32        dim;
    Datum       *elems;
    ArrayType   *arr;

    dim = maludb_vec_decode(vb, &vec);
    elems = (Datum *) palloc(sizeof(Datum) * dim);
    for (int32 i = 0; i < dim; i++)
        elems[i] = Float4GetDatum(vec[i]);
    arr = construct_array(elems, dim, FLOAT4OID,
                          sizeof(float4), true, 'i');
    PG_RETURN_ARRAYTYPE_P(arr);
}

/* ---------------------------------------------------------------------
 * vector_dims(bytea) -> integer
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_dims);
Datum
maludb_vector_dims(PG_FUNCTION_ARGS)
{
    bytea       *vb = PG_GETARG_BYTEA_PP(0);
    const float *vec;
    int32        dim = maludb_vec_decode(vb, &vec);
    PG_RETURN_INT32(dim);
}

/* ---------------------------------------------------------------------
 * vector_norm(bytea) -> float8
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_norm);
Datum
maludb_vector_norm(PG_FUNCTION_ARGS)
{
    bytea       *vb = PG_GETARG_BYTEA_PP(0);
    const float *vec;
    int32        dim = maludb_vec_decode(vb, &vec);
    double       sum = 0.0;
    for (int32 i = 0; i < dim; i++) {
        double v = (double) vec[i];
        sum += v * v;
    }
    PG_RETURN_FLOAT8(sqrt(sum));
}

/* ---------------------------------------------------------------------
 * vector_dot_product(bytea, bytea) -> float8
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_dot_product);
Datum
maludb_vector_dot_product(PG_FUNCTION_ARGS)
{
    bytea       *va = PG_GETARG_BYTEA_PP(0);
    bytea       *vb = PG_GETARG_BYTEA_PP(1);
    const float *a, *b;
    int32        da = maludb_vec_decode(va, &a);
    int32        db = maludb_vec_decode(vb, &b);
    double       sum = 0.0;
    maludb_vec_check_dims(da, db);
    for (int32 i = 0; i < da; i++)
        sum += (double) a[i] * (double) b[i];
    PG_RETURN_FLOAT8(sum);
}

/* ---------------------------------------------------------------------
 * vector_l2_squared(bytea, bytea) -> float8
 *
 * Sum of squared component differences. Squared L2 preserves ordering
 * for ranking, so we don't take the square root here.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_l2_squared);
Datum
maludb_vector_l2_squared(PG_FUNCTION_ARGS)
{
    bytea       *va = PG_GETARG_BYTEA_PP(0);
    bytea       *vb = PG_GETARG_BYTEA_PP(1);
    const float *a, *b;
    int32        da = maludb_vec_decode(va, &a);
    int32        db = maludb_vec_decode(vb, &b);
    double       sum = 0.0;
    maludb_vec_check_dims(da, db);
    for (int32 i = 0; i < da; i++) {
        double d = (double) a[i] - (double) b[i];
        sum += d * d;
    }
    PG_RETURN_FLOAT8(sum);
}

/* ---------------------------------------------------------------------
 * vector_normalize(bytea) -> bytea
 *
 * In-place style: returns a new BYTEA with each component divided by
 * the L2 norm. Zero vectors are returned unchanged (no division by 0).
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_normalize);
Datum
maludb_vector_normalize(PG_FUNCTION_ARGS)
{
    bytea       *vb = PG_GETARG_BYTEA_PP(0);
    const float *vec;
    int32        dim = maludb_vec_decode(vb, &vec);
    bytea       *out;
    float       *dst;
    double       sum = 0.0;
    double       norm;

    for (int32 i = 0; i < dim; i++) {
        double v = (double) vec[i];
        sum += v * v;
    }
    norm = sqrt(sum);

    out = (bytea *) palloc(VARHDRSZ + dim * MALUDB_VEC_BYTES_PER_ELEMENT);
    SET_VARSIZE(out, VARHDRSZ + dim * MALUDB_VEC_BYTES_PER_ELEMENT);
    dst = (float *) VARDATA(out);
    if (norm == 0.0) {
        memcpy(dst, vec, dim * MALUDB_VEC_BYTES_PER_ELEMENT);
    } else {
        double inv = 1.0 / norm;
        for (int32 i = 0; i < dim; i++)
            dst[i] = (float) ((double) vec[i] * inv);
    }
    PG_RETURN_BYTEA_P(out);
}
