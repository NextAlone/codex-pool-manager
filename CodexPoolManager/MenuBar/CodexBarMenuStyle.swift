// Adapted from steipete/CodexBar at b76508292e6849929bb4e838ee3d5d2a1072bc64.
// Copyright (c) 2026 Peter Steinberger. MIT; see ThirdPartyNotices/CodexBar.txt.
import SwiftUI

/// CodexBar's standard menu-card dimensions and default Codex accent.
enum CodexBarMenuStyle {
    static let width: CGFloat = 310
    static let horizontalPadding: CGFloat = 20
    static let headerVerticalPadding: CGFloat = 6
    static let headerContentSpacing: CGFloat = 6
    static let headerLineSpacing: CGFloat = 4
    static let headerColumnSpacing: CGFloat = 12
    static let usageTopPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 12
    static let sectionBottomPadding: CGFloat = 6
    static let primary = Color(nsColor: .controlTextColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let accent = Color(red: 73.0 / 255, green: 163.0 / 255, blue: 176.0 / 255)
    static let progressTrack = Color(nsColor: .tertiaryLabelColor).opacity(0.22)
}

/// MenuBarExtra uses a window host; request the same material as an AppKit menu.
struct CodexBarMenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct CodexBarUsageProgressBar: View {
    let percent: Double
    let pacePercent: Double?
    let paceOnTop: Bool
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let scale = max(displayScale, 1)
            let clamped = min(100, max(0, percent))
            let displayPercent = Int(clamped.rounded())
            let fillPercent = displayPercent <= 0 ? 0 : (displayPercent >= 100 ? 100 : clamped)
            let cornerSize = CGSize(width: size.height / 2, height: size.height / 2)
            let rect = CGRect(origin: .zero, size: size)
            context.clip(to: Path(rect))
            context.fill(Path(roundedRect: rect, cornerSize: cornerSize), with: .color(CodexBarMenuStyle.progressTrack))
            let fillWidth = size.width * fillPercent / 100
            if fillWidth > 0 {
                let fillRect = CGRect(x: 0, y: 0, width: min(fillWidth, size.width), height: size.height)
                context.fill(Path(roundedRect: fillRect, cornerSize: cornerSize), with: .color(CodexBarMenuStyle.accent))
            }
            if let pacePercent {
                let paceWidth = size.width * min(100, max(0, pacePercent)) / 100
                let tipWidth = max(25, size.height * 6.5)
                let tipOffset = paceWidth - tipWidth + 3 + 1 / scale
                let stripes = Self.paceStripePaths(size: CGSize(width: tipWidth, height: size.height), scale: scale)
                let shift = CGAffineTransform(translationX: tipOffset, y: 0)
                context.blendMode = .destinationOut
                context.fill(stripes.punched.applying(shift), with: .color(.white.opacity(0.9)))
                context.blendMode = .normal
                context.fill(stripes.center.applying(shift), with: .color(paceOnTop ? .green : .red))
            }
        }
        .frame(height: 6)
        .accessibilityLabel(L10n.text("usage.remaining_percent_format", Int(percent.rounded())))
    }

    private static func paceStripePaths(size: CGSize, scale: CGFloat) -> (punched: Path, center: Path) {
        let rect = CGRect(origin: .zero, size: size)
        let extend = size.height * 2
        let stripeTopY: CGFloat = -extend
        let stripeBottomY: CGFloat = size.height + extend
        let align: (CGFloat) -> CGFloat = { value in
            (value * scale).rounded() / scale
        }

        let stripeWidth = CGFloat(2)
        let punchWidth = stripeWidth * 3
        let stripeInset = 1 / scale
        let stripeAnchorX = align(rect.maxX - stripeInset)
        let stripeMinY = align(stripeTopY)
        let stripeMaxY = align(stripeBottomY)
        let anchorTopX = stripeAnchorX
        var punchedStripe = Path()
        var centerStripe = Path()
        let availableWidth = (anchorTopX - punchWidth) - rect.minX
        guard availableWidth >= 0 else { return (punchedStripe, centerStripe) }

        let punchRightTopX = align(anchorTopX)
        let punchLeftTopX = punchRightTopX - punchWidth
        let punchRightBottomX = punchRightTopX
        let punchLeftBottomX = punchLeftTopX
        punchedStripe.addPath(Path { path in
            path.move(to: CGPoint(x: punchLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: punchRightBottomX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: punchLeftBottomX, y: stripeMaxY))
            path.closeSubpath()
        })

        let centerLeftTopX = align(punchLeftTopX + (punchWidth - stripeWidth) / 2)
        let centerRightTopX = centerLeftTopX + stripeWidth
        let centerRightBottomX = centerRightTopX
        let centerLeftBottomX = centerLeftTopX
        centerStripe.addPath(Path { path in
            path.move(to: CGPoint(x: centerLeftTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightTopX, y: stripeMinY))
            path.addLine(to: CGPoint(x: centerRightBottomX, y: stripeMaxY))
            path.addLine(to: CGPoint(x: centerLeftBottomX, y: stripeMaxY))
            path.closeSubpath()
        })

        return (punchedStripe, centerStripe)
    }

}
