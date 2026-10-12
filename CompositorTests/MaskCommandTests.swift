import Testing
@testable import Compositor
import Foundation
import CoreGraphics

/// Stage 2c's `mask.*` commands and the `editMask` tool: plain and selection-made masks (named by
/// what shows, since this app's default Add Mask hides the selection), on/off, delete, clipping,
/// all through the Layers panel's own methods as one undo step.
@MainActor
struct MaskCommandTests {
    private func session() -> (EditorSession, EditCommandRunner, lower: UUID, upper: UUID) {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100, emptyLayer: true)
        let lower = session.activeLayerID!
        session.renameLayer(lower, to: "Lower")
        session.addBlankLayer()
        let upper = session.activeLayerID!
        session.renameLayer(upper, to: "Upper")
        return (session, EditCommandRunner(session: session), lower, upper)
    }

    private func layer(_ session: EditorSession, _ id: UUID) -> ImageLayer? {
        session.document?.layers.first { $0.id == id }
    }

    /// The mask's gray value at a document point, for a mask covering an unmoved full-canvas layer.
    private func maskGray(_ mask: LayerMask, at point: CGPoint, canvasWidth: Int) throws -> UInt8 {
        let image = mask.asset.image
        let scale = CGFloat(image.width) / CGFloat(canvasWidth)
        var pixel: UInt8 = 0
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        // Draw so the sampled document point lands on the single pixel (CG's origin is bottom-left).
        let x = point.x * scale, y = CGFloat(image.height) - point.y * scale
        context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
        return pixel
    }

    @Test func plainMasksApplyAsOneUndoStep() async throws {
        let (session, runner, lower, upper) = session()
        let undoCount = session.history.undoCount
        _ = try await runner.applyBatch([
            .maskAdd(MaskAdd(layer: .id(lower), reveal: true)),
            .maskAdd(MaskAdd(layer: .id(upper), reveal: false))
        ], label: "masks").get()
        #expect(layer(session, lower)?.mask != nil)
        #expect(try maskGray(#require(layer(session, upper)?.mask), at: CGPoint(x: 10, y: 10), canvasWidth: 200) == 0)
        #expect(session.history.undoCount == undoCount + 1)
        session.undo()
        #expect(layer(session, lower)?.mask == nil && layer(session, upper)?.mask == nil)
    }

    /// Named by the result: "shows selection" must leave the selected area white.
    @Test func aSelectionMaskShowsWhatItSaysAndUsesUpTheSelection() async throws {
        let (session, runner, lower, upper) = session()
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil), mode: .replace, name: "seed")
        _ = try await runner.applyBatch([.maskAddFromSelection(MaskFromSelection(layer: .id(upper), shows: .selection))], label: "m").get()
        let mask = try #require(layer(session, upper)?.mask)
        #expect(try maskGray(mask, at: CGPoint(x: 50, y: 50), canvasWidth: 200) == 255)
        #expect(try maskGray(mask, at: CGPoint(x: 150, y: 50), canvasWidth: 200) == 0)
        #expect(session.selection == nil)

        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil), mode: .replace, name: "seed")
        _ = try await runner.applyBatch([.maskAddFromSelection(MaskFromSelection(layer: .id(lower), shows: .outside))], label: "m").get()
        let outside = try #require(layer(session, lower)?.mask)
        #expect(try maskGray(outside, at: CGPoint(x: 50, y: 50), canvasWidth: 200) == 0)
        #expect(try maskGray(outside, at: CGPoint(x: 150, y: 50), canvasWidth: 200) == 255)
    }

    @Test func proposingChecksTheMaskState() throws {
        let (session, runner, lower, upper) = session()
        if case .success = runner.propose(.maskDelete(MaskTarget(layer: .id(upper)))) { Issue.record("no mask to delete") }
        if case .success = runner.propose(.maskAddFromSelection(MaskFromSelection(layer: .id(upper), shows: .selection))) {
            Issue.record("no selection to make a mask from")
        }
        // The bottom layer has nothing below it to clip to.
        if case .success = runner.propose(.maskClipToBelow(MaskTarget(layer: .id(lower)))) { Issue.record("nothing below") }

        session.selectLayer(upper)
        session.addLayerMask(revealing: true)
        if case .success = runner.propose(.maskAdd(MaskAdd(layer: .id(upper), reveal: true))) { Issue.record("already masked") }
        let off = try runner.propose(.maskSetEnabled(MaskSetEnabled(layer: .id(upper), enabled: false))).get()
        #expect(off.summary == "'Upper' 마스크 끄기")
        #expect(try runner.propose(.maskDelete(MaskTarget(layer: .id(upper)))).get().isDestructive)
    }

    @Test func masksTurnOffAndDelete() async throws {
        let (session, runner, _, upper) = session()
        session.addLayerMask(revealing: true)
        _ = try await runner.applyBatch([.maskSetEnabled(MaskSetEnabled(layer: .id(upper), enabled: false))], label: "off").get()
        #expect(layer(session, upper)?.mask?.isEnabled == false)
        _ = try await runner.applyBatch([.maskDelete(MaskTarget(layer: .id(upper)))], label: "delete").get()
        #expect(layer(session, upper)?.mask == nil)
    }

    @Test func clippingAttachesToTheLayerBelowAndReleases() async throws {
        let (session, runner, lower, upper) = session()
        let clip = try runner.propose(.maskClipToBelow(MaskTarget(layer: .name("Upper")))).get()
        #expect(clip.summary == "'Upper'을(를) 아래 'Lower'에 클리핑")
        _ = try await runner.applyBatch([clip.command], label: "clip").get()
        #expect(layer(session, upper)?.maskSourceID == lower)
        _ = try await runner.applyBatch([.maskReleaseClipping(MaskTarget(layer: .id(upper)))], label: "release").get()
        #expect(layer(session, upper)?.maskSourceID == nil)
    }

    @Test func aSecondMaskOnTheSameLayerSupersedesTheFirst() throws {
        let (_, runner, _, upper) = session()
        let collector = ProposalCollector()
        collector.append(try runner.propose(.maskAdd(MaskAdd(layer: .id(upper), reveal: true))).get())
        collector.append(try runner.propose(.maskAdd(MaskAdd(layer: .id(upper), reveal: false))).get())
        #expect(collector.edits.map(\.command) == [.maskAdd(MaskAdd(layer: .id(upper), reveal: false))])
    }

    /// The tool speaks in what shows, never "hide" — "숨겨줘" must reach editLayer's hide.
    @Test func theToolMapsActionsAndNeverSaysHide() async throws {
        let (_, runner, _, upper) = session()
        let proposals = ProposalCollector()
        let tool = EditMaskTool(backend: CompositorToolBackend(runner: runner, mailbox: CanvasImageMailbox(), proposals: proposals))
        _ = try await tool.call(arguments: .init(action: .addMaskShowingNothing, layer: "Upper"))
        #expect(proposals.edits.map(\.command) == [.maskAdd(MaskAdd(layer: .id(upper), reveal: false))])
        #expect(!EditMaskTool.Action.allCases.contains { $0.rawValue.lowercased().contains("hide") })
    }
}
