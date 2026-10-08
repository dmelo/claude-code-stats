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

    @AppStorage(ProfilePreferences.hiddenKey) private var hiddenProfilesRaw = ""
    @AppStorage(ProfilePreferences.labelsKey) private var profileLabelsRaw = ""

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
                if showRings, !ringGroups.isEmpty {
                    Image(nsImage: renderRings(ringGroups))
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

    // One ring: its letter and fill, or nil progress for a login we can't read
    // (expired, signed out, never fetched) — drawn dashed rather than as a
    // confident 0%.
    private struct RingSegment {
        let label: String
        let progress: Double?
    }

    // One account's rings, with the name drawn before them; nil name when only
    // one account is visible, which keeps the single-account bar as it was.
    private struct RingGroup {
        let name: String?
        let rings: [RingSegment]
    }

    private var ringGroups: [RingGroup] {
        let hidden = ProfilePreferences.hidden(from: hiddenProfilesRaw)
        let labels = ProfilePreferences.labels(from: profileLabelsRaw)
        let visible = viewModel.accounts.filter { account in
            account.profileName.map { !hidden.contains($0) } ?? true
        }
        // A group left with no rings (only F selected, account has no Fable
        // limit) is dropped rather than drawn as a bare name.
        return visible.map { account in
            RingGroup(
                name: visible.count > 1 ? ProfilePreferences.label(for: account, in: labels) : nil,
                rings: rings(for: account)
            )
        }
        .filter { !$0.rings.isEmpty }
    }

    private func rings(for account: ClaudeAccount) -> [RingSegment] {
        let state = viewModel.usageByAccount[account.id]
        let usage = state?.needsLogin == true ? nil : state?.usage
        var rings: [RingSegment] = []
        if showSession { rings.append(RingSegment(label: "S", progress: usage?.sessionUsage)) }
        if showWeekly { rings.append(RingSegment(label: "W", progress: usage?.weeklyUsage)) }
        // Not every plan carries a Fable limit; an account without one gets no F
        // ring rather than an empty one. Unknown (no reading yet) also omits it.
        if showFable, let fable = usage?.scopedLimits.first(where: { $0.name == "Fable" }) {
            rings.append(RingSegment(label: "F", progress: fable.usage))
        }
        return rings
    }

    private func renderRings(_ groups: [RingGroup]) -> NSImage {
        let height: CGFloat = 18
        let ringSize: CGFloat = 14
        let ringLineWidth: CGFloat = 2.5
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let textColor = NSColor.labelColor
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        // A lone group keeps today's "S◯ | W◯ | F◯". Several groups drop the
        // pipes inside a group and let the profile name plus a wider gap do the
        // grouping — a pipe within and between groups reads the same at 10pt.
        let multi = groups.count > 1
        let separator = " | " as NSString
        let intraGap: CGFloat = multi ? 4 : separator.size(withAttributes: textAttrs).width
        let groupGap: CGFloat = 10
        let nameGap: CGFloat = 3

        func groupWidth(_ group: RingGroup) -> CGFloat {
            var width: CGFloat = 0
            if let name = group.name {
                width += (name as NSString).size(withAttributes: textAttrs).width + nameGap
            }
            for ring in group.rings {
                width += (ring.label as NSString).size(withAttributes: textAttrs).width + 2 + ringSize
            }
            width += intraGap * CGFloat(max(0, group.rings.count - 1))
            return width
        }

        let totalWidth = groups.map(groupWidth).reduce(0, +)
            + groupGap * CGFloat(max(0, groups.count - 1))

        let image = NSImage(size: NSSize(width: max(totalWidth, 1), height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            var x: CGFloat = 0

            for (g, group) in groups.enumerated() {
                if g > 0 { x += groupGap }

                if let name = group.name {
                    let nameStr = name as NSString
                    let nameSize = nameStr.size(withAttributes: textAttrs)
                    nameStr.draw(at: NSPoint(x: x, y: (height - nameSize.height) / 2), withAttributes: textAttrs)
                    x += nameSize.width + nameGap
                }

                for (i, ring) in group.rings.enumerated() {
                    if i > 0 {
                        if !multi {
                            let sepSize = separator.size(withAttributes: textAttrs)
                            separator.draw(at: NSPoint(x: x, y: (height - sepSize.height) / 2), withAttributes: textAttrs)
                        }
                        x += intraGap
                    }

                    let labelStr = ring.label as NSString
                    let labelSize = labelStr.size(withAttributes: textAttrs)
                    labelStr.draw(at: NSPoint(x: x, y: (height - labelSize.height) / 2), withAttributes: textAttrs)
                    x += labelSize.width + 2

                    let ringCenter = CGPoint(x: x + ringSize / 2, y: height / 2)
                    let radius = (ringSize - ringLineWidth) / 2
                    self.drawRing(in: ctx, center: ringCenter, radius: radius,
                                  lineWidth: ringLineWidth, progress: ring.progress)
                    x += ringSize
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawRing(in ctx: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat, progress: Double?) {
        let startAngle = CGFloat.pi / 2

        // No reading: a dashed track only, so "can't tell" never passes for 0%.
        guard let progress else {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.gray.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(lineWidth * 0.6)
            ctx.setLineDash(phase: 0, lengths: [2, 2])
            ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            ctx.strokePath()
            ctx.restoreGState()
            return
        }

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
