import SwiftUI
import AppKit

/// Which appearance the popover renders in.
///
/// Applies to the popover's contents only — never to `NSApp.appearance`. The
/// menu bar icon draws with `NSColor.labelColor` against the real menu bar, so
/// forcing the app light while the system is dark would paint it black on black.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// nil follows the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension View {
    /// Applies an appearance override to this subtree.
    ///
    /// Both modifiers are needed, and they cover different layers.
    /// `preferredColorScheme` reaches the hosting window, which is what native
    /// controls (pickers, toggles) follow. Inside a MenuBarExtra the window's
    /// appearance is *not* fed back down as an environment value, so the
    /// `Theme` colours — `NSColor(dynamicProvider:)`, resolved against
    /// `\.colorScheme` — keep rendering in the system's scheme unless the
    /// environment is set explicitly too. With only the former, the popover
    /// renders native controls light over dark cards.
    @ViewBuilder
    func appearanceOverride(_ preference: AppearancePreference) -> some View {
        if let scheme = preference.colorScheme {
            self.environment(\.colorScheme, scheme)
                .preferredColorScheme(scheme)
        } else {
            self
        }
    }
}

enum Theme {
    static let background = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 26/255, green: 26/255, blue: 26/255, alpha: 1)
            : NSColor(red: 245/255, green: 245/255, blue: 245/255, alpha: 1)
    }))

    static let cardBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 42/255, green: 42/255, blue: 42/255, alpha: 1)
            : NSColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
    }))

    static let textPrimary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 255/255, green: 255/255, blue: 255/255, alpha: 1)
            : NSColor(red: 0/255, green: 0/255, blue: 0/255, alpha: 1)
    }))

    static let textSecondary = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 138/255, green: 138/255, blue: 138/255, alpha: 1)
            : NSColor(red: 102/255, green: 102/255, blue: 102/255, alpha: 1)
    }))

    static let divider = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 58/255, green: 58/255, blue: 58/255, alpha: 1)
            : NSColor(red: 224/255, green: 224/255, blue: 224/255, alpha: 1)
    }))

    // Chart marks. Each mode gets its own step rather than one colour reused on
    // both surfaces: a single blue can't sit inside the readable lightness band
    // against white and against #2A2A2A at once.
    static let chartBar = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 59/255, green: 130/255, blue: 246/255, alpha: 1)
            : NSColor(red: 37/255, green: 99/255, blue: 235/255, alpha: 1)
    }))

    static let inputBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 35/255, green: 35/255, blue: 35/255, alpha: 1)
            : NSColor(red: 235/255, green: 235/255, blue: 235/255, alpha: 1)
    }))

    // Severity ramp — cyan, orange, purple. The obvious green/yellow/red loses
    // most of its meaning twice over: on a light background the green and
    // yellow sat at 1.7:1 and 1.5:1, well under the 3:1 WCAG floor for non-text
    // UI, and under deuteranopia all three collapse into shades of olive
    // (#C2C284 / #DBDB00 / #A8A86B — ΔE 9.5 between the outer two, which is no
    // difference at all). This ramp keeps every pair at ΔE ≥ 41 under
    // protanopia, deuteranopia and tritanopia alike, and every step clears 3:1
    // on all four surfaces. Purple rather than red for the top step is the
    // price: red can't hold that separation from orange without a lightness
    // gap that the light-mode contrast floor forbids. See issue #29.
    //
    // Measured on each real surface, worst of the three steps:
    //   light popover #FFFFFF  5.18:1    light menu bar #DCDCDC  3.78:1
    //   dark popover  #2A2A2A  3.63:1    dark menu bar  #272727  3.78:1
    //
    // The light menu bar is the tightest of the four, because it is translucent
    // over the wallpaper rather than the #F2F2F2 an opaque bar would give. That
    // is what puts the warning step at orange-700 and not the orange-600 the
    // popover could otherwise carry: on a #DCDCDC bar orange-600 is 2.60:1.
    //
    // The menu bar takes the same pair as the popover, not a fixed mid-tone.
    // Its rings are rasterised into an NSImage, but the drawing handler runs at
    // draw time under the menu bar's own appearance, so a dynamic colour
    // resolves to the right step there — the labels next to the rings already
    // rely on this, via `NSColor.labelColor`. Pinning them to the light step
    // instead left the two commonest states at 2.86:1 and 2.85:1 on a real
    // #252525 menu bar: under the floor, and visibly washed out.
    static let statusOKColor = NSColor.statusStep(
        light: NSColor(red: 14/255, green: 116/255, blue: 144/255, alpha: 1),
        dark: NSColor(red: 103/255, green: 232/255, blue: 249/255, alpha: 1))

    static let statusWarningColor = NSColor.statusStep(
        light: NSColor(red: 194/255, green: 65/255, blue: 12/255, alpha: 1),
        dark: NSColor(red: 252/255, green: 211/255, blue: 77/255, alpha: 1))

    static let statusCriticalColor = NSColor.statusStep(
        light: NSColor(red: 147/255, green: 51/255, blue: 234/255, alpha: 1),
        dark: NSColor(red: 168/255, green: 85/255, blue: 247/255, alpha: 1))

    static let statusOK = Color(nsColor: Theme.statusOKColor)
    static let statusWarning = Color(nsColor: Theme.statusWarningColor)
    static let statusCritical = Color(nsColor: Theme.statusCriticalColor)
}

private extension NSColor {
    /// Pairs a light step with a dark one, matching the two-step approach the
    /// rest of `Theme` uses: a single saturated hue can't sit inside the
    /// readable lightness band against white and against #2A2A2A at once.
    static func statusStep(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// How close a limit is to being hit.
///
/// The thresholds and their colours live here so the usage bars, the menu bar
/// rings and the status dot can't drift apart — they were three separate copies
/// of the same triple before.
enum StatusLevel {
    case ok
    case warning
    case critical

    init(usagePercent: Double) {
        switch usagePercent {
        case ..<50: self = .ok
        case ..<75: self = .warning
        default: self = .critical
        }
    }

    /// For SwiftUI surfaces, which resolve against the appearance in effect.
    var color: Color {
        switch self {
        case .ok: return Theme.statusOK
        case .warning: return Theme.statusWarning
        case .critical: return Theme.statusCritical
        }
    }

    /// The same step as `color`, for the menu bar rings — they're drawn with
    /// Core Graphics, which needs the `NSColor` rather than the SwiftUI one.
    var menuBarColor: NSColor {
        switch self {
        case .ok: return Theme.statusOKColor
        case .warning: return Theme.statusWarningColor
        case .critical: return Theme.statusCriticalColor
        }
    }
}
