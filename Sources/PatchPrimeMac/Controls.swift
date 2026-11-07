// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 KC2RGW Chris
//
// The hand-made controls: meters and faders. Meters are a single Core Animation
// layer, so they cost almost nothing to move, and don't go through SwiftUI layout.

import AppKit
import QuartzCore
import SwiftUI

final class MeterLayerView: NSView {
    private let fill = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        fill.colors = [NSColor.systemGreen.cgColor, NSColor.systemGreen.cgColor,
            NSColor.systemYellow.cgColor, NSColor.systemRed.cgColor]
        fill.locations = [0, 0.7, 0.88, 1]
        fill.startPoint = CGPoint(x: 0.5, y: 0)
        fill.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { nil }

    /// Left to right instead of bottom to top (the mini window's).
    var horizontal = false {
        didSet {
            fill.startPoint = horizontal ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
            fill.endPoint = horizontal ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
            place()
        }
    }

    var level: Float = 0 {
        didSet {
            let shown = Int(fraction(level) * 200)
            if shown != lastShown {
                lastShown = shown
                place()
            }
        }
    }

    private var lastShown = -1

    private func fraction(_ level: Float) -> CGFloat {
        let db = level > 0 ? 20 * log10(level) : -90
        return CGFloat(max(0, min(1, (db + 60) / 60)))
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = bounds.height
        let shown = fraction(level)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        let mask = fill.mask ?? CALayer()
        mask.backgroundColor = NSColor.white.cgColor
        mask.frame = horizontal ? CGRect(x: 0, y: 0, width: bounds.width * shown, height: height)
            : CGRect(x: 0, y: 0, width: bounds.width, height: height * shown)
        fill.mask = mask
        CATransaction.commit()
    }
}

struct Meter: NSViewRepresentable {
    var level: Float

    func makeNSView(context: Context) -> MeterLayerView { MeterLayerView() }
    func updateNSView(_ view: MeterLayerView, context: Context) { view.level = level }
}

/// A meter wired straight to its level. SwiftUI places it once and then leaves it alone.
struct LiveMeter: NSViewRepresentable {
    var levels: Levels
    var key: String
    var horizontal = false

    func makeNSView(context: Context) -> MeterLayerView {
        let view = MeterLayerView()
        view.horizontal = horizontal
        levels.attach(view, key: key)
        return view
    }

    func updateNSView(_ view: MeterLayerView, context: Context) {
        levels.attach(view, key: key)
    }
}

/// A vertical fader in decibels. Reports while dragging; double-click returns to 0 dB;
/// the wheel moves it half a dB a notch.
struct Fader: View {
    var db: Float
    var onChange: (Float) -> Void
    @State private var dragStart: Float?
    @State private var dragValue: Float? // follows the hand, not the round trip
    @State private var wheelValue: Float?
    @State private var wheelEnd: DispatchWorkItem?

    private let capHeight: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height - capHeight
            let span = Decibels.top - Decibels.floor
            let position = CGFloat(((dragValue ?? db) - Decibels.floor) / span)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.45)).frame(width: 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.white).frame(height: 2))
                    .frame(width: geo.size.width - 6, height: capHeight)
                    .shadow(radius: 1, y: 1)
                    .offset(y: -position * travel)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = dragStart ?? db
                    dragStart = start
                    let delta = Float(-value.translation.height / travel) * span
                    let value = min(Decibels.top, max(Decibels.floor, start + delta))
                    dragValue = value
                    onChange(value)
                }
                .onEnded { _ in
                    dragStart = nil
                    dragValue = nil
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
            .onWheel { steps in
                // Half a dB a notch, from wherever it is, as with the effect controls.
                let from = wheelValue ?? db
                let next = min(Decibels.top, max(Decibels.floor, from + Float(steps) * 0.5))
                wheelValue = next
                dragValue = next
                onChange(next)
                wheelEnd?.cancel()
                let work = DispatchWorkItem {
                    wheelValue = nil
                    dragValue = nil
                }
                wheelEnd = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
            }
        }
    }
}

struct ToggleButton: View {
    var title: String
    var on: Bool
    var color: Color
    /// The label's colour when on: white reads better on the darker colours.
    var textOn: Color = .black
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 20)
                .foregroundStyle(on ? textOn : Color.secondary)
                .background(on ? color : Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

extension Color {
    /// A true, dark red for mute.
    static let muteRed = Color(.sRGB, red: 0.80, green: 0.0, blue: 0.0)
}
