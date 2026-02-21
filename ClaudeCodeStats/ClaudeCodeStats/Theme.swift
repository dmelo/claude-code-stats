import SwiftUI
import AppKit

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

    static let inputBackground = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 35/255, green: 35/255, blue: 35/255, alpha: 1)
            : NSColor(red: 235/255, green: 235/255, blue: 235/255, alpha: 1)
    }))
}
