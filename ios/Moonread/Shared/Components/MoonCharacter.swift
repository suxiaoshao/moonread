import SwiftUI

/// The moon expresses task state, never a tool, expression or prop.
enum MoonPose: Equatable, CaseIterable {
    case idle, answering, needsYou, done, doneReview, failed

    var completed: Bool { self == .done || self == .doneReview }
    static func live(running: Bool, status: AIAgentStatus, hasTools: Bool, reasoning: Bool) -> Self {
        guard running else { return .idle }
        if status == .waitingConfirmation || status == .waitingDataSharing { return .needsYou }
        if status == .compacting { return .idle }
        return hasTools || reasoning ? .answering : .idle
    }
}

/// Fixed brand geometry on a 100-unit canvas, with a 72-unit navy disc.
/// The gold moon is the icon's outer circle minus a 0.84r inner circle,
/// offset in the (0.8, -0.6) direction. Only the offset changes with phase.
struct MoonArtwork {
    struct Palette {
        let disc = Color(red: 31 / 255, green: 44 / 255, blue: 92 / 255)
        let gold = Color(red: 247 / 255, green: 199 / 255, blue: 95 / 255)
        let dimDisc = Color(red: 20 / 255, green: 29 / 255, blue: 60 / 255)
        let dimGold = Color(red: 136 / 255, green: 109 / 255, blue: 52 / 255)
        let accent: Color
        let failure: Color
        let onFailure: Color
        init(_ theme: ThemeSurface) {
            accent = Color(uiColor: theme.accent)
            failure = Color(uiColor: theme.destructive); onFailure = Color(uiColor: theme.onDestructive)
        }
    }
    static let disc = CGRect(x: 14, y: 14, width: 72, height: 72)
    let pose: MoonPose
    let palette: Palette
    /// nil is the complete still state, including with Reduce Motion.
    let time: Double?
    var backing: Color? = nil
    var shadow: Color = .clear

    var phase: CGFloat {
        guard pose.completed else { return 0.5 }
        guard let time else { return 1.35 }
        let p = min(1, max(0, time / 0.4))
        return 0.5 + 0.85 * p * p * (3 - 2 * p)
    }
    var haloOpacity: Double {
        if pose == .answering {
            guard let time else { return 0.16 }
            return 0.16 - 0.06 * cos(time * 2 * .pi / 3)
        }
        if pose.completed, let time, time < 0.9 {
            let p = max(0, time / 0.9)
            return 0.22 * sin(p * .pi)
        }
        return 0
    }
    func draw(in context: GraphicsContext, unit: CGFloat, origin: CGPoint) {
        var c = context
        c.translateBy(x: origin.x, y: origin.y); c.scaleBy(x: unit, y: unit)
        if haloOpacity > 0 {
            c.stroke(Path(ellipseIn: Self.disc.insetBy(dx: -7, dy: -7)),
                     with: .color(palette.gold.opacity(haloOpacity)), lineWidth: 8)
        }
        let disk = Path(ellipseIn: Self.disc)
        if let backing {
            var rim = c
            rim.addFilter(.shadow(color: shadow, radius: 4, y: 1))
            // One opaque backing pass: a second shadowed draw would shade the
            // paper rim again. The shadow belongs behind the whole clearance.
            rim.fill(Path(ellipseIn: Self.disc.insetBy(dx: -3.5, dy: -3.5)), with: .color(backing))
        }
        let dimmed = pose == .failed
        c.fill(disk, with: .color(dimmed ? palette.dimDisc : palette.disc))
        let radius: CGFloat = 26, inner = radius * 0.84
        let moon = Path(ellipseIn: CGRect(x: 50 - radius, y: 50 - radius, width: radius * 2, height: radius * 2))
            .subtracting(Path(ellipseIn: CGRect(x: 50 + 0.8 * phase * radius - inner,
                                               y: 50 - 0.6 * phase * radius - inner,
                                               width: inner * 2, height: inner * 2)))
        c.fill(moon, with: .color(dimmed ? palette.dimGold : palette.gold))
        if pose == .needsYou || pose == .doneReview || dimmed {
            let badge = Path(ellipseIn: CGRect(x: 68, y: 16, width: 18, height: 18))
            if let backing { c.stroke(badge, with: .color(backing), lineWidth: 4) }
            c.fill(badge, with: .color(dimmed ? palette.failure : pose == .needsYou ? palette.accent : palette.gold))
            if dimmed {
                var mark = Path(); mark.move(to: CGPoint(x: 77, y: 20)); mark.addLine(to: CGPoint(x: 77, y: 26))
                c.stroke(mark, with: .color(palette.onFailure), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                c.fill(Path(ellipseIn: CGRect(x: 76, y: 29, width: 2, height: 2)), with: .color(palette.onFailure))
            }
        }
    }
}

/// 40pt disc, 56pt tappable canvas. Fixed brand colours; page colour is only
/// used for the clearance around the floating assistant.
struct MoonCharacter: View {
    let pose: MoonPose
    var discSize: CGFloat = 40
    var time: Double? = nil
    var floating = false
    @Environment(\.theme) private var theme
    static func frame(disc: CGFloat) -> CGFloat { disc * 1.4 }
    var body: some View {
        Canvas { context, _ in
            MoonArtwork(pose: pose, palette: .init(theme), time: time,
                        backing: floating ? Color(uiColor: theme.paper) : nil,
                        shadow: .black.opacity(theme.scheme == .dark ? 0.3 : 0.12))
                .draw(in: context, unit: discSize / 72,
                      origin: CGPoint(x: (Self.frame(disc: discSize) - discSize * 100 / 72) / 2,
                                      y: (Self.frame(disc: discSize) - discSize * 100 / 72) / 2))
        }
        .frame(width: Self.frame(disc: discSize), height: Self.frame(disc: discSize))
        .accessibilityHidden(true)
    }
}
