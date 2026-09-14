/* maludb_type.c — R1.1-17 malu_vector custom varlena type.
 *
 * Storage layout is byte-compatible with bytea: a varlena header
 * followed by 4*dim bytes of host-order IEEE 754 float32. Dim is
 * derived from the length, not stored separately, so a cast
 * malu_vector ↔ bytea is WITHOUT FUNCTION (zero-cost). Operators
 * still see a typed value with its own text and binary I/O.
 *
 * Text format: "[f1, f2, ...]" — matches pgvector's vector(N) for
 * easy migration of values copied out of that ecosystem.
 *
 * The R1.1-12 / R1.1-13 / R1.1-14 C functions in maludb_vector.c +
 * maludb_search.c work unchanged: they take bytea Datums and rely on
 * VARSIZE_ANY_EXHDR + VARDATA_ANY, which apply to any varlena type.
 * Only the SQL declarations swap from bytea to malu_vector.
 */

#include "postgres.h"

#include "common/shortest_dec.h"
#include "maludb_varlena.h"
#include "fmgr.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/bytea.h"
#include "libpq/pqformat.h"
#include "lib/stringinfo.h"
#include "catalog/pg_type.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

#define MALU_VEC_BYTES_PER_ELEMENT 4

/* ---------------------------------------------------------------------
 * malu_vector_in: parse "[f1, f2, ...]" into varlena-packed float32.
 *
 * Whitespace is permitted around tokens; commas separate values.
 * Empty vector "[]" is accepted (zero-dim).
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_in);
Datum
maludb_vector_in(PG_FUNCTION_ARGS)
{
    char       *s     = PG_GETARG_CSTRING(0);
    char       *p     = s;
    int         count = 0;
    int         cap   = 16;
    float      *out   = (float *) palloc(sizeof(float) * cap);
    bytea      *result;

    while (*p && isspace((unsigned char) *p)) p++;
    if (*p != '[')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                 errmsg("malu_vector input must start with '['"),
                 errdetail("Got: \"%s\"", s)));
    p++;
    while (*p && isspace((unsigned char) *p)) p++;

    while (*p && *p != ']') {
        char   *end;
        double  v;

        errno = 0;
        v = strtod(p, &end);
        if (end == p)
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                     errmsg("malu_vector: invalid float starting at: \"%s\"", p)));
        if (count >= cap) {
            cap *= 2;
            out  = (float *) repalloc(out, sizeof(float) * cap);
        }
        out[count++] = (float) v;
        p = end;

        while (*p && isspace((unsigned char) *p)) p++;
        if (*p == ',') {
            p++;
            while (*p && isspace((unsigned char) *p)) p++;
        } else if (*p != ']' && *p != '\0') {
            ereport(ERROR,
                    (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                     errmsg("malu_vector: expected ',' or ']' at: \"%s\"", p)));
        }
    }

    if (*p != ']')
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_TEXT_REPRESENTATION),
                 errmsg("malu_vector input must end with ']'")));

    result = (bytea *) palloc(VARHDRSZ + count * MALU_VEC_BYTES_PER_ELEMENT);
    SET_VARSIZE(result, VARHDRSZ + count * MALU_VEC_BYTES_PER_ELEMENT);
    memcpy(VARDATA(result), out, count * MALU_VEC_BYTES_PER_ELEMENT);

    pfree(out);
    PG_RETURN_POINTER(result);
}

/* ---------------------------------------------------------------------
 * malu_vector_out: format as "[f1, f2, ...]".
 *
 * Each element is printed as the shortest decimal that reads back as the
 * same float4 (PostgreSQL's float_to_shortest_decimal_bufn, the routine
 * float4out uses). It was "%g", six significant digits, which is not
 * enough for a float4: every text read of an embedding -- pg_dump, COPY,
 * a client reading the column -- returned a rounded copy, and a restore
 * wrote that copy back (#31).
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_out);
Datum
maludb_vector_out(PG_FUNCTION_ARGS)
{
    bytea          *vb   = PG_GETARG_BYTEA_PP(0);
    int32           len  = VARSIZE_ANY_EXHDR(vb);
    const float    *data = (const float *) maludb_varlena_aligned(vb);
    int32           dim;
    StringInfoData  buf;

    if (len % MALU_VEC_BYTES_PER_ELEMENT != 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                 errmsg("malu_vector storage length %d is not a multiple of %d",
                        len, MALU_VEC_BYTES_PER_ELEMENT)));
    dim = len / MALU_VEC_BYTES_PER_ELEMENT;

    initStringInfo(&buf);
    appendStringInfoChar(&buf, '[');
    for (int32 i = 0; i < dim; i++) {
        char    num[FLOAT_SHORTEST_DECIMAL_LEN];
        int     n;

        if (i > 0) appendStringInfoString(&buf, ", ");
        n = float_to_shortest_decimal_bufn(data[i], num);
        appendBinaryStringInfo(&buf, num, n);
    }
    appendStringInfoChar(&buf, ']');
    PG_RETURN_CSTRING(buf.data);
}

/* ---------------------------------------------------------------------
 * malu_vector_recv: binary in (wire format). We accept the raw float32
 * bytes the sender provides; dim is derived from the message length.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_recv);
Datum
maludb_vector_recv(PG_FUNCTION_ARGS)
{
    StringInfo  buf  = (StringInfo) PG_GETARG_POINTER(0);
    int32       nbytes;
    bytea      *result;

    nbytes = buf->len - buf->cursor;
    if (nbytes % MALU_VEC_BYTES_PER_ELEMENT != 0)
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_BINARY_REPRESENTATION),
                 errmsg("malu_vector wire payload %d not multiple of %d",
                        nbytes, MALU_VEC_BYTES_PER_ELEMENT)));
    result = (bytea *) palloc(VARHDRSZ + nbytes);
    SET_VARSIZE(result, VARHDRSZ + nbytes);
    pq_copymsgbytes(buf, VARDATA(result), nbytes);
    PG_RETURN_POINTER(result);
}

/* ---------------------------------------------------------------------
 * malu_vector_send: binary out (wire format). Same bytes as bytea_send.
 * ------------------------------------------------------------------- */
PG_FUNCTION_INFO_V1(maludb_vector_send);
Datum
maludb_vector_send(PG_FUNCTION_ARGS)
{
    bytea          *vb = PG_GETARG_BYTEA_PP(0);
    StringInfoData  buf;
    pq_begintypsend(&buf);
    pq_sendbytes(&buf, VARDATA_ANY(vb), VARSIZE_ANY_EXHDR(vb));
    PG_RETURN_BYTEA_P(pq_endtypsend(&buf));
}
