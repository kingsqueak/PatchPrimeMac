// One instance, two ways: AVAudioUnit loaded out of process, rendered through its C
// AudioUnit and its window from its AUAudioUnit. Silent: no audio device.
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <Cocoa/Cocoa.h>
#include <cmath>
#include <cstdio>
#include <vector>
static std::vector<float> in(4096);
static OSStatus feed(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 n, AudioBufferList *l) {
    for (UInt32 b = 0; b < l->mNumberBuffers; ++b) { if (l->mBuffers[b].mData) memcpy(l->mBuffers[b].mData, in.data(), n * 4); else l->mBuffers[b].mData = in.data(); l->mBuffers[b].mDataByteSize = n * 4; }
    return noErr; }
static NSWindow *window; static AVAudioUnit *keep;
int main(int argc, char **argv) { @autoreleasepool {
    [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSString *want = @(argv[1]);
    AVAudioUnitComponent *c = [[AVAudioUnitComponentManager sharedAudioUnitComponentManager] componentsPassingTest:^BOOL(AVAudioUnitComponent *c, BOOL *) {
        return [[NSString stringWithFormat:@"%@: %@", c.manufacturerName, c.name] isEqualToString:want]; }].firstObject;
    [AVAudioUnit instantiateWithComponentDescription:c.audioComponentDescription options:kAudioComponentInstantiation_LoadOutOfProcess completionHandler:^(AVAudioUnit *av, NSError *e) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!av) { printf("load failed\n"); exit(1); }
        keep = av;
        AudioUnit u = av.audioUnit;
        UInt32 ch = [c.name containsString:@"(m)"] ? 1 : 2;
        AudioStreamBasicDescription f{48000, kAudioFormatLinearPCM, kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved, 4, 1, 4, ch, 32, 0};
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f);
        AURenderCallbackStruct cb{feed, nullptr}; AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
        OSStatus s = AudioUnitInitialize(u);
        std::vector<std::vector<float>> out(ch, std::vector<float>(128)); AudioBufferList *l = (AudioBufferList *)calloc(1, sizeof(AudioBufferList) + sizeof(AudioBuffer) * ch);
        AudioTimeStamp ts{}; ts.mFlags = kAudioTimeStampSampleTimeValid; float peak = 0; int errs = 0; double ph = 0;
        for (int b = 0; b < 375; ++b) { for (int i = 0; i < 128; ++i) { in[i] = 0.25f * sinf(ph); ph += 2 * M_PI * 1000 / 48000; }
            l->mNumberBuffers = ch; for (UInt32 k = 0; k < ch; ++k) l->mBuffers[k] = {1, 512, out[k].data()};
            AudioUnitRenderActionFlags fl = 0; if (AudioUnitRender(u, &fl, &ts, 0, 128, l) != noErr) ++errs; ts.mSampleTime += 128;
            for (int i = 0; i < 128; ++i) peak = fmaxf(peak, fabsf(out[0][i])); }
        printf("init %d; rendered through the C handle: peak %.1f dBFS, %d errors\n", (int)s, 20 * log10f(peak), errs);
        [av.AUAudioUnit requestViewControllerWithCompletionHandler:^(AUViewControllerBase *vc) { dispatch_async(dispatch_get_main_queue(), ^{
            if (!vc) { printf("no view\n"); exit(1); }
            NSSize sz = vc.preferredContentSize; if (sz.width < 50) sz = vc.view.frame.size;
            printf("window from the same instance: %s, %.0f x %.0f\n", NSStringFromClass([vc class]).UTF8String, sz.width, sz.height); fflush(stdout);
            window = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 300, sz.width, sz.height) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
            window.title = want; window.contentViewController = vc; [window setContentSize:sz]; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ printf("closing\n"); exit(0); });
        }); }];
      }); }];
    [NSApp run];
} }
