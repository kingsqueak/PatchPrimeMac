// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The realtime core, as a plain C API for Swift. Functions marked [RT] are for the
// audio thread: they never allocate, lock or call into the system. Every other
// function is for a control thread, and is safe to call while audio runs.

#ifndef PPCORE_H
#define PPCORE_H

#ifdef __cplusplus
extern "C" {
#endif

// Sizes. Every signal is stereo. Mono sources use the same left and right.
enum {
    PP_MAX_INPUTS = 32,
    PP_MAX_BUSES = 16,
    PP_MAX_OUTPUTS = 32,
    PP_MAX_BLOCK = 4096,
};

typedef struct PPMixer PPMixer;
typedef struct PPFx PPFx; // see ppdsp.h

enum { PP_KIND_STRIP = 0, PP_KIND_BUS = 1, PP_KIND_OUTPUT = 2 };

PPMixer *pp_mixer_create(double sampleRate);
void pp_mixer_destroy(PPMixer *mixer);

// Recording. A tap takes a copy of one strip's, bus's or output's sound, block by
// block, into a lock-free queue that a writer thread empties with pp_tap_read. A
// strip's tap takes its sound before its effects (raw) or after its effects and
// fader (processed); a bus's or output's, after its effects. A tap records the
// blocks from its window's start until its stop (not included), so taps given the
// same window start on the same sample. Blocks are counted by pp_mixer_block.
typedef struct PPTap PPTap;
PPTap *pp_tap_create(int channels, int capacityFrames); // channels 1 (the left) or 2
void pp_tap_destroy(PPTap *tap); // once it's detached and the audio thread is past it
void pp_tap_set_window(PPTap *tap, unsigned long long startBlock, unsigned long long stopBlock);
void pp_tap_stop_at(PPTap *tap, unsigned long long stopBlock);
void pp_tap_set_processed(PPTap *tap, int processed);
void pp_tap_end(PPTap *tap); // the mixer is gone: nothing more will come
int pp_tap_channels(const PPTap *tap);
int pp_tap_read(PPTap *tap, float *interleaved, int maxFrames); // frames read
int pp_tap_finished(const PPTap *tap); // past its stop, and everything read
unsigned long long pp_tap_dropped(const PPTap *tap); // frames lost to a slow disk
// One tap per strip, bus or output. Returns 0, or -1 if one is attached already.
int pp_mixer_attach_tap(PPMixer *m, int kind, int slot, PPTap *tap);
void pp_mixer_detach_tap(PPMixer *m, int kind, int slot);
unsigned long long pp_mixer_block(const PPMixer *m);

// Playback. A feed is stereo audio a reader thread queues (pp_feed_write) and the
// mixer plays into one strip, bus or output: into a strip in place of its device
// (so its effects can be set up on a recording), added into a bus or output. Silence
// where nothing is queued, and while paused (keeping its place). Up to PP_MAX_FEEDS at
// once, each in a slot of its own: the player's and the soundboard's pads.
typedef struct PPFeed PPFeed;
PPFeed *pp_feed_create(int capacityFrames);
void pp_feed_destroy(PPFeed *feed); // once it's off the mixer and the audio thread is past it
int pp_feed_space(const PPFeed *feed); // frames
int pp_feed_write(PPFeed *feed, const float *stereo, int frames); // frames queued
void pp_feed_set_paused(PPFeed *feed, int paused);
void pp_feed_set_gain(PPFeed *feed, float gain); // linear; 1 as it is
void pp_feed_end(PPFeed *feed); // nothing more will be queued
int pp_feed_finished(const PPFeed *feed); // ended, and everything played
unsigned long long pp_feed_played(const PPFeed *feed); // frames since the last flush
// Seeking: drop what's queued. The audio thread does it on its next block;
// pp_feed_flushed says when, for the ticket pp_feed_flush returned.
unsigned int pp_feed_flush(PPFeed *feed);
int pp_feed_flushed(const PPFeed *feed, unsigned int ticket);
// Plays feed into a strip, bus or output (or nothing, with a null feed), in slot
// `index` (0 to PP_MAX_FEEDS - 1).
enum { PP_MAX_FEEDS = 17 };
void pp_mixer_set_feed(PPMixer *m, int index, PPFeed *feed, int kind, int slot);

// Faders, in linear gain. All changes glide over about 10 ms, so nothing clicks.
void pp_mixer_set_input_gain(PPMixer *m, int input, float gain);
void pp_mixer_set_input_mute(PPMixer *m, int input, int muted);
void pp_mixer_set_bus_gain(PPMixer *m, int bus, float gain);
void pp_mixer_set_bus_mute(PPMixer *m, int bus, int muted);
void pp_mixer_set_output_gain(PPMixer *m, int output, float gain);
void pp_mixer_set_output_mute(PPMixer *m, int output, int muted);

// Routing. A gain of 0 means no route. Signals only move forward, input to bus,
// bus to output, or input straight to output, so a loop can't be made.
void pp_mixer_set_input_to_bus(PPMixer *m, int input, int bus, float gain);
void pp_mixer_set_input_to_output(PPMixer *m, int input, int output, float gain);
void pp_mixer_set_bus_to_output(PPMixer *m, int bus, int output, float gain);

// Whether a slot is in use, so the block skips idle ones.
void pp_mixer_set_input_active(PPMixer *m, int input, int active);
void pp_mixer_set_bus_active(PPMixer *m, int bus, int active);
void pp_mixer_set_output_active(PPMixer *m, int output, int active);

// Effects (Patch Prime's built-ins): on a strip before its fader, on a bus or an
// output after it. The spec is pp_fx_set's (ppdsp.h). Returns the number of
// effects running, or -1. Call pp_mixer_collect now and then to free old chains.
int pp_mixer_set_effects(PPMixer *m, int kind, int slot, const char *spec);
PPFx *pp_mixer_effects(PPMixer *m, int kind, int slot);
// A strip whose source is one channel (the same on left and right): its effects run
// once, on one channel. Takes effect with the next pp_mixer_set_effects.
void pp_mixer_set_input_mono(PPMixer *m, int input, int mono);
void pp_mixer_collect(PPMixer *m);
// The input strip a chain's ducker listens to (its key), or -1 for none. The key is
// that strip's sound after its effects and fader, in mono. A strip can't be its own
// key, and keys can't go round in a loop: -1 or -2 is returned and nothing changes.
int pp_mixer_set_key(PPMixer *m, int kind, int slot, int fromInput);
// Cue (solo in the headphones). While anything is cued, the cue output plays what's
// cued, at the cue level, instead of its own mix: before each one's fader (PFL; a
// strip's after its effects) or after it (AFL). -1 turns cue off. Switching in and
// out crossfades, and the cue output's safety limiter still applies.
void pp_mixer_set_cue_output(PPMixer *m, int output);
void pp_mixer_set_cue_level(PPMixer *m, float gain);
void pp_mixer_set_cue_pre_fader(PPMixer *m, int pre);
void pp_mixer_set_cued(PPMixer *m, int kind, int slot, int cued);
// A limiter on an output that reaches hardware, after its own effects: true peak,
// 1.5 ms lookahead, at ceilingDb (below 0). 0 turns it off. The hard clip in the
// engine stays behind it as the last resort.
void pp_mixer_set_output_safety(PPMixer *m, int output, float ceilingDb);

// [RT] One block. Before it, write each active input into pp_mixer_input_left and
// right. After it, read each active output from pp_mixer_output_left and right.
float *pp_mixer_input_left(PPMixer *m, int input);
float *pp_mixer_input_right(PPMixer *m, int input);
const float *pp_mixer_output_left(const PPMixer *m, int output);
const float *pp_mixer_output_right(const PPMixer *m, int output);
void pp_mixer_process(PPMixer *m, int frames);

// Meters, after the fader and the mute. Peaks are the highest since the last read,
// so a reader never misses one. Levels are linear.
typedef struct PPMeter {
    float peakLeft;
    float peakRight;
} PPMeter;
PPMeter pp_mixer_read_input_meter(PPMixer *m, int input);
PPMeter pp_mixer_read_bus_meter(PPMixer *m, int bus);
PPMeter pp_mixer_read_output_meter(PPMixer *m, int output);

// The engine. Hardware outputs stay muted until pp_engine_enable_hardware_output.
typedef struct PPEngine PPEngine;
typedef struct PPEngineStats {
    unsigned long long cycles;
    unsigned long long underruns;
    unsigned long long overruns;
    unsigned long long resyncs;
    double maxGapMs;
    float hardwarePeak; // the highest sample written to any hardware output
    int devices;
} PPEngineStats;

// The engine runs at `sampleRate` in blocks of `block` frames, on the hidden device.
// To change either, destroy it and create another. Each hardware device keeps its
// own rate and buffer, read when it's first opened; set them before binding.
PPEngine *pp_engine_create(unsigned int hiddenDevice, double sampleRate, int block);
void pp_engine_destroy(PPEngine *e);
PPMixer *pp_engine_mixer(PPEngine *e);
int pp_engine_start(PPEngine *e);
void pp_engine_enable_hardware_output(PPEngine *e, int enabled, float limit);
void pp_engine_bind_input_virtual(PPEngine *e, int input, int slot);
void pp_engine_bind_output_virtual(PPEngine *e, int output, int slot);
int pp_engine_bind_input_device(PPEngine *e, int input, unsigned int device, int left, int right, double savedPpm);
int pp_engine_bind_output_device(PPEngine *e, int output, unsigned int device, int left, int right, double savedPpm);
void pp_engine_unbind_input(PPEngine *e, int input);
void pp_engine_unbind_output(PPEngine *e, int output);
void pp_engine_device_lost(PPEngine *e, unsigned int device);
PPEngineStats pp_engine_stats(PPEngine *e);
// The newest time and sample position of an open device. 0 if it isn't open.
int pp_engine_device_clock(PPEngine *e, unsigned int device, double *seconds, double *sample);
double pp_engine_input_ratio_ppm(PPEngine *e, int input);
double pp_engine_output_ratio_ppm(PPEngine *e, int output);

int pp_shm_open(const char *name, int flags, int mode);

// An Audio Unit in a chain (see au.cpp). The caller loads it, sets its stream formats
// (planar float, `inputs` and `outputs` channels at the engine's rate), its maximum
// frames, and initialises it; then attaches pp_au_external to the chain's slot with
// pp_fx_attach. Destroy only once it's detached and the audio thread is past it, and
// before disposing of the AudioUnit.
typedef struct PPAU PPAU;
struct PPExternal;
// It renders on a realtime worker thread of its own; the engine waits at most half a
// block for it, else that block is dry.
PPAU *pp_au_create(void *audioUnit, int inputs, int outputs, int maxFrames, int latencySamples, double sampleRate);
const struct PPExternal *pp_au_external(PPAU *au);
void pp_au_destroy(PPAU *au);
// From any thread: its process has gone (the system said so); stop calling it at once.
void pp_au_mark_gone(PPAU *au);
// The first render call's time, the slowest's, and how many (for diagnosis).
void pp_au_timing(const PPAU *au, double *firstMs, double *slowestMs, unsigned long long *calls);
// Blocks the engine played dry because the plugin wasn't back in time.
unsigned long long pp_au_late(const PPAU *au);

// The clock bridge, exposed for the offline tests.
typedef struct PPBridge PPBridge;
PPBridge *pp_bridge_create(double producerRate, double consumerRate, int producerBlock,
    int consumerBlock, double savedPpm);
void pp_bridge_destroy(PPBridge *b);
void pp_bridge_write(PPBridge *b, const float *left, const float *right, int frames, double seconds);
void pp_bridge_read(PPBridge *b, float *left, float *right, int frames, double seconds);
double pp_bridge_ratio_ppm(const PPBridge *b);
double pp_bridge_position(const PPBridge *b);
double pp_bridge_target(const PPBridge *b);
unsigned long long pp_bridge_underruns(const PPBridge *b);
unsigned long long pp_bridge_overruns(const PPBridge *b);
unsigned long long pp_bridge_resyncs(const PPBridge *b);

#ifdef __cplusplus
}
#endif

#endif
