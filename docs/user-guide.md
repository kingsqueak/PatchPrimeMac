# PatchPrimeMac user guide

PatchPrimeMac turns your Mac's audio into a small mixing console: your microphones and other inputs, the sound from your apps, mix buses and outputs, with effects on any of them. It runs in the background, so the sound keeps going with the window closed, and it carries on when a device is unplugged, switched off or plugged back in.

## Getting started

### The idea in one minute

<!-- keywords: overview, concept, strip, bus, output, virtual device, engine -->

- **Inputs** are strips: a microphone on your audio interface, the radio on a USB codec, or a **virtual device** that apps play into (Desktop, say, which you make the Mac's default output, so everything you hear goes through the mixer).
- **Mix buses** add strips together: a Stream bus with your mic and the music, for example.
- **Outputs** are where sound goes: your headphones or speakers, or a virtual device that apps record from (Stream Mic, which a streaming or call app uses as its microphone).
- **Routing** connects them: a strip to buses and outputs, a bus to outputs, each at its own level.
- **Effects** run on any strip, bus or output: the built-in ones (EQ, compressor, noise suppression and more) and Audio Unit plugins.

The mixing is done by the **engine**, a helper that starts when you log in and runs without a window. The PatchPrimeMac app is its control panel: quitting the app changes nothing you hear. The menu bar icon (three sliders) opens the mixer again.

### Installing

<!-- keywords: install, pkg, dmg, gatekeeper, open anyway, quarantine, security, apple silicon -->

PatchPrimeMac is free and open source (GPL-3.0-or-later). It needs a Mac with Apple Silicon and macOS 26 or later.

1. Open the downloaded DMG. It holds the installer (**PatchPrimeMac.pkg**), a Read Me and the uninstaller.
2. PatchPrimeMac isn't signed with a paid Apple certificate, so macOS stops the installer the first time: "can't be opened because Apple cannot check it". Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** beside PatchPrimeMac. (Or, in Terminal: `xattr -dr com.apple.quarantine ~/Downloads/PatchPrimeMac-*.dmg` before opening it.)
3. Run the installer. It asks for your password: it installs an audio driver, which only an administrator can.
4. **At the end of the install, all sound on the Mac stops for a moment** while macOS's audio system restarts with the driver. Turn your speakers or amplifier down first if they're loud.
5. The engine starts. The first time an input from a microphone is used, macOS asks to let **PatchPrimeMac** use the microphone: allow it, or the mics stay silent.

**Updating:** install the new version the same way, over the old one. Your settings are kept, and the app opens again if it was open. macOS asks for microphone access again after each update, because each version carries its own signature rather than one from Apple: click **Allow** again.

### First setup

<!-- keywords: first time, start here, hardware output, safety, setup, add input, add output, patch desktop, patch mic, default output -->

Open PatchPrimeMac (in Applications, or from the menu bar icon). The first time, the mixer shows a **Start here** panel that sets up the usual mix in five steps, ticking each off as it's done:

1. **Where you listen**: pick your speakers or headphones and click **Add Output**.
2. **Your apps' sound**: **Set Up Patch Desktop** creates a virtual device called Patch Desktop, makes it the Mac's sound output, adds it as the **Desktop** strip and sends it to where you listen. From then on every app plays into the mixer. Apps that choose their own output device (call, streaming and radio apps, music software) have a setting for it: set it to Patch Desktop, or create a virtual device just for that app (see [Virtual devices and the system defaults](#virtual-devices-and-the-system-defaults)) to give it its own strip. To go back to playing straight to your speakers, pick them in System Settings → Sound.
3. **Your microphones and instruments**: pick the device and channel and click **Add Input**. They aren't sent to your speakers until you route them, so a microphone can't feed back.
4. **A microphone for apps** (optional): **Set Up Patch Mic** creates Patch Mic, makes it the Mac's microphone, and sends your inputs to it, so call and streaming apps hear your microphones with their effects.
5. **Turn on hardware output.**

**Hide** puts the panel away; it comes back if the mix is ever emptied. Everything it does can also be done by hand:

- **Hardware output starts off.** Until you turn it on (the button at the top right), nothing reaches your speakers or headphones, so a mistake in routing can't blast your amplifier. When it's on, every hardware output has a safety limiter at −6 dBFS: nothing louder leaves.
- **Add your inputs** in **Setup → Add an input**: pick the device and the channel (a microphone on input 1 of your interface, say), and give it a name.
- **Add your outputs** in **Setup → Add a hardware output**: your headphones or speakers.
- **Virtual devices** (Setup → Virtual devices): create one that apps play into (Desktop), add it as a strip with **Add Strip**, and make it the Mac's default output with **Make Default**, so your apps' sound comes through the mixer. Create one that apps record from (Mic), add it as an output, and pick it as the microphone in your streaming or call app. The Mac lists them with "Patch" in front: Patch Desktop, Patch Mic.
- **Route** each strip where it should go (see [Routing](#routing)).

### Finding your way around

<!-- keywords: tabs, mixer tab, routing tab, setup tab, menu bar, top bar -->

- **Mixer**: every strip, bus and output, with its fader, meter and buttons.
- **Routing**: a grid of every route, strip and bus down the side, buses and outputs across.
- **Setup**: the clock, sample rate and buffer size, plugins, adding inputs, buses and outputs, the system defaults and virtual devices.
- The top bar also has the **Scenes** menu, the **Recordings** button (it opens the Recordings window: the format, multitrack takes, your recordings and the player; it's red while anything records), the **mini window** button, the engine's state, and **Hardware Output**.
- The **menu bar icon** shows whether the engine is running, opens the mixer (**Open Mixer**, also after you closed its window), and quits the app (the sound carries on).

## Mixing

### A channel strip

<!-- keywords: strip, fader, mute, cue, star, default, route, fx, rename, remove, move, order, reorder, offline, no signal -->

From top to bottom:

- **The name**, in the strip's colour: green for inputs, blue for mix buses, orange for outputs. Right-click the strip to **Rename** or **Remove** it, or to **Move Left** or **Move Right** within its section (its routing and effects go with it).
- **FX**: its effects (see [Effects](#effects)). It's blue and shows how many while effects are on, "FX OFF" while they're all bypassed.
- **What it is**: the device and channel, "Virtual" or "Mix bus". **OFFLINE** in red means its device isn't there (unplugged or switched off); **NO SIGNAL** in orange means the device is there but sends pure silence (nothing plugged into that channel, or microphone permission refused).
- **The fader**, with the level in dB under it, and the **meter** beside it (after the fader and effects). Drag it, scroll on it (half a dB a notch), or double-click it for 0 dB.
- **M** mutes it.
- **C** cues it: you hear it alone in the cue output (see [Cue](#cue-headphones)). C appears once a cue output is chosen.
- **★** shows and sets the Mac's default device: green when this strip's device is the default. On a strip apps play into (Desktop), it makes that the default **output**; on an output apps record from (Stream Mic), the default **input**; on hardware, that device. macOS makes a whole device the default, never one channel: two mics on one interface both show it.
- **Route**: where it goes (see [Routing](#routing)). Outputs have none.
- **REC** records it to a file; with Multitrack on it reads **ARM** (see [Recording](#recording)).

**Scrolling:** the scroll wheel works on faders, sliders, knobs and number fields everywhere. Hold **Option** or **Command**, or use a mouse's thumb wheel (or Shift with the wheel), for steps a tenth the size.

### Virtual devices and the system defaults

<!-- keywords: virtual device, desktop, stream mic, default output, default input, system sounds, loopback -->

Virtual devices are audio devices PatchPrimeMac adds to the Mac. Apps see them like any other.

- One that **apps play into** (an output to them) becomes a strip in the mixer. Make it the default output, and everything the Mac plays comes through it: you can EQ it, duck it under your voice, and send it to your headphones and your stream at different levels.
- One that **apps record from** (an input to them) is an output in the mixer: whatever you route to it is what the app records. Choose it as the microphone in OBS, Zoom, Discord or a browser.

Create, rename and delete them in **Setup → Virtual devices**. They run at the engine's sample rate and are kept across restarts.

### Mix buses

<!-- keywords: bus, submix, group, stream mix -->

A mix bus adds up what's routed to it and sends the result on. Use one for each mix you need: the stream (mics and music), a monitor mix, a recording. Add one in **Setup → Add a mix bus**. A bus has a fader, mute, cue and effects like a strip; its effects come after its fader.

### Routing

<!-- keywords: route, send, routing grid, level, destination -->

- **On a strip**: the **Route** button under the M and C buttons says where it goes ("→ Stream, M2 Out"), or "Route" in grey if nowhere. Click it for every bus and output it can feed: tick as many as you like. A route starts at 0 dB; its menu sets 0, −3, −6, −12 or −20 dB.
- **In the Routing tab**: every route at once. Click a cell to turn a route on (0 dB) or off; scroll on it to change its level; right-click it for a level.

Strips go to buses and outputs; buses go to outputs. Sound only moves forward, so there can't be a loop.

### Scenes

<!-- keywords: scene, snapshot, recall, save mix, switch setup -->

A scene is the whole mix: every strip's, bus's and output's level, mute, routes and effects (plugins' settings included), and the Mac's default output and input. Use them to switch between setups: "Radio", "Streaming", "Calls".

- The **Scenes** menu in the top bar shows the scene in use. **Save Mix as Scene…** saves the mix under a name; **Update "…" with This Mix** saves your changes into the scene in use; **Delete** removes one.
- Loading a scene never adds, removes or restarts anything, so it's safe while you're live. Strips are found by name, so a scene still lands right after you've added, removed or reordered strips; anything it doesn't know is left alone.
- Scenes are kept one file each in `~/Library/Application Support/PatchPrimeMac/scenes/`, easy to copy or back up.

### Mini window

<!-- keywords: mini, compact, small window, overview -->

The mini window button (two arrows pressing together, beside Scenes) shrinks the window to one strip wide: each strip, bus and output is a row with **M**, its name and level, a slider and a thin meter. The slider works like a fader: double-click for 0 dB, scroll to adjust. The button at its top right goes back to the full mixer.

The full and mini windows each remember their own size and place, and the app opens in the one you left it in.

## Monitoring and meters

### Cue (headphones)

<!-- keywords: cue, solo, pfl, afl, headphones, monitor, listen -->

Cue lets you hear one thing alone, in your headphones, without changing the mix.

- Choose the **cue output** in the **CUE** bar above the mixer: usually your headphones. **C** buttons then appear on every strip, bus and output.
- While anything is cued, the cue output plays only what's cued, at the cue level, instead of its own mix. Its strip shows **C ON**. Cue several things and you hear them together. **Clear Cue** uncues everything.
- **PFL** (pre-fade listen, the default) is before the fader and after a strip's effects: you can check a mic that's muted or faded down, processed as it will sound. **AFL** (after-fade listen) is after the fader.
- Switching in and out of cue crossfades, so it never clicks. The cue output's safety limiter still applies.
- What's cued isn't saved, or kept in scenes; the cue output, level and PFL/AFL are.

### Meters

<!-- keywords: meter, level, dbfs, peak, clip -->

Each strip's meter shows its peak level after its effects and fader, from −60 to 0 dBFS: green, yellow near the top, red at the top. An output's meter shows what leaves it, after its effects and safety limiter. Meters cost nothing when the window is closed.

## Effects

What each effect does and how to set it. Effects run in a chain on a strip, bus or output, and save with it, in presets and in scenes.

### Working with effects

<!-- keywords: chain, insert, bypass, all effects, order, add effect, meters, meter bridge, gain reduction, gr, threshold, knob, graph, curve, slider, spinner -->

Click **FX** on a strip to open its effects. On an input strip the effects come before the fader, so apps recording a bus the strip feeds get the processed sound; on a bus or output they come after the fader.

- **Add Effect** adds an effect at the end of the chain: a built-in one, or **Plugins…** for an Audio Unit (see [Plugins](#plugins-audio-units)). A chain can have up to eight.
- Effects run top to bottom. Move them with the arrows; remove one with the bin.
- The **switch** on each effect turns it on or bypasses it, crossfading so it doesn't click. **All effects**, at the top, bypasses every effect at once and brings back the ones that were on.
- **Knobs**, grouped by what they do (Detection, Timing, Output and so on): drag up or down, scroll (Option, Command or the thumb wheel for fine steps), or double-click to reset to the effect's starting value. Knobs for a range either side of zero (gain, makeup) fill from the middle. Plugins, the EQ's band table and the multiband compressor's bands keep their sliders and number fields.
- **A picture of what it does**, beside the knobs: for the gate, expander, compressor and limiter, the level in (across) against the level out (up), with a dot at the level going in now; the ducker's dip over time; the de-esser's band; the leveler's target, window and freeze on a loudness scale, with the loudness now; the reverb's tail; the multiband compressor's four bands, each dropping as it's turned down. The compressor has **One knob** (Amount) or **Full controls**.
- **Number fields** (the EQ's and multiband's bands): type a value and press Return (`3.5k` works for 3.5 kHz), click the arrows, or scroll.
- **Meters**, beside each effect's controls, like a console's meter bridge: **IN** and **OUT** for each channel (the light part is the peak, the solid part the average), and **GR**, how much it's turning the sound down (gate, expander, compressor, de-esser, limiter, ducker, multiband). The leveler shows **GAIN**, its boost or cut, and the ducker its **KEY** (the strip it listens to). The scale runs from 0 down to −80 dB, with each meter's peak in dB under it. A line across a meter marks the setting it's compared with: the threshold of the gate, expander and compressor on **IN**, the limiter's ceiling on **IN** and **OUT**, the ducker's threshold on **KEY**; hover over it for the value. Noise suppression also shows its **Voice** and the leveler its **Loudness**. Measuring costs a little, so it only happens while the effects window is open and can be seen (not minimised or covered).
- **Muted strips cost nothing:** once a mute (or a fader at the bottom) has faded the sound out, its effects stop, and start again clean when you unmute. A chain with a reverb keeps running, so its tail isn't frozen.
- **Mono sources** (a single microphone channel) run their effects once rather than on both sides, which halves their cost; a chain with a reverb or leveler stays stereo.

### Parametric EQ

<!-- keywords: equaliser, equalizer, filter, bell, shelf, low cut, high pass, tone, frequency, curve -->

Six bands. Each can be a bell, a low or high shelf, or a low or high cut (12 dB per octave).

- **On the curve:** the white line is the whole EQ; each band shows faintly in its colour. Drag a numbered handle left and right for frequency, and up and down for gain. Scroll on it to make the band narrower or wider (Q). Double-click it to set its gain to 0 dB.
- **In the table:** each band's on/off, type, frequency, gain and Q. A step is a semitone of frequency, half a dB of gain, about 6 % of Q.

A new EQ is flat: a low shelf at 80 Hz, bells at 250 Hz, 1 kHz, 3 kHz and 6 kHz, and a high shelf at 12 kHz.

### Compressor

<!-- keywords: dynamics, amount, ratio, attack, release, makeup, voice -->

Evens out a voice: loud words are turned down, so the quiet ones can come up. It's one knob, **Amount**: 0 % does nothing, 40 % is a light touch for speech, 100 % is heavy, radio-style. The knob sets the threshold, ratio, attack, release and makeup gain together, so your voice comes out about as loud as it went in, only steadier.

Choose **Full controls** for the controls themselves: **Threshold**, **Ratio**, **Attack**, **Release** and **Makeup**. They start where the knob was, so nothing jumps.

### De-esser

<!-- keywords: sibilance, harsh, ess, s sounds -->

Softens harsh "s", "sh" and "t" sounds without dulling the voice. It watches the sound above **Frequency** (6 kHz to start), and while that's over **Threshold** it turns down only that part, by up to **Range** dB.

To set it up, turn on **Listen**: you hear only the part it watches. Move **Frequency** until the "s" sounds stand out most (usually 5–8 kHz; lower for deeper voices), turn Listen off, then lower **Threshold** until it moves on the "s" sounds and stays still on the rest.

### Expander

<!-- keywords: downward expansion, noise, breaths, room -->

A gentler noise gate: below **Threshold** it turns the sound down gradually instead of shutting it. With **Ratio** 1:2, a sound 10 dB under the threshold comes out 20 dB under; **Range** is the most it will cut. Breaths and room sound between words drop away while the ends of words still trail off naturally.

### Multiband compressor

<!-- keywords: bands, crossover, dynamics -->

Splits the sound into four bands at three crossovers (120 Hz, 1 kHz and 6 kHz to start) and compresses each separately. Per band: threshold, ratio, attack, release and makeup; **On** turns a band's compression off; **Solo** lets you hear only the soloed bands while setting them up. With nothing compressing, the bands add back up to the original exactly.

### Noise gate

<!-- keywords: gate, threshold, background noise, keyboard noise -->

Turns the sound down by **Range** when it falls below **Threshold**, so breaths, keyboard and room noise between words don't come through. **Attack**, **Hold** and **Release** set how fast it opens, how long it stays open after you stop, and how fast it closes. Watch IN while you're quiet and while you talk, and put the threshold between the two.

### Noise suppression

<!-- keywords: denoise, rnnoise, fan, hum, neural, background noise -->

Takes fans, hum and room noise out of a voice with RNNoise, a small neural network from Xiph.Org. **Amount** blends the cleaned voice with the original; 100 % is fully cleaned. The **Voice** meter shows how sure it is that it hears a voice. It adds 10 ms of delay and works at 48 kHz (at other sample rates it passes the sound through, and says so).

### Ducker

<!-- keywords: ducking, sidechain, side chain, key, dip music, talk over -->

Turns this strip down by **Depth** while the strip it **listens to** is above **Threshold**: music that dips while you talk. Choose that strip in the effect's **Listens to** menu. **Attack**, **Hold** and **Release** shape the dip. The **KEY** meter shows the level it listens to.

It hears the other strip after that strip's own effects and fader, so with noise suppression or a gate on your mic, it dips for your voice and not the room. A strip can't duck under itself, or under a strip that ducks under it: that would be a loop, and PatchPrimeMac refuses it.

### Broadcast leveler

<!-- keywords: agc, automatic gain, loudness, lufs, leveller -->

Slowly turns the sound up or down so it sits at a steady loudness, like a radio station's processing. **Target** is the loudness to aim for, in LUFS (about −16 for streams and podcasts); **Max boost** and **Max cut**, how far it may go; **Speed**, how many seconds a change takes; **Freeze below**, the level under which it holds still, so silence isn't turned up.

### Safety limiter

<!-- keywords: limit, clipping, ceiling, true peak, brickwall, protection -->

Nothing leaves above the **Ceiling** (−1 dB to start). It looks 1.5 ms ahead, so peaks are caught before they arrive instead of being clipped. **Release** sets how fast it recovers. With **True peak** on, it also catches the peaks that form between samples once the sound is played back or encoded; turn it on for anything you publish.

Every hardware output also has a safety limiter of its own, at −6 dBFS, that you can't remove: it's what stands between a routing mistake and your speakers.

### Reverb

<!-- keywords: room, echo, ambience, tail -->

An algorithmic reverb. **Size** and **Decay** set the room and how long the tail lasts; **Pre-delay**, a gap before it starts, which keeps a voice clear; **Damping**, how quickly the highs die away; **Width**, from mono to wide; **Mix**, how much you hear. Bypassing it lets the tail ring out instead of cutting it off.

### Delay (line up outputs)

<!-- keywords: sync, bluetooth, hdmi, lip sync, align -->

Delays the sound by up to one second. Use it on a fast output to line it up with a slow one, such as Bluetooth headphones or an HDMI TV.

### Gain

<!-- keywords: trim, boost, preamp -->

A plain level trim, ±24 dB.

### Presets

<!-- keywords: chain preset, effect preset, voice, podcast voice, streaming voice, radio voice, natural voice, noisy room -->

- **Chain presets:** the **Presets** menu at the top of the effects window loads a whole chain, replacing what's there, or saves this one (**Save Chain as Preset…**). It also has ready-made chains for a microphone: **Podcast voice**, **Streaming voice**, **Noisy room**, **Radio voice** and **Natural voice**. Load one, adjust it, and save it as your own.
- **Effect presets:** the list icon on each effect saves just that effect's settings, and loads them onto any effect of the same kind.
- Loading a preset sets every setting: anything the preset doesn't mention goes back to its starting value. Plugins' presets keep the plugin's own settings too.
- Presets are kept in `~/Library/Application Support/PatchPrimeMac/presets.json`.

### Plugins (Audio Units)

<!-- keywords: plugin, audio unit, au, waves, melda, scan, browser, filter, crash, plugin window, vst, clap -->

Besides the built-in effects, any chain can run **Audio Unit** effects: Waves, MeldaProduction, Apple's own, and others you have installed. (VST3 and CLAP are planned.)

- **The browser** (Setup → Plugins → **Browse…**) lists every plugin installed, by format (AU), maker, name and category. Search it, sort it by any column, and hide what you don't want: a plugin, everything by a maker, or a category (right-click), or whole kinds such as instruments (**Kinds**). Hidden plugins aren't offered or scanned. Waves plugins appear once each; the mono or stereo version is chosen to match the strip.
- **Scanning** (Setup → Plugins): **Scan New** checks plugins that are new or updated since the last scan; **Rescan All** checks everything again. A scan loads each plugin to be sure it works, four at a time in the background, so it never disturbs your audio. A plugin that hangs or crashes is marked and skipped until it's updated. Scanning only happens when you start it.
- **Adding one:** in the effects window, **Add Effect → Plugins…**. Double-click a plugin, or select it and press **Add**. Plugins the scan found broken, or that only come in surround versions, aren't offered. It takes under a second to start; until then the strip plays as if it weren't there.
- **Its window:** **Open Window** on the plugin shows its own controls. What you change there is saved with the chain, in presets and in scenes.
- **Plugins run apart from the engine.** macOS runs them in a process of its own, so a plugin that crashes can't take your audio down: the affected strip plays without it for a moment while it's loaded again with its settings, and everything else carries on.
- Each plugin costs what its processing costs, plus a few hundredths of a millisecond for running apart. The built-in effects remain the lightest choice.

## Recording

### Recording a strip

<!-- keywords: record, rec, capture, flac, wav, aac, m4a, raw, processed, music folder, file format -->

Any input, mix bus or output can be recorded to a file. Press **REC** at the bottom of its strip; it turns red and shows the time. Press it again to stop. Several can record at once.

- **What's recorded:** a mix bus or an output records what it sends on, after its effects and fader; so does a strip apps play into (Desktop). A hardware **input** (a microphone) records either **raw**, the sound as the device sends it, before the strip's effects and fader (the default; for processing later, or for tuning its effects), or **processed**, after them, as the mix hears it. Choose with **Inputs** in the Recordings window; it applies at once, also to a recording already running. A mono input records a mono file.
- **Where:** `~/Music/PatchPrimeMac`, named after the strip and the time: `Mix A 2026-11-08 14-30-07.flac`.
- **Format:** **FLAC** is lossless at about half the size of WAV; **WAV** is uncompressed; both are 24-bit. **AAC** (.m4a) is small and plays everywhere, up to 48 kHz (at a higher sample rate, choose FLAC or WAV). The format applies to the next recording.
- **In time:** effects that make the sound a little late (noise suppression by 10 ms, plugins by what they report) are allowed for: a recording after a chain's effects leaves that much off its start and adds as much silence at its end, so it lines up with real time and with the other tracks of a take.
- The engine does the recording, so it carries on with the window closed. It stops if the engine restarts (a sample rate or buffer change, or macOS's audio system restarting); what was recorded until then is kept.

### Multitrack takes

<!-- keywords: multitrack, take, arm, tracks, audacity, reaper, logic, podcast, sample aligned -->

A take records several strips at once, each to its own file, all starting on the same sample, so they line up as tracks in Logic, Reaper or Audacity: your mic raw, a guest, and the stream mix, say, to fix the levels or the edit afterwards.

1. In the **Recordings** window, turn on **Multitrack**. The strips' **REC** buttons now read **ARM**.
2. Click **ARM** on each strip you want; armed ones are outlined in red. They stay armed until you click again.
3. Press **Record Take**. Every armed strip records and shows its time. Press **Stop Take**, or any of its strips' buttons, to stop them all.

Each take gets a folder, `Take 2026-11-08 14-30-00`, with one file per strip named after it: `RE20b.flac`, `Mix A.flac`. For a summed stereo track, arm a mix bus the strips are sent to.

### Your recordings and the player

<!-- keywords: recordings list, playback, play into, loop, seek, finder, trash, delete, open folder -->

The **Recordings** window (the **Recordings** button in the top bar) lists them newest first, with their length, size and when they were made; a take's tracks show its name.

- **Double-click** one, or select it and press play, to play it. The player has play and pause, stop, **loop** (over and over, without a gap), and a position slider: drag it to jump.
- **Play into** chooses where it plays. A **mix bus** or an **output**: it's added to what's there: into the bus your stream hears, say, or into your headphones' output to listen alone. An **input**: in place of its device (see below). It plays at the mixer's sample rate, whatever the file's.
- Right-click for **Open in Its Usual App**, **Show in Finder** and **Move to Trash** (from where you can put it back); a take's folder goes when its last track does. **Open Folder** opens the recordings folder.

### Setting up a mic's effects on a recording

<!-- keywords: tune, adjust, effects, loop, playback through effects, test recording -->

You can't really hear your own voice while you talk, so setting a gate or a compressor live is guesswork. Instead:

1. With **Inputs** on **Raw** (the default), press **REC** on the mic's strip, talk for half a minute the way you usually do, and stop.
2. In the Recordings window, choose the mic in **Play into** ("RE20b (instead of the device)"), turn on **loop**, and play the recording.
3. While it plays, the strip hears the recording instead of the microphone, through its whole effects chain, fader and sends, exactly as your voice would go.
4. Open its effects and adjust them while you listen (cue the strip, or listen on an output it's sent to). Stop the player when you're done: the microphone is back at once.

Mind what the strip is sent to while you do this: the recording goes wherever the mic goes.

## Engine and devices

### Sample rate and buffer size

<!-- keywords: sample rate, 44.1, 48, 96, 192, buffer, latency, frames -->

**Setup → Audio**:

- **Sample rate**: 44.1, 48, 96 or 192 kHz. The virtual devices always run at this rate. A hardware device switches to it if it can, unless you tick **Keep its own rate**; one that can't is converted (resampled), and says so.
- **Buffer size**: 32 to 1024 frames. Smaller means less delay and more work for the Mac; 128 is a good start. Each device can have its own (a slow USB device may need more).
- Changing either restarts the engine: the sound stops for a moment. You're asked first.

### Clock

<!-- keywords: clock, sync, drift, master clock, word clock -->

Every audio device has its own clock, and no two run at exactly the same speed. PatchPrimeMac keeps each device in step with the engine by converting its sample rate by tiny amounts, so nothing drifts, clicks or drops out over hours. By default the engine keeps its own steady time (**Patch Prime**); in **Setup → Clock** you can have it follow a device's clock instead, such as your main interface.

### When devices come and go

<!-- keywords: unplug, plug in, offline, hot plug, usb, switch off, recover -->

When a device is unplugged or switched off, its strips and outputs stay in the mixer, marked **OFFLINE**, and everything else carries on as if nothing happened. When it comes back, it's picked up again by itself, with its routing, levels and effects. Devices are recognised by their serial number where they have one, so a device that comes back with a different name inside macOS is still found.

Some devices show up in macOS twice under one name: an input half and an output half (a radio's USB codec, for example). PatchPrimeMac uses the right half for a strip and for an output; if one was set up on the wrong half, it shows as OFFLINE with a note saying which to choose.

### Hardware output and the safety limit

<!-- keywords: hardware output, amplifier, speakers, safety, limit, -6 dbfs -->

**Hardware Output** (top right) is off until you turn it on, so nothing reaches real speakers until you've checked your levels. With it on, each hardware output passes through a safety limiter at −6 dBFS, and a hard limit behind that.

### Where your settings are

<!-- keywords: settings, files, backup, application support, logs -->

- Settings: `~/Library/Application Support/PatchPrimeMac/settings.json`, with the last five versions kept beside it. If the file is ever damaged, the newest good copy is loaded and the damaged one kept aside.
- Presets: `presets.json`; scenes: the `scenes` folder; the plugin scan: `plugin-cache.json`, all in the same folder.
- The engine's log: `~/Library/Logs/PatchPrimeMac/`.

## The command line

<!-- keywords: patchprime-ctl, terminal, script, automation, stream deck -->

`patchprime-ctl` talks to the engine from Terminal or a script (a Stream Deck button, say). `patchprime-ctl help` lists everything. A few:

- `patchprime-ctl status`: the engine, devices, levels and clock.
- `patchprime-ctl mute strip 0 on`, `patchprime-ctl gain out 1 0.5`.
- `patchprime-ctl scene-load Streaming`.
- `patchprime-ctl cue strip 0 on`.
- `patchprime-ctl record bus 0` starts or stops recording a bus; `patchprime-ctl take` starts or stops a multitrack take.
- `patchprime-ctl play-into bus 0`, then `patchprime-ctl play ~/Music/PatchPrimeMac/<file>`; `play-pause on|off`, `play-stop`.

## Uninstalling

<!-- keywords: uninstall, remove, delete, clean -->

Run **Uninstall PatchPrimeMac** from the DMG (or the uninstaller in the app's Help menu). It asks for your password, then removes everything PatchPrimeMac added: the app, the engine, the driver, its settings in macOS's audio system, its logs, caches and crash reports, and its permissions. The default output and input go back to the devices they were before. You choose whether to keep your settings, presets and scenes.

**All sound on the Mac stops for a moment** while macOS's audio system restarts without the driver.

## Troubleshooting

<!-- keywords: problem, no sound, silent, not working, help, fix -->

- **No sound at all:** is the engine running (top bar, or the menu bar icon)? Is **Hardware Output** on? Is the strip routed to an output (its Route button), and that output not muted? If the Mac's default output is a virtual device and the engine isn't running, nothing plays: pick your speakers in **System Settings → Sound** to get sound back, then restart PatchPrimeMac.
- **A microphone shows NO SIGNAL:** check the channel has the mic on it, and that PatchPrimeMac is allowed in **System Settings → Privacy & Security → Microphone** (after an update, macOS asks again; if you missed the prompt, turn PatchPrimeMac on there).
- **A strip shows OFFLINE:** its device isn't there. Plug it in or switch it on; it comes back by itself.
- **Clicks or dropouts:** try a bigger buffer size (Setup → Audio). `patchprime-ctl status` shows underruns, if any.
- **A plugin shows a note:** it didn't load, or its process stopped and it's being loaded again. The note says which.
- **The scan reports a plugin as failed:** it won't load out of process, or not at 48 kHz, or not in mono or stereo. It's left out of the plugin list; Rescan All tries again.

## Privacy

<!-- keywords: privacy, network, data, microphone permission -->

PatchPrimeMac doesn't connect to the internet, collect anything or send anything anywhere. Your microphones' sound goes only where you route it. macOS asks your permission before the engine can use a microphone.
