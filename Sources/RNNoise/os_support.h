/* SPDX-License-Identifier: GPL-3.0-or-later */
/* SPDX-FileCopyrightText: 2026 KC2RGW Chris */

/* RNNoise 0.2's ARM NEON code (vec_neon.h) includes os_support.h, which the
   release tarball doesn't ship. It only needs OPUS_INLINE and OPUS_CLEAR,
   which RNNoise's common.h has (as OPUS_INLINE and RNN_CLEAR). */
#ifndef PATCHPRIME_RNNOISE_OS_SUPPORT_H
#define PATCHPRIME_RNNOISE_OS_SUPPORT_H

#include "common.h"

#ifndef OPUS_CLEAR
#define OPUS_CLEAR(dst, n) RNN_CLEAR(dst, n)
#endif

#endif
