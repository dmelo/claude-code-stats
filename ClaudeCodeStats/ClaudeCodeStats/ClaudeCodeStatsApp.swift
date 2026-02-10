import SwiftUI
import AppKit

@main
struct ClaudeCodeStatsApp: App {
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var viewModel = UsageViewModel()
    @AppStorage("showSessionInMenuBar") private var showSession = false
    @AppStorage("showWeeklyInMenuBar") private var showWeekly = false

    private var showRings: Bool {
        showSession || showWeekly
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(updateChecker)
                .environmentObject(viewModel)
        } label: {
            ZStack(alignment: .topTrailing) {
                if showRings {
                    let sessionPct = viewModel.webUsage?.sessionUsage ?? 0
                    let weeklyPct = viewModel.webUsage?.weeklyUsage ?? 0
                    Image(nsImage: renderRings(
                        session: showSession ? sessionPct : nil,
                        weekly: showWeekly ? weeklyPct : nil
                    ))
                } else {
                    Image(systemName: "chart.bar.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                if updateChecker.hasUpdate {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                        .offset(x: 4, y: -3)
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func renderRings(session: Double?, weekly: Double?) -> NSImage {
        let height: CGFloat = 18
        let ringSize: CGFloat = 14
        let ringLineWidth: CGFloat = 2.5
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let textColor = NSColor.labelColor
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        // Build segments: [(label, progress)]
        var segments: [(String, Double)] = []
        if let session { segments.append(("S", session)) }
        if let weekly { segments.append(("W", weekly)) }

        // Measure total width
        let separatorWidth: CGFloat = segments.count > 1 ? 12 : 0  // " | "
        var totalWidth: CGFloat = 0
        var segmentWidths: [CGFloat] = []
        for (label, _) in segments {
            let labelSize = (label as NSString).size(withAttributes: textAttrs)
            let w = labelSize.width + 2 + ringSize  // label + gap + ring
            segmentWidths.append(w)
            totalWidth += w
        }
        totalWidth += separatorWidth

        let image = NSImage(size: NSSize(width: totalWidth, height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0

            for (i, (label, progress)) in segments.enumerated() {
                // Draw separator before second segment
                if i > 0 {
                    let sep = " | " as NSString
                    let sepSize = sep.size(withAttributes: textAttrs)
                    sep.draw(at: NSPoint(x: x, y: (height - sepSize.height) / 2), withAttributes: textAttrs)
                    x += separatorWidth
                }

                // Draw label
                let labelStr = label as NSString
                let labelSize = labelStr.size(withAttributes: textAttrs)
                labelStr.draw(at: NSPoint(x: x, y: (height - labelSize.height) / 2), withAttributes: textAttrs)
                x += labelSize.width + 2

                // Draw ring
                let ringCenter = CGPoint(x: x + ringSize / 2, y: height / 2)
                let radius = (ringSize - ringLineWidth) / 2
                self.drawRing(in: ctx, center: ringCenter, radius: radius,
                              lineWidth: ringLineWidth, progress: progress)
                x += ringSize
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawRing(in ctx: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat, progress: Double) {
        let startAngle = CGFloat.pi / 2

        // Track
        ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.butt)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()

        // Progress arc
        let endAngle = startAngle - CGFloat(min(progress / 100, 1.0)) * 2 * .pi
        ctx.setStrokeColor(ringColor(for: progress).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()
    }

    private func ringColor(for progress: Double) -> NSColor {
        if progress < 50 {
            return NSColor(red: 74/255, green: 222/255, blue: 128/255, alpha: 1)
        } else if progress < 75 {
            return NSColor(red: 250/255, green: 204/255, blue: 21/255, alpha: 1)
        } else {
            return NSColor(red: 248/255, green: 113/255, blue: 113/255, alpha: 1)
        }
    }
}
