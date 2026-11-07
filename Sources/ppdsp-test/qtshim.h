// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Just enough of Qt Test's macros to run Patch Prime's effect tests without Qt. A
// failed check is reported and counted; the test carries on.

#pragma once

#include <cmath>
#include <cstdio>
#include <functional>
#include <sstream>
#include <string>
#include <type_traits>

namespace qtshim {

inline int failures = 0;
inline int checksFailedHere = 0;

inline void fail(const char *what, const char *file, int line, const std::string &more = {})
{
    ++failures;
    ++checksFailedHere;
    std::printf("    FAIL %s (%s:%d)%s%s\n", what, file, line, more.empty() ? "" : ": ", more.c_str());
}

template <typename A, typename B> bool same(const A &a, const B &b)
{
    if constexpr (std::is_floating_point_v<A> || std::is_floating_point_v<B>) {
        using F = std::conditional_t<std::is_same_v<A, float> || std::is_same_v<B, float>, float, double>;
        const F x = F(a), y = F(b);
        if (x == y) {
            return true;
        }
        // Qt's qFuzzyCompare.
        const F scale = std::is_same_v<F, float> ? F(100000) : F(1000000000000);
        return std::abs(x - y) * scale <= std::min(std::abs(x), std::abs(y));
    } else if constexpr (std::is_integral_v<A> && std::is_integral_v<B>) {
        return static_cast<long long>(a) == static_cast<long long>(b);
    } else {
        return a == b;
    }
}

template <typename T> std::string show(const T &v)
{
    if constexpr (requires(std::ostream &o) { o << v; }) {
        std::ostringstream s;
        s.precision(9);
        s << v;
        return s.str();
    } else {
        return "?";
    }
}

inline void run(const char *name, const std::function<void()> &test)
{
    checksFailedHere = 0;
    test();
    std::printf("%s %s\n", checksFailedHere == 0 ? "ok  " : "FAIL", name);
}

inline int finish()
{
    std::printf(failures == 0 ? "all passed\n" : "%d checks FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}

} // namespace qtshim

struct QString
{
    static std::string number(double v) { return qtshim::show(v); }
};
#define qPrintable(s) (s).c_str()
#define QVERIFY(c) \
    do { \
        if (!(c)) \
            qtshim::fail(#c, __FILE__, __LINE__); \
    } while (false)
#define QVERIFY2(c, m) \
    do { \
        if (!(c)) \
            qtshim::fail(#c, __FILE__, __LINE__, m); \
    } while (false)
#define QCOMPARE(a, b) \
    do { \
        const auto qa_ = (a); \
        const auto qb_ = (b); \
        if (!qtshim::same(qa_, qb_)) \
            qtshim::fail(#a " == " #b, __FILE__, __LINE__, qtshim::show(qa_) + " vs " + qtshim::show(qb_)); \
    } while (false)
