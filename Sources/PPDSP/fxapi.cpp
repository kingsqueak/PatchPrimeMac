// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The C API over Patch Prime's effects. Building and updating a chain follow
// buildChain() and updateChain() in Patch Prime's busmanager.cpp.

#include "effects.h"
#include "eq.h"
#include "voice.h"
#include "ppdsp.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace {

struct Spec
{
    std::string type;
    bool enabled = true;
    std::map<std::string, double> params;
};

bool parse(const char *text, std::vector<Spec> &out)
{
    std::istringstream lines(text ? text : "");
    std::string line;
    while (std::getline(lines, line)) {
        if (line.empty()) {
            continue;
        }
        const auto a = line.find('\t');
        if (a == std::string::npos) {
            return false;
        }
        const auto b = line.find('\t', a + 1);
        Spec s;
        s.type = line.substr(0, a);
        s.enabled = line.substr(a + 1, b == std::string::npos ? std::string::npos : b - a - 1) != "0";
        if (b != std::string::npos) {
            std::istringstream pairs(line.substr(b + 1));
            std::string pair;
            while (std::getline(pairs, pair, ';')) {
                const auto eq = pair.find('=');
                if (eq == std::string::npos) {
                    continue;
                }
                char *end = nullptr;
                const std::string value = pair.substr(eq + 1);
                const double v = std::strtod(value.c_str(), &end);
                if (end == value.c_str()) {
                    return false;
                }
                s.params[pair.substr(0, eq)] = v;
            }
        }
        out.push_back(std::move(s));
    }
    return true;
}

void escape(std::string &out, const std::string &text)
{
    out += '"';
    for (const char c : text) {
        if (c == '"' || c == '\\') {
            out += '\\';
            out += c;
        } else if (static_cast<unsigned char>(c) < 0x20) {
            out += ' ';
        } else {
            out += c;
        }
    }
    out += '"';
}

std::string number(double v)
{
    std::ostringstream s;
    s.precision(10);
    s << v;
    return s.str();
}

} // namespace

struct PPFx
{
    pp::Processor processor;
    std::vector<std::string> types; // what the current chain holds, in order
    double rate = 0;
    int channels = 2;
    float keyPeak = -1;
    std::atomic<bool> canSleep{true}; // read by the audio thread // as of the last take of levels
};

