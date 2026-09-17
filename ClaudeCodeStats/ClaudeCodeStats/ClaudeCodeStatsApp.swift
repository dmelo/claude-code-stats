import SwiftUI
import AppKit

@main
struct ClaudeCodeStatsApp: App {
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var viewModel = UsageViewModel()
    @AppStorage("showSessionInMenuBar") private var showSession = false
    @AppStorage("showWeeklyInMenuBar") private var showWeekly = false
    @AppStorage("showFableInMenuBar") private var showFable = false
    @AppStorage("appearancePreference") private var appearance: AppearancePreference = .system

    private var showRings: Bool {
        showSession || showWeekly || showFable
    }

    var body: some Scene {
        MenuBarExtra {
            // Scoped to the popover's contents. The label below is deliberately
            // left out so the menu bar icon keeps following the system.
            ContentView()
                .environmentObject(updateChecker)
                .environmentObject(viewModel)
                .appearanceOverride(appearance)
        } label: {
            ZStack(alignment: .topTrailing) {
                if showRings {
                    let sessionPct = viewModel.webUsage?.sessionUsage ?? 0
                    let weeklyPct = viewModel.webUsage?.weeklyUsage ?? 0
                    let fablePct = viewModel.webUsage?.scopedLimits
                        .first(where: { $0.name == "Fable" })?.usage ?? 0
                    Image(nsImage: renderRings(
                        session: showSession ? sessionPct : nil,
                        weekly: showWeekly ? weeklyPct : nil,
                        fable: showFable ? fablePct : nil
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
            .onAppear {
                viewModel.backgroundRefreshEnabled = showRings
            }
            .onChange(of: showRings) { _, newValue in
                viewModel.backgroundRefreshEnabled = newValue
            }
        }
        .menuBarExtraStyle(.window)
    }

    private func renderRings(session: Double?, weekly: Double?, fable: Double?) -> NSImage {
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
        if let fable { segments.append(("F", fable)) }

        // Measure total width
        let separatorWidth: CGFloat = (" | " as NSString).size(withAttributes: textAttrs).width
        var totalWidth: CGFloat = 0
        for (label, _) in segments {
            let labelSize = (label as NSString).size(withAttributes: textAttrs)
            totalWidth += labelSize.width + 2 + ringSize  // label + gap + ring
        }
        // One separator between each pair of segments (count - 1 total)
        totalWidth += separatorWidth * CGFloat(max(0, segments.count - 1))

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
        let clamped = max(0.0, min(progress, 100.0))
        let level = StatusLevel(usagePercent: clamped)
        let endAngle = startAngle - CGFloat(clamped / 100.0) * 2 * .pi
        ctx.setStrokeColor(level.menuBarColor.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.strokePath()

        // Every other surface pairs its colour with a number or a word; up here
        // the ring is the whole signal, so the top step gets a shape too. The
        // dot is readable with no colour perception at all.
        if level == .critical {
            let dotRadius: CGFloat = 2
            ctx.setFillColor(level.menuBarColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2))
        }
    }
}
