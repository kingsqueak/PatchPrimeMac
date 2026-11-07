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
