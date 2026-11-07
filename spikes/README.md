# Spikes

Throwaway experiments for PatchPrimeMac. Nothing here is product code.

- `s1-driver`: test driver and `probe`. Build libASPL first:
  `cmake -S third_party/libASPL -B build/aspl -DCMAKE_INSTALL_PREFIX=$PWD/build/aspl-prefix -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 -DBUILD_TESTING=OFF && cmake --build build/aspl --target install`,
  then `cmake -S spikes/s1-driver -B build/s1 -G Ninja && cmake --build build/s1`.
- `s2-clock`: `follower.h` (ring, resampler, rate controller), `sim.cpp` (offline tests), `drift.cpp`.
- `s4-auhost`: Audio Unit hosting. `auspike` loads one AU effect (C API) in or out of process
  and renders a tone offline (`paced`, `state`, `crash` options); `twohosts` counts hosting
  processes; `winspike` opens a plugin's own window from an out-of-process instance. Silent:
  no audio device is touched. Build: `clang++ -std=c++20 -fobjc-arc -O2 X.mm -framework
  AVFoundation -framework AudioToolbox -framework Foundation [-framework CoreAudioKit -framework Cocoa]`.
