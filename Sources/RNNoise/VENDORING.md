# RNNoise (vendored)

Xiph.Org's RNNoise, for the noise suppression effect. BSD-3-Clause (see COPYING),
which is compatible with PatchPrimeMac's GPL-3.0-or-later.

- Source: https://github.com/xiph/rnnoise/releases/download/v0.2/rnnoise-0.2.tar.gz
- SHA-256 of the tarball: 90fce4b00b9ff24c08dbfe31b82ffd43bae383d85c5535676d28b0a2b11c0d37
  (the same release and checksum Patch Prime pins in cmake/RNNoise.cmake)
- Taken from it: `src/*.h` and `src/x86/*.h` (headers only: the x86 code isn't built), the ten `.c` files Patch Prime builds (not `dump_features.c`,
  a training tool), `include/rnnoise.h`, COPYING and AUTHORS. Unchanged.
- `rnnoise_data.c` is the trained model, built in.
- Added: `os_support.h`, from Patch Prime (cmake/rnnoise), which the release's ARM NEON
  code includes but doesn't ship.

Compiled with -O2 and warnings off: it runs on the realtime thread, and its warnings
aren't ours to fix.
