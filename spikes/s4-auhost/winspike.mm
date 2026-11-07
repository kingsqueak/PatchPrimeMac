// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// Spike S4: a plugin's own window, from a plugin loaded out of process. Opens the
// window in this app if the system can show it here. Renders nothing: silent.
//
//   winspike "<Maker: Name>" [inproc|outproc]

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudioKit/CoreAudioKit.h>
#import <Cocoa/Cocoa.h>
#include <cstdio>
#include <string>

@interface Holder : NSObject <NSWindowDelegate>
@property(strong) AUAudioUnit *unit;
@property(strong) NSWindow *window;
@end
@implementation Holder
- (void)windowWillClose:(NSNotification *)n { [NSApp terminate:nil]; }
@end

static Holder *holder;

static void show(NSViewController *vc, NSString *title)
{
    NSView *view = vc.view;
    NSSize size = vc.preferredContentSize;
    if (size.width < 50 || size.height < 50) size = view.fittingSize;
    if (size.width < 50 || size.height < 50) size = view.frame.size;
    if (size.width < 50 || size.height < 50) size = NSMakeSize(600, 400);
    std::printf("view controller %s, view %s, size %.0f x %.0f\n", NSStringFromClass([vc class]).UTF8String,
        NSStringFromClass([view class]).UTF8String, size.width, size.height);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, size.width, size.height)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = title;
    w.contentViewController = vc;
    [w setContentSize:size];
    w.delegate = holder;
    holder.window = w;
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    std::fflush(stdout);
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) return 2;
        NSString *want = @(argv[1]);
        const bool outOfProcess = !(argc > 2 && std::string(argv[2]) == "inproc");
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        holder = [Holder new];
        AVAudioUnitComponent *c = [[AVAudioUnitComponentManager sharedAudioUnitComponentManager]
            componentsPassingTest:^BOOL(AVAudioUnitComponent *c, BOOL *) {
                return [[NSString stringWithFormat:@"%@: %@", c.manufacturerName, c.name] isEqualToString:want];
            }].firstObject;
        if (!c) {
            std::printf("no plugin called %s\n", argv[1]);
            return 1;
        }
        NSString *title = [NSString stringWithFormat:@"%@ (%s)", want, outOfProcess ? "out of process" : "in process"];
        [AUAudioUnit instantiateWithComponentDescription:c.audioComponentDescription
                                                 options:outOfProcess ? kAudioComponentInstantiation_LoadOutOfProcess : 0
                                       completionHandler:^(AUAudioUnit *unit, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!unit) {
                    std::printf("load failed: %s\n", error.localizedDescription.UTF8String);
                    [NSApp terminate:nil];
                    return;
                }
                holder.unit = unit;
                std::printf("loaded %s; asking for its view\n", argv[1]);
                std::fflush(stdout);
                [unit requestViewControllerWithCompletionHandler:^(AUViewControllerBase *vc) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!vc) {
                            std::printf("no view controller came back\n");
                            std::fflush(stdout);
                            [NSApp terminate:nil];
                            return;
                        }
                        show(vc, title);
                    });
                }];
            });
        }];
        [NSApp run];
    }
    return 0;
}
