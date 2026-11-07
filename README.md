# PatchPrimeMac

A free, open-source audio mixer for macOS. It turns your Mac's audio into a small mixing console: microphones and instruments, the sound from your apps, mix buses and outputs, with effects on any of them. It runs in the background, so the sound keeps going with the window closed, and it carries on when a device is unplugged, switched off or plugged back in.

![The PatchPrimeMac mixer](docs/mixer.png)

It's the Mac sibling of [Patch Prime](https://github.com/kingsqueak/patch-prime), the Linux mixer built on PipeWire: a separate native app that shares its DSP.

## What it does

- **Virtual devices** that apps play into or record from: make *Patch Desktop* the Mac's output and every app goes through the mixer; give a call or streaming app *Patch Mic* as its microphone and it hears your mics with their effects.
- **Strips, mix buses and outputs**, routed at any level from any strip or bus to any output, with mute, cue (headphones) and meters everywhere.
- **Built-in effects** on every strip, bus and output: parametric EQ, compressor, de-esser, expander, multiband compressor, noise gate, noise suppression (RNNoise), ducker, broadcast leveler, safety limiter, reverb, delay and gain, with presets.
- **Audio Unit plugins**, each hosted out of process so a crashing plugin doesn't take the mix down.
- **Scenes** that save and recall the whole mix, a **mini window**, and a command-line tool (`patchprime-ctl`).
- **Device handling** that follows a device across reconnects and driver changes, mixes devices on different clocks without drift, and refuses setups that would misbehave rather than going silent.

Full details are in the [user guide](docs/user-guide.md), which is also in the app under **Help**.

## Requirements

A Mac with Apple Silicon, macOS 26 or later.

## Installing

Download the DMG from [Releases](https://github.com/kingsqueak/PatchPrimeMac/releases) and check its SHA-256 against the release notes. The DMG holds the installer, a Read Me and the uninstaller.

PatchPrimeMac isn't signed with a paid Apple Developer certificate, so macOS stops the installer the first time ("Apple cannot check it"). Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** beside PatchPrimeMac. Or, before opening the DMG:

```
xattr -dr com.apple.quarantine ~/Downloads/PatchPrimeMac-*.dmg
```

The installer asks for your password, since it installs an audio driver. **At the end, all sound on the Mac stops for a moment** while macOS's audio system restarts with the driver: turn loud speakers or amplifiers down first. A few apps that are using sound (some Electron apps, such as Signal) may close; reopen them.

Then open PatchPrimeMac. The first time, a **Start here** panel sets up the usual mix: where you listen, your apps' sound, your microphones, and optionally a microphone for apps. When a microphone is first used, allow PatchPrimeMac to use it.

## Uninstalling

Open **Uninstall PatchPrimeMac** from the DMG, or **Help → Uninstall PatchPrimeMac…** in the app. It removes everything PatchPrimeMac added (the app, the engine, the driver, its entries in macOS's audio settings, logs and permissions) and puts your default sound devices back. You choose whether to keep your settings, presets and scenes.

## Building from source

Needs Xcode (macOS 26 SDK), CMake and Ninja (`brew install cmake ninja`).

```
git clone --recursive https://github.com/kingsqueak/PatchPrimeMac.git
cd PatchPrimeMac
PPMAC_SIGN=- scripts/make-release.sh
```

That builds the driver, the engine and the app, runs the tests, and leaves an ad-hoc-signed `PatchPrimeMac-<version>.pkg` and `.dmg` in `build/release`. (Release builds are signed with the project's own certificate instead, so macOS keeps the microphone permission across updates; an ad-hoc build asks again after each one.)

How it fits together:

- `driver/`: the audio driver (an AudioServerPlugIn on [libASPL](https://github.com/gavv/libASPL)) that provides the virtual devices.
- `Sources/PPCore`: the realtime mixing engine on Core Audio, with clock bridging between devices.
- `Sources/PPDSP`: the effects, shared with Patch Prime.
- `Sources/PatchPrimeEngine`: the background helper that runs the engine and hosts plugins.
- `Sources/PatchPrimeMac`: the SwiftUI app. `Sources/patchprime-ctl`: the command-line tool.
- `packaging/`: the installer, the uninstaller and the Read Me. `spikes/`: early experiments that tested the design; not product code.

## Licence

GPL-3.0-or-later (see [LICENSE](LICENSE)). It includes [RNNoise](https://github.com/xiph/rnnoise) (BSD-3-Clause, `Sources/RNNoise`) and [libASPL](https://github.com/gavv/libASPL) (MIT, `third_party/libASPL`); their notices ship with the app in `THIRD-PARTY-NOTICES.txt`.

Made by KC2RGW. Bug reports and suggestions are welcome in [Issues](https://github.com/kingsqueak/PatchPrimeMac/issues).
