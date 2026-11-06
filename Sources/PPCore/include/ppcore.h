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

PPEngine *pp_engine_create(unsigned int hiddenDevice, double sampleRate);
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
double pp_engine_input_ratio_ppm(PPEngine *e, int input);
double pp_engine_output_ratio_ppm(PPEngine *e, int output);

// The clock bridge, exposed for the offline tests.
typedef struct PPBridge PPBridge;
PPBridge *pp_bridge_create(double rate, int producerBlock, int consumerBlock, double savedPpm);
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
