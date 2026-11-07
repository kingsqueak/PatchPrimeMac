// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The built-in effects (Patch Prime's patchprime-dsp) as a plain C API, for the
// engine and for Swift. One PPFx holds the effect chain of one strip, bus or
// output. Functions marked [RT] are for the audio thread; the rest are for one
// control thread.

#ifndef PPDSP_H
#define PPDSP_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PPFx PPFx;

PPFx *pp_fx_create(void);
// Only once the audio thread can no longer call pp_fx_process on it.
void pp_fx_destroy(PPFx *fx);

// Sets the chain from a spec, one effect per line:
//   <type> TAB <1 on | 0 bypassed> TAB <name>=<value>;<name>=<value>...
// An empty spec means no effects. When the types and their order are the same as
// now, parameters change in place, gliding where the effect does; otherwise a new
// chain is built for `rate` and swapped in without stopping audio. Returns the
// number of effects running, or -1 if the spec couldn't be read.
int pp_fx_set(PPFx *fx, const char *spec, double rate);
// The same for a mono source (left and right the same): the chain runs on one
// channel, half the work, and the result goes to both. A change between mono and
// stereo builds a new chain.
int pp_fx_set_channels(PPFx *fx, const char *spec, double rate, int channels);
// Frees chains the audio thread has finished with. Call now and then.
void pp_fx_collect(PPFx *fx);
// [RT] Runs the chain on stereo audio in place. Without a chain, does nothing.
void pp_fx_process(PPFx *fx, float *left, float *right, int frames);
// [RT] The same, with a key: another strip's sound, mono, `frames` long, for a ducker.
// Null when there's none (a ducker then does nothing).
void pp_fx_process_keyed(PPFx *fx, float *left, float *right, int frames, const float *key);
// Whether any chain is set.
int pp_fx_active(const PPFx *fx);
// Samples of delay the effects that are on add, together.
int pp_fx_latency(const PPFx *fx);

// Per-effect levels, for meters in an editor; measuring costs a little, so it's off
// until turned on. Fills, for each effect, inPeak, outPeak (linear, both channels'
// highest since the last call): 2 floats each. Returns the number of effects.
void pp_fx_set_metering(PPFx *fx, int on);
int pp_fx_take_levels(PPFx *fx, float *out, int maxEffects);
// The key's peak (linear) as of the last pp_fx_take_levels, or -1 if no key came.
float pp_fx_key_peak(const PPFx *fx);
// An effect's own meters (gain reduction per band, say), since the last call.
int pp_fx_take_meters(PPFx *fx, int effect, float *out, int max);

// What the compressor's one knob stands for at `amount` (0-100 %): threshold (dB),
// ratio, attack (ms), release (ms), makeup (dB). When "advanced" is switched on, its
// own controls start from these, so the sound doesn't jump.
void pp_fx_compressor_knob(double amount, double out[5]);

// The EQ's response in dB at each of `count` frequencies, for drawing its curve: the
// same filters the engine runs. `params` is the effect's "name=value;..." (as in a
// spec line); bands it doesn't mention take their defaults. `band` 1-6 gives that
// band alone (whether or not it's on), 0 all the bands that are on.
void pp_fx_eq_curve(const char *params, int band, double rate, const double *freqs, double *dbOut, int count);

// Every built-in effect type with its label and parameters, as JSON:
// [{"type","label","key":bool,"params":[{"name","label","unit","min","max",
//   "initial","kind","options":[...]}]}]. Free with pp_fx_free_string.
char *pp_fx_catalog_json(void);
void pp_fx_free_string(char *text);

#ifdef __cplusplus
}
#endif

#endif
