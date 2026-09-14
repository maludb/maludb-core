/*
 * maludb_varlena.h -- read a varlena's payload through typed pointers safely.
 *
 * A bytea fetched with PG_GETARG_BYTEA_PP may keep its 1-byte short header,
 * and a value stored in a tuple starts wherever the tuple's alignment put it,
 * so VARDATA_ANY() is not guaranteed to be aligned for float, int32 or int64.
 * Casting it to one of those and dereferencing is undefined behaviour: x86-64
 * tolerates it, strict-alignment targets and optimising compilers need not, and
 * UBSan reports "load of misaligned address" (the CI sanitizer job).
 *
 * maludb_varlena_aligned() returns the payload itself when it is already at
 * maximum alignment, and otherwise a palloc'd copy (palloc memory is
 * MAXALIGN'd) in the current memory context. Callers treat the result as
 * read-only and never pfree it.
 */
#ifndef MALUDB_VARLENA_H
#define MALUDB_VARLENA_H

#include "postgres.h"
#if PG_VERSION_NUM >= 160000
#include "varatt.h"    /* VARDATA_ANY, VARSIZE_ANY_EXHDR moved here in PostgreSQL 16 */
#endif

#include <string.h>

static inline const char *
maludb_varlena_aligned(const struct varlena *v)
{
    const char *p   = VARDATA_ANY(v);
    Size        len = VARSIZE_ANY_EXHDR(v);
    char       *copy;

    if (((uintptr_t) p & (MAXIMUM_ALIGNOF - 1)) == 0)
        return p;
    copy = (char *) palloc(len > 0 ? len : 1);
    memcpy(copy, p, len);
    return copy;
}

#endif /* MALUDB_VARLENA_H */
