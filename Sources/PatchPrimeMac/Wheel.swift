// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The scroll wheel, the same on every control in the app: faders, routing levels,
// effect sliders, spinners and EQ handles.
// - A wheel notch is one step, however fast the wheel spins.
// - A trackpad moves smoothly, about a step for every 12 points.
// - Up (or right, on a thumb wheel) is more.
// - Fine steps, a tenth: Option or Command held (read from the keyboard, since mouse
//   utilities such as Logi Options+ can drop them from scroll events), or the
//   thumb wheel (or Shift with the wheel, which macOS turns sideways).

import AppKit
import SwiftUI

struct WheelReader {
    private var carried = 0.0

    /// Steps for one scroll event (+ is more). `whole`: a trackpad's come out in whole
    /// steps, the rest carried to the next event, for controls that move in clicks.
    mutating func steps(_ event: NSEvent, whole: Bool = false) -> Double {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        var raw = Double(horizontal ? event.scrollingDeltaX : event.scrollingDeltaY)
        guard raw != 0 else { return 0 }
        if event.isDirectionInvertedFromDevice { raw = -raw }
        let keys = NSEvent.modifierFlags.union(event.modifierFlags)
        let scale = keys.contains(.option) || keys.contains(.command) || horizontal ? 0.1 : 1.0
        guard event.hasPreciseScrollingDeltas else {
            return (raw > 0 ? 1 : -1) * scale
        }
        let steps = raw / 12
        guard whole else { return steps * scale }
        carried += steps
        let out = carried.rounded(.towardZero)
        carried -= out
        return out * scale
    }
}

/// Lies over a control and takes only the scroll wheel: clicks, drags and typing go
/// through to what's underneath.
struct WheelCatcher: NSViewRepresentable {
    var whole = false
    var steps: (Double) -> Void

    final class Catcher: NSView {
        var onSteps: (Double) -> Void = { _ in }
        var whole = false
        private var reader = WheelReader()

        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
        }

        override func scrollWheel(with event: NSEvent) {
            let s = reader.steps(event, whole: whole)
            if s != 0 { onSteps(s) }
        }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) {
        view.onSteps = steps
        view.whole = whole
    }
}

extension View {
    /// The wheel on this control, in steps (see WheelReader).
    func onWheel(whole: Bool = false, _ steps: @escaping (Double) -> Void) -> some View {
        overlay(WheelCatcher(whole: whole, steps: steps))
    }
}