extern "C" {

PPFx *pp_fx_create(void) { return new PPFx; }

void pp_fx_destroy(PPFx *fx) { delete fx; }

int pp_fx_set(PPFx *fx, const char *spec, double rate) { return pp_fx_set_channels(fx, spec, rate, 2); }

int pp_fx_set_channels(PPFx *fx, const char *spec, double rate, int channels)
{
    channels = channels == 1 ? 1 : 2;
    std::vector<Spec> wanted;
    if (!parse(spec, wanted)) {
        return -1;
    }
    std::vector<const Spec *> known;
    std::vector<std::string> types;
    for (const auto &s : wanted) {
        if (pp::makeEffect(s.type)) {
            known.push_back(&s);
            types.push_back(s.type);
        }
    }
    if (known.empty()) {
        if (fx->processor.chain()) {
            fx->processor.setChain(nullptr);
        }
        fx->types.clear();
        return 0;
    }
    pp::EffectChain *current = fx->processor.chain();
    if (current && types == fx->types && rate == fx->rate && channels == fx->channels) {
        for (std::size_t i = 0; i < known.size(); ++i) {
            pp::Effect &effect = current->at(i);
            for (const auto &[name, value] : known[i]->params) {
                effect.setParam(name, value);
            }
            effect.enabled = known[i]->enabled;
        }
        return int(known.size());
    }
    std::vector<std::unique_ptr<pp::Effect>> made;
    for (const Spec *s : known) {
        auto effect = pp::makeEffect(s->type);
        for (const auto &[name, value] : s->params) {
            effect->setParam(name, value);
        }
        effect->enabled = s->enabled;
        made.push_back(std::move(effect));
    }
    bool rings = false;
    for (const auto &e : made) {
        rings = rings || e->ringsOut();
    }
    fx->canSleep.store(!rings);
    fx->processor.setChain(std::make_unique<pp::EffectChain>(std::move(made), rate, channels));
    fx->types = std::move(types);
    fx->rate = rate;
    fx->channels = channels;
    return int(known.size());
}

void pp_fx_collect(PPFx *fx) { fx->processor.collect(); }

void pp_fx_process(PPFx *fx, float *left, float *right, int frames)
{
    pp_fx_process_keyed(fx, left, right, frames, nullptr);
}

void pp_fx_process_keyed(PPFx *fx, float *left, float *right, int frames, const float *key)
{
    pp::EffectChain *chain = fx->processor.chain();
    if (!chain) {
        return;
    }
    float *planes[2] = {left, right};
    if (chain->channels() == 1) {
        // Mono: the left is the source; the right gets the result.
        fx->processor.process(planes, planes, 1, frames, key);
        std::memcpy(right, left, std::size_t(std::max(frames, 0)) * sizeof(float));
        return;
    }
    fx->processor.process(planes, planes, 2, frames, key);
}

float pp_fx_key_peak(const PPFx *fx) { return fx->keyPeak; }

void pp_fx_resume(PPFx *fx)
{
    pp::EffectChain *chain = fx->processor.chain();
    if (!chain) {
        return;
    }
    for (std::size_t i = 0; i < chain->size(); ++i) {
        pp::Effect &effect = chain->at(i);
        if (!effect.ringsOut()) {
            effect.resume();
        }
    }
}

int pp_fx_can_sleep(const PPFx *fx) { return fx->canSleep.load(std::memory_order_relaxed) ? 1 : 0; }

int pp_fx_active(const PPFx *fx) { return fx->processor.chain() ? 1 : 0; }

int pp_fx_latency(const PPFx *fx)
{
    const pp::EffectChain *chain = fx->processor.chain();
    return chain ? chain->latency() : 0;
}

void pp_fx_set_metering(PPFx *fx, int on) { fx->processor.setMetering(on != 0); }

int pp_fx_take_levels(PPFx *fx, float *out, int maxEffects)
{
    pp::EffectChain *chain = fx->processor.chain();
    if (!chain) {
        return 0;
    }
    const auto levels = chain->takeLevels();
    fx->keyPeak = !levels.empty() && levels.front().hasKey ? levels.front().keyPeak : -1.0F;
    const int n = std::min(int(levels.size()), maxEffects);
    for (int i = 0; i < n; ++i) {
        const auto &l = levels[std::size_t(i)];
        float in = 0, outPeak = 0;
        for (std::size_t g = 0; g < l.groups; ++g) {
            in = std::max(in, l.inPeak[g]);
            outPeak = std::max(outPeak, l.outPeak[g]);
        }
        out[i * 2] = in;
        out[i * 2 + 1] = outPeak;
    }
    return n;
}

int pp_fx_take_meters(PPFx *fx, int effect, float *out, int max)
{
    pp::EffectChain *chain = fx->processor.chain();
    if (!chain || effect < 0 || std::size_t(effect) >= chain->size() || max <= 0) {
        return 0;
    }
    return int(chain->at(std::size_t(effect)).takeMeters(std::span<float>(out, std::size_t(max))));
}

char *pp_fx_catalog_json(void)
{
    std::string j = "[";
    bool firstType = true;
    for (const auto &type : pp::effectTypes()) {
        if (!firstType) {
            j += ',';
        }
        firstType = false;
        j += "{\"type\":";
        escape(j, type);
        j += ",\"label\":";
        escape(j, pp::effectLabel(type));
        j += ",\"key\":";
        j += pp::effectTakesKey(type) ? "true" : "false";
        j += ",\"params\":[";
        bool firstParam = true;
        for (const auto &p : pp::effectParams(type)) {
            if (!firstParam) {
                j += ',';
            }
            firstParam = false;
            j += "{\"name\":";
            escape(j, p.name);
            j += ",\"label\":";
            escape(j, p.label);
            j += ",\"unit\":";
            escape(j, p.unit);
            j += ",\"min\":" + number(p.minimum) + ",\"max\":" + number(p.maximum)
                + ",\"initial\":" + number(p.initial) + ",\"kind\":";
            escape(j, pp::paramKindName(p.kind));
            j += ",\"options\":[";
            for (std::size_t i = 0; i < p.options.size(); ++i) {
                if (i > 0) {
                    j += ',';
                }
                escape(j, p.options[i]);
            }
            j += "]}";
        }
        j += "]}";
    }
    j += "]";
    char *out = static_cast<char *>(std::malloc(j.size() + 1));
    std::memcpy(out, j.c_str(), j.size() + 1);
    return out;
}

void pp_fx_free_string(char *text) { std::free(text); }

void pp_fx_eq_curve(const char *params, int band, double rate, const double *freqs, double *dbOut, int count)
{
    std::vector<pp::EqEffect::Band> bands;
    for (int b = 0; b < pp::EqEffect::bandCount; ++b) {
        bands.push_back(pp::EqEffect::defaultBand(b));
    }
    std::istringstream pairs(params ? params : "");
    std::string pair;
    while (std::getline(pairs, pair, ';')) {
        const auto eq = pair.find('=');
        if (eq == std::string::npos || pair.size() < 4 || pair[0] != 'b') {
            continue;
        }
        const std::string name = pair.substr(0, eq);
        std::size_t used = 0;
        int n = 0;
        try {
            n = std::stoi(name.substr(1), &used);
        } catch (...) {
            continue;
        }
        if (n < 1 || n > pp::EqEffect::bandCount) {
            continue;
        }
        const std::string field = name.substr(1 + used);
        const double v = std::strtod(pair.c_str() + eq + 1, nullptr);
        auto &b = bands[std::size_t(n - 1)];
        if (field == "On") {
            b.on = v >= 0.5;
        } else if (field == "Type") {
            b.type = static_cast<pp::EqEffect::BandType>(
                std::clamp(int(std::lround(v)), 0, pp::EqEffect::bandTypeCount - 1));
        } else if (field == "Freq") {
            b.freq = std::clamp(v, pp::EqEffect::minFreq, pp::EqEffect::maxFreq);
        } else if (field == "Gain") {
            b.gainDb = std::clamp(v, pp::EqEffect::minGain, pp::EqEffect::maxGain);
        } else if (field == "Q") {
            b.q = std::clamp(v, pp::EqEffect::minQ, pp::EqEffect::maxQ);
        }
    }
    std::vector<pp::EqEffect::Band> used;
    if (band >= 1 && band <= pp::EqEffect::bandCount) {
        auto only = bands[std::size_t(band - 1)];
        only.on = true;
        used.push_back(only);
    } else {
        for (const auto &b : bands) {
            if (b.on) {
                used.push_back(b);
            }
        }
    }
    for (int i = 0; i < count; ++i) {
        dbOut[i] = pp::EqEffect::responseDb(used, freqs[i], rate);
    }
}

void pp_fx_compressor_knob(double amount, double out[5])
{
    const auto k = pp::CompressorEffect::fromAmount(amount);
    out[0] = k.threshold;
    out[1] = k.ratio;
    out[2] = k.attack;
    out[3] = k.release;
    out[4] = k.makeup;
}

} // extern "C"
