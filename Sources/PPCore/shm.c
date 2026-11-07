// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// shm_open is variadic, which Swift can't call.
#include "ppcore.h"
#include <sys/mman.h>
#include <sys/stat.h>

int pp_shm_open(const char *name, int flags, int mode)
{
    return shm_open(name, flags, (mode_t)mode);
}
