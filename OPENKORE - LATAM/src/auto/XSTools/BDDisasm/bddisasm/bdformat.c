/*
 * Copyright (c) 2020 Bitdefender
 * SPDX-License-Identifier: Apache-2.0
 */
#include "include/nd_crt.h"
#include "../inc/bddisasm.h"


NDSTATUS
NdToText(
    const INSTRUX *Instrux,
    uint64_t Rip,
    uint32_t BufferSize,
    char *Buffer
    )
{
    UNREFERENCED_PARAMETER(Instrux);
    UNREFERENCED_PARAMETER(Rip);

    // At least make sure the buffer is NULL-terminated so integrators can use NdToText without checking if the
    // BDDISASM_NO_FORMAT macro is defined. This makes switching between versions with formatting and versions without
    // formatting easier.
    if (Buffer != NULL && BufferSize >= 1)
    {
        *Buffer = '\0';
    }

    return ND_STATUS_SUCCESS;
}