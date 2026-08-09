import AppKit
import SwiftUI

// The shared visual language. Dark-first, but every colour is defined for both appearances
// through NSColor's dynamic provider, so nothing is hard-coded black and light mode is right.
// Every view file uses these tokens instead of inventing its own.

enum Theme {
    // MARK: Colours

    static let background = dyn(dark: 0x0E0E11, light: 0xF5F5F7)
    static let sidebar = dyn(dark: 0x141418, light: 0xECECEF)
    static let card = dyn(dark: 0x1A1A1F, light: 0xFFFFFF)
    static let cardHover = dyn(dark: 0x232329, light: 0xF0F0F3)
    static let stroke = dyn(dark: 0xFFFFFF, darkAlpha: 0.08, light: 0x000000, lightAlpha: 0.10)
    static let accent = dyn(dark: 0x8B93FF, light: 0x4B54D6)
    static let accentSoft = dyn(dark: 0x8B93FF, darkAlpha: 0.16, light: 0x4B54D6, lightAlpha: 0.12)
    static let textPrimary = dyn(dark: 0xF3F3F6, light: 0x121216)
    static let textSecondary = dyn(dark: 0x9C9CA6, light: 0x62626C)
    static let textTertiary = dyn(dark: 0x6C6C76, light: 0x8E8E98)
    static let success = dyn(dark: 0x4ED08A, light: 0x1E9E5F)
    static let warning = dyn(dark: 0xF0B23E, light: 0xB57A0C)
    static let danger = dyn(dark: 0xFF6B6B, light: 0xC93030)

    // MARK: Corner radii

    enum Radius {
        static let panel: CGFloat = 22
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let chip: CGFloat = 8
    }

    // MARK: Spacing scale

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 36
    }

    // MARK: Type

    static let title = Font.system(size: 32, weight: .semibold)
    static let heading = Font.system(size: 19, weight: .semibold)
    static let body = Font.system(size: 13)
    static let caption = Font.system(size: 11)
    static let mono = Font.system(size: 12, design: .monospaced)

    // MARK: Dynamic colour plumbing

    private static func dyn(dark: UInt32, darkAlpha: CGFloat = 1,
                            light: UInt32, lightAlpha: CGFloat = 1) -> Color {
        let d = ns(dark, darkAlpha), l = ns(light, lightAlpha)
        return Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }

    private static func ns(_ v: UInt32, _ a: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255,
                alpha: a)
    }
}

// MARK: - Card surface

extension View {
    /// The standard card: material-backed, softly stroked, generous radius.
    func card(padding: CGFloat = Theme.Space.l, radius: CGFloat = Theme.Radius.card) -> some View {
        self.padding(padding)
            .background(Theme.card, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.stroke))
    }
}

// MARK: - KeyCap

/// A small rounded key-cap chip: KeyCap("fn"), KeyCap("⇧"), KeyCap("space").
struct KeyCap: View {
    let label: String

    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(minWidth: 24)
            .background(Theme.cardHover, in: .rect(cornerRadius: Theme.Radius.chip))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(Theme.stroke))
    }
}

/// A row of key caps joined by a thin plus, for a whole trigger: fn + ⇧
struct KeyCaps: View {
    let caps: [String]

    init(_ caps: [String]) { self.caps = caps }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            ForEach(Array(caps.enumerated()), id: \.offset) { i, cap in
                if i > 0 {
                    Text("+").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
                KeyCap(cap)
            }
        }
    }
}
