import Testing
@testable import Compositor
import Foundation
import CoreGraphics

/// Stage 2b's `selection.*` commands and the `editSelection` tool: validation (including the
/// explicit-empty-selection trap), applying through the Select menu's own methods as one undo
/// step, and the tool turning named regions into coordinates.
@MainActor
struct SelectionCommandTests {
    private func session() -> (EditorSession, EditCommandRunner) {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200, emptyLayer: true)
        return (session, EditCommandRunner(session: session))
    }

    private func decode(_ name: String, _ arguments: String = "{}") throws -> EditCommand {
        try EditCommandRunner.decode(command: name, argumentsJSON: arguments).get()
    }

    @Test func shapesMustOverlapTheCanvasAndHaveSize() throws {
        let (_, runner) = session()
        // Entirely off the canvas would clip to an explicit empty selection: "touch nothing".
        let outside = runner.propose(try decode("selection.rect", "{\"x\":500,\"y\":0,\"width\":50,\"height\":50}"))
        if case .failure(let error) = outside { #expect(error.message.contains("400×200")) } else { Issue.record("expected failure") }
        let flat = runner.propose(try decode("selection.ellipse", "{\"x\":0,\"y\":0,\"width\":0,\"height\":50}"))
        if case .failure(let error) = flat { #expect(error.code == "invalid_arguments") } else { Issue.record("expected failure") }

        let rect = try runner.propose(decode("selection.rect", "{\"x\":10,\"y\":20,\"width\":30,\"height\":40}")).get()
        #expect(rect.summary == "사각형 선택 (10, 20, 30×40)")
    }

    @Test func modifyingNeedsASelectionNowOrEarlierInTheProposal() throws {
        let (_, runner) = session()
        for name in ["selection.invert"] {
            if case .success = runner.propose(try decode(name)) { Issue.record("\(name) without a selection should be refused") }
        }
        if case .success = runner.propose(try decode("selection.feather", "{\"amount\":5}")) {
            Issue.record("feather without a selection should be refused")
        }
        // A shape earlier in the same proposal counts.
        let feather = try runner.propose(decode("selection.feather", "{\"amount\":5}"), selectionPending: true).get()
        #expect(feather.summary == "선택 영역 경계 5px 부드럽게")
        if case .success = runner.propose(try decode("selection.expand", "{\"amount\":900}"), selectionPending: true) {
            Issue.record("expand beyond 500 px should be refused")
        }
    }

    @Test func aSelectionBatchIsOneUndoStepThroughTheMenuMethods() async throws {
        let (session, runner) = session()
        let undoCount = session.history.undoCount
        let collector = ProposalCollector()
        collector.append(try runner.propose(decode("selection.rect", "{\"x\":0,\"y\":0,\"width\":200,\"height\":200}")).get())
        collector.append(try runner.propose(decode("selection.feather", "{\"amount\":6}"), selectionPending: collector.selectionPending).get())

        _ = try await runner.applyBatch(collector.edits.map(\.command), label: "select").get()
        let selection = try #require(session.selection)
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(selection.feather == 6)
        #expect(session.history.undoCount == undoCount + 1)

        session.undo()
        #expect(session.selection == nil)
    }

    @Test func addingCombinesAndDeselectingTwiceIsHarmless() async throws {
        let (session, runner) = session()
        _ = try await runner.applyBatch([
            .selectionRect(SelectionShape(x: 0, y: 0, width: 100, height: 100)),
            .selectionRect(SelectionShape(x: 300, y: 0, width: 100, height: 100, mode: .add))
        ], label: "add").get()
        #expect(session.selection?.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 400, height: 100))

        _ = try await runner.applyBatch([.selectionDeselect, .selectionDeselect], label: "clear").get()
        #expect(session.selection == nil)
    }

    @Test func theToolWorksOutNamedRegionsFromTheCanvas() {
        let canvas = CGSize(width: 400, height: 200)
        func frame(_ region: EditSelectionTool.Region?, x: Double? = nil, y: Double? = nil, width: Double? = nil, height: Double? = nil) -> [Double?] {
            let f = EditSelectionTool.frame(for: .init(action: .rectangle, region: region, x: x, y: y, width: width, height: height, amount: nil),
                                            canvas: canvas)
            return [f.x, f.y, f.width, f.height]
        }
        #expect(frame(.leftHalf) == [0, 0, 200, 200])
        #expect(frame(.bottomHalf) == [0, 100, 400, 100])
        #expect(frame(.center, width: 100, height: 50) == [150, 75, 100, 50])
        // One side given means a square; the model often left the height out.
        #expect(frame(.center, width: 100) == [150, 50, 100, 100])
        #expect(frame(.custom, x: 1, y: 2, width: 3, height: 4) == [1, 2, 3, 4])
        // No region but only a size: centered.
        #expect(frame(nil, width: 80, height: 80) == [160, 60, 80, 80])
    }

    @Test func theToolProposesAddsAndNeverSubtracts() async throws {
        let (session, runner) = session()
        session.selectAll()
        let proposals = ProposalCollector()
        let tool = EditSelectionTool(backend: CompositorToolBackend(runner: runner, mailbox: CanvasImageMailbox(), proposals: proposals))
        _ = try await tool.call(arguments: .init(action: .addEllipse, region: .center, x: nil, y: nil, width: 80, height: nil, amount: nil))
        #expect(proposals.edits.map(\.command) == [.selectionEllipse(SelectionShape(x: 160, y: 60, width: 80, height: 80, mode: .add))])
        #expect(!EditSelectionTool.Action.allCases.map(\.rawValue).contains { $0.lowercased().contains("subtract") })
    }
}
