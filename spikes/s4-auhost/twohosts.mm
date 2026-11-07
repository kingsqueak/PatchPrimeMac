// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
// How many hosting processes several out-of-process AUs get.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <cstdio>
#include <string>
static AudioUnit load(NSString *name) {
    AVAudioUnitComponent *c = [[AVAudioUnitComponentManager sharedAudioUnitComponentManager] componentsPassingTest:^BOOL(AVAudioUnitComponent *c, BOOL *) {
        return [[NSString stringWithFormat:@"%@: %@", c.manufacturerName, c.name] isEqualToString:name]; }].firstObject;
    __block AudioUnit u = nullptr; dispatch_semaphore_t d = dispatch_semaphore_create(0);
    AudioComponentInstantiate(c.audioComponent, kAudioComponentInstantiation_LoadOutOfProcess, ^(AudioComponentInstance a, OSStatus) { u = a; dispatch_semaphore_signal(d); });
    while (dispatch_semaphore_wait(d, DISPATCH_TIME_NOW)) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return u;
}
static void hosts(const char *when) { std::printf("%s: ", when); fflush(stdout); system("pgrep -l AUHostingService | tr '\\n' ' '; echo"); }
int main() { @autoreleasepool {
    hosts("before");
    AudioUnit a = load(@"Apple: AUNBandEQ"); hosts("one Apple AU");
    AudioUnit b = load(@"Waves: C1 comp (m)"); hosts("plus Waves C1");
    AudioUnit c = load(@"Waves: CLA-76 (m)"); hosts("plus Waves CLA-76");
    AudioUnit d = load(@"MeldaProduction: MCompressor"); hosts("plus Melda MCompressor");
    std::printf("loaded: %d %d %d %d\n", a != nullptr, b != nullptr, c != nullptr, d != nullptr);
} return 0; }
