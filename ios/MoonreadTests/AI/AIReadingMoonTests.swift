import SwiftUI
import XCTest
@testable import Moonread

@MainActor
final class AIReadingMoonTests: XCTestCase {
    private func snapshot(_ status: AIAgentStatus, running: Bool, pose: MoonPose = .idle, id: String = "c1") -> AIMoonSnapshot {
        AIMoonSnapshot(conversationID: id, running: running, status: status, pose: pose, label: "")
    }

    func testOpeningIsABaselineAndRefreshesNeverReplayOutcomes() {
        var presence = AIMoonPresence()
        presence.observe(snapshot(.completed, running: false), chatOpen: false) { XCTFail("no outcome on a baseline"); return false }
        presence.observe(snapshot(.completed, running: false), chatOpen: false) { XCTFail("no outcome on a refresh"); return false }
        presence.observe(snapshot(.failed, running: false, id: "c2"), chatOpen: false) { false }
        XCTAssertNil(presence.reveal())
        XCTAssertEqual(presence.pose(live: .idle), .idle)
    }

    func testCompletionShowsBriefDoneThenRests() throws {
        var presence = AIMoonPresence()
        presence.observe(snapshot(.running, running: true, pose: .answering), chatOpen: false) { false }
        XCTAssertEqual(presence.pose(live: .answering), .answering)
        presence.observe(snapshot(.completed, running: false), chatOpen: false) { false }
        let shown = try XCTUnwrap(presence.reveal())
        XCTAssertEqual(shown.notice, .outcome(.done))
        XCTAssertEqual(shown.notice.duration, .seconds(2))
        XCTAssertEqual(presence.pose(live: .idle), .done)
        presence.expire(shown.id)
        XCTAssertNil(presence.shown)
        XCTAssertEqual(presence.pose(live: .idle), .idle, "Plain completion leaves nothing behind")
        presence.observe(snapshot(.completed, running: false), chatOpen: false) { false }
        XCTAssertNil(presence.reveal(), "Acknowledged outcomes are not replayed")
    }

    func testReviewAndFailureStayUnseenUntilTheConversationOpens() throws {
        var presence = AIMoonPresence()
        presence.observe(snapshot(.running, running: true), chatOpen: false) { false }
        presence.observe(snapshot(.completed, running: false), chatOpen: false) { true }
        let review = try XCTUnwrap(presence.reveal())
        XCTAssertEqual(review.notice, .outcome(.doneReview)); XCTAssertEqual(review.notice.duration, .seconds(4))
        presence.expire(review.id)
        XCTAssertEqual(presence.pose(live: .idle), .doneReview)

        presence.observe(snapshot(.running, running: true, pose: .answering), chatOpen: false) { false }
        XCTAssertEqual(presence.pose(live: .answering), .answering, "A new run supersedes the old outcome")
        presence.observe(snapshot(.limitReached, running: false), chatOpen: false) { false }
        let failure = try XCTUnwrap(presence.reveal())
        XCTAssertEqual(failure.notice, .outcome(.failed)); XCTAssertEqual(failure.notice.duration, .seconds(5))
        presence.expire(failure.id)
        XCTAssertEqual(presence.pose(live: .idle), .failed)
        presence.chatOpened()
        XCTAssertEqual(presence.pose(live: .idle), .idle)
    }

    func testWaitingConfirmationIsABriefNoticeAndReturnsWithControls() throws {
        var presence = AIMoonPresence()
        presence.observe(snapshot(.running, running: true, pose: .answering), chatOpen: false) { false }
        presence.observe(snapshot(.waitingConfirmation, running: true, pose: .needsYou), chatOpen: false) { false }
        let notice = try XCTUnwrap(presence.reveal())
        XCTAssertEqual(notice.notice, .needsYou); XCTAssertEqual(notice.notice.duration, .seconds(6))
        presence.expire(notice.id)
        XCTAssertNil(presence.shown, "Waiting hides after its notice")
        XCTAssertEqual(presence.pose(live: .needsYou), .needsYou, "Opening the controls shows the waiting state again")
        presence.observe(snapshot(.waitingConfirmation, running: true, pose: .needsYou), chatOpen: false) { false }
        XCTAssertNil(presence.reveal())
    }

    func testStopAndOpenChatProduceNoNotice() {
        var presence = AIMoonPresence()
        presence.observe(snapshot(.running, running: true), chatOpen: false) { false }
        presence.observe(snapshot(.stopped, running: false), chatOpen: false) { false }
        XCTAssertNil(presence.reveal())
        presence.observe(snapshot(.running, running: true), chatOpen: true) { false }
        presence.observe(snapshot(.waitingConfirmation, running: true), chatOpen: true) { false }
        presence.observe(snapshot(.failed, running: false), chatOpen: true) { false }
        XCTAssertNil(presence.reveal(), "Events seen in the open conversation need no reading notice")
        XCTAssertEqual(presence.pose(live: .idle), .idle)
    }

    func testClosingTheChatDuringARunShowsWhatIsHappening() throws {
        var presence = AIMoonPresence()
        presence.observe(snapshot(.running, running: true, pose: .answering), chatOpen: true) { false }
        presence.chatClosed()
        let working = try XCTUnwrap(presence.reveal())
        XCTAssertEqual(working.notice, .working); XCTAssertEqual(working.notice.duration, .milliseconds(2500))
        presence.conceal()
        XCTAssertNil(presence.shown, "A panel or background ends the notice")
        presence.observe(snapshot(.waitingConfirmation, running: true), chatOpen: true) { false }
        presence.chatClosed()
        XCTAssertEqual(presence.reveal()?.notice, .needsYou)
    }

    func testLiveStateUsesOneWorkingPoseAndPreservesImmediateOutcomes() {
        XCTAssertEqual(MoonPose.allCases.count, 6)
        XCTAssertEqual(MoonPose.live(running: false, status: .completed, hasTools: true, reasoning: true), .idle)
        XCTAssertEqual(MoonPose.live(running: true, status: .running, hasTools: false, reasoning: false), .idle)
        XCTAssertEqual(MoonPose.live(running: true, status: .running, hasTools: true, reasoning: false), .answering)
        XCTAssertEqual(MoonPose.live(running: true, status: .running, hasTools: false, reasoning: true), .answering)
        XCTAssertEqual(MoonPose.live(running: true, status: .compacting, hasTools: true, reasoning: true), .idle)
        XCTAssertEqual(MoonPose.live(running: true, status: .waitingConfirmation, hasTools: true, reasoning: true), .needsYou)
        XCTAssertTrue(MoonPose.needsYou.immediate && MoonPose.failed.immediate)
        XCTAssertFalse(MoonPose.answering.immediate || MoonPose.idle.immediate)
    }

}

/// Renders the character through the production views so its small-size,
/// light/dark and still (Reduce Motion) frames can be inspected as images.
@MainActor
final class MoonCharacterRenderingTests: XCTestCase {
    private func surface(_ system: ThemeAppearance) throws -> ThemeSurface {
        ThemeSurface(plan: try resolveThemes(value: defaultThemeSnapshot(), system: system, highContrast: false).reader)
    }

    private func sheet(_ theme: ThemeSurface, disc: CGFloat, time: Double?) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(MoonPose.allCases, id: \.self) { pose in
                MoonCharacter(pose: pose, discSize: disc, time: time, floating: true)
            }
        }
        .padding(8)
        .background(Color(uiColor: theme.paper))
        .environment(\.theme, theme)
    }

    func testMoonPhaseAndHaloKeepStaticGeometryAndReduceMotionKeyframes() throws {
        let palette = MoonArtwork.Palette(try surface(.light))
        func art(_ pose: MoonPose, _ time: Double?) -> MoonArtwork { .init(pose: pose, palette: palette, time: time) }
        XCTAssertEqual(art(.idle, nil).phase, 0.5)
        XCTAssertEqual(art(.done, nil).phase, 1.35)
        XCTAssertEqual(art(.doneReview, nil).haloOpacity, 0)
        XCTAssertEqual(art(.done, 0).phase, 0.5)
        XCTAssertGreaterThan(art(.done, 0.2).phase, art(.done, 0).phase)
        XCTAssertEqual(art(.done, 0.4).phase, 1.35, accuracy: 0.001)
        XCTAssertEqual(art(.answering, 0).haloOpacity, 0.10, accuracy: 0.001)
        XCTAssertEqual(art(.answering, 1.5).haloOpacity, 0.22, accuracy: 0.001)
        XCTAssertEqual(art(.answering, nil).haloOpacity, 0.16)
        XCTAssertEqual(art(.failed, 1).haloOpacity, 0)
        XCTAssertEqual(art(.done, 1).haloOpacity, 0)
    }

    func testFloatingMoonHasOpaquePaperClearanceOverInkInBothAppearances() throws {
        for appearance in [ThemeAppearance.light, .dark] {
            let theme = try surface(appearance)
            let renderer = ImageRenderer(content: ZStack {
                Color(uiColor: theme.ink)
                MoonCharacter(pose: .idle, floating: true)
            }.frame(width: 56, height: 56).environment(\.theme, theme))
            renderer.scale = 3
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            // 0.7pt outside the 20pt disc radius, inside the paper-coloured rim.
            let i = (image.height / 2 * image.width + Int(48.7 * 3)) * 4
            let expected = theme.paper.opaqueRGB
            for (channel, shift) in [16, 8, 0].enumerated() {
                XCTAssertEqual(Double(pixels[i + channel]), Double((expected >> shift) & 255), accuracy: 2,
                    "Underlying ink must be covered by opaque reading paper")
            }
        }
    }

    func testEveryPoseRendersAtReadingSizeInLightAndDark() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "moonlight", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", ThemeAppearance.light), ("dark", .dark)] {
            let theme = try surface(appearance)
            // nil is the still key frame used with Reduce Motion; the others are animation frames.
            for (frame, time) in [("still", nil), ("t0.2", 0.2), ("t1.5", 1.5)] as [(String, Double?)] {
                for disc in [40.0, 120.0] {
                    let renderer = ImageRenderer(content: sheet(theme, disc: disc, time: time))
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.uiImage, "\(name) \(frame) \(disc)")
                    XCTAssertGreaterThan(image.size.width, CGFloat(MoonPose.allCases.count) * MoonCharacter.frame(disc: disc))
                    let data = try XCTUnwrap(image.pngData())
                    try data.write(to: directory.appending(path: "\(name)-\(frame)-\(Int(disc)).png"))
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                    attachment.name = "\(name)-\(frame)-\(Int(disc))"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
        // The 夜读 brand mark used by About and the title page, on light and dark paper.
        for (name, appearance) in [("light", ThemeAppearance.light), ("dark", .dark)] {
            let theme = try surface(appearance)
            let renderer = ImageRenderer(content: HStack(spacing: 16) { BrandSeal(size: 80); BrandSeal(size: 64) }
                .padding(12).background(Color(uiColor: theme.paper)))
            renderer.scale = 3
            let data = try XCTUnwrap(renderer.uiImage?.pngData())
            try data.write(to: directory.appending(path: "brand-seal-\(name).png"))
        }
        print("Moon character renders: \(directory.path)")
    }
}
