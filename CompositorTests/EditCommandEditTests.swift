import Testing
@testable import Compositor
import Foundation

/// Stage 2's `layer.*` commands: proposing (validation, pinning), applying as one undo step,
/// gating on what the person has open, and rolling back a batch that fails part way.
@MainActor
struct EditCommandEditTests {
    private func sessionWithLayer() -> (EditorSession, EditCommandRunner, UUID) {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100, emptyLayer: true)
        return (session, EditCommandRunner(session: session), session.activeLayerID!)
    }

    private func decode(_ name: String, _ arguments: String) throws -> EditCommand {
        try EditCommandRunner.decode(command: name, argumentsJSON: arguments).get()
    }

    @Test func proposingPinsActiveReferencesAndRejectsBadValues() throws {
        let (_, runner, id) = sessionWithLayer()

        let opacity = try runner.propose(decode("layer.setOpacity", "{\"layer\":{\"active\":true},\"opacity\":0.6}")).get()
        #expect(opacity.command == .layerSetOpacity(LayerSetOpacity(layer: .id(id), opacity: 0.6)))
        #expect(opacity.summary == "'Layer 1' 불투명도 60%")

        // 60 meant as a percentage is rejected, not clamped to 100%.
        let percent = runner.propose(try decode("layer.setOpacity", "{\"layer\":{\"active\":true},\"opacity\":60}"))
        #expect((try? percent.get()) == nil)
        if case .failure(let error) = percent { #expect(error.code == "invalid_arguments") }

        let blend = runner.propose(try decode("layer.setBlendMode", "{\"layer\":{\"active\":true},\"blendMode\":\"Sparkle\"}"))
        if case .failure(let error) = blend { #expect(error.message.contains("Multiply")) } else { Issue.record("expected failure") }

        let missing = runner.propose(try decode("layer.delete", "{\"layer\":{\"name\":\"Nope\"}}"))
        if case .failure(let error) = missing { #expect(error.code == "layer_not_found") } else { Issue.record("expected failure") }
    }

    @Test func folderBlendModesAreRefused() throws {
        let (session, runner, _) = sessionWithLayer()
        session.addGroup()
        let result = runner.propose(try decode("layer.setBlendMode", "{\"layer\":{\"active\":true},\"blendMode\":\"Multiply\"}"))
        if case .failure(let error) = result { #expect(error.code == "not_supported") } else { Issue.record("expected failure") }
    }

    @Test func aBatchAppliesAsOneUndoStepAndUndoesCompletely() async throws {
        let (session, runner, id) = sessionWithLayer()
        let before = session.document
        let undoCount = session.history.undoCount

        // A later edit targets a layer only an earlier edit in the same proposal creates.
        let collector = ProposalCollector()
        for (name, arguments) in [
            ("layer.add", "{\"name\":\"Sky\"}"),
            ("layer.setOpacity", "{\"layer\":{\"name\":\"Sky\"},\"opacity\":0.25}"),
            ("layer.setBlendMode", "{\"layer\":{\"name\":\"Sky\"},\"blendMode\":\"screen\"}"),
            ("layer.setVisibility", "{\"layer\":{\"index\":0},\"visible\":false}")
        ] {
            collector.append(try runner.propose(decode(name, arguments), pendingNames: collector.pendingNames).get())
        }

        let report = try await runner.applyBatch(collector.edits.map(\.command), label: "test").get()
        #expect(report.undoName == "AI: test")
        #expect(session.history.undoCount == undoCount + 1)
        let sky = try #require(session.document?.layers.first { $0.name == "Sky" })
        #expect(sky.opacity == 0.25)
        #expect(sky.blendMode == .screen)
        #expect(session.document?.layers.first { $0.id == id }?.isVisible == false)

        session.undo()
        #expect(session.document == before)
    }

    @Test func renamedLayersCanBeTargetedByTheirNewName() async throws {
        let (session, runner, id) = sessionWithLayer()
        let collector = ProposalCollector()
        collector.append(try runner.propose(decode("layer.rename", "{\"layer\":{\"active\":true},\"name\":\"Ground\"}")).get())
        collector.append(try runner.propose(decode("layer.setOpacity", "{\"layer\":{\"name\":\"Ground\"},\"opacity\":0.5}"),
                                            pendingNames: collector.pendingNames).get())
        _ = try await runner.applyBatch(collector.edits.map(\.command), label: "rename").get()
        let layer = try #require(session.document?.layers.first { $0.id == id })
        #expect(layer.name == "Ground")
        #expect(layer.opacity == 0.5)
    }

    @Test func aFailingBatchLeavesTheDocumentUnchanged() async throws {
        let (session, runner, id) = sessionWithLayer()
        let before = session.document
        let undoCount = session.history.undoCount
        let result = await runner.applyBatch([
            .layerSetOpacity(LayerSetOpacity(layer: .id(id), opacity: 0.3)),
            .layerRename(LayerRename(layer: .name("Gone"), name: "x"))
        ], label: "broken")
        if case .failure(let error) = result { #expect(error.code == "layer_not_found") } else { Issue.record("expected failure") }
        #expect(session.document == before)
        #expect(session.history.undoCount == undoCount)
    }

    @Test func editsWaitWhileThePersonHasSomethingOpen() async throws {
        let (session, runner, id) = sessionWithLayer()
        let before = session.document

        session.beginOpacityEdit()
        let dragging = await runner.applyBatch([.layerSetOpacity(LayerSetOpacity(layer: .id(id), opacity: 0.3))], label: "x")
        if case .failure(let error) = dragging { #expect(error.code == "busy") } else { Issue.record("expected busy") }
        session.finishOpacityEdit()

        session.isProjectBusy = true
        let busy = await runner.applyBatch([.layerSetVisibility(LayerSetVisibility(layer: .id(id), visible: false))], label: "x")
        if case .failure(let error) = busy { #expect(error.message.contains("busy")) } else { Issue.record("expected busy") }
        session.isProjectBusy = false

        #expect(session.document == before)
    }

    /// Deleting a live-mask source would stop for a Bake / Remove Links alert only the person can answer.
    @Test func liveMaskSourcesAreNotDeleted() throws {
        let (session, runner, source) = sessionWithLayer()
        session.addBlankLayer()
        let dependent = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == dependent })
        session.document?.layers[index].maskSourceID = source
        let result = runner.propose(.layerDelete(LayerDelete(layer: .id(source))))
        if case .failure(let error) = result { #expect(error.code == "not_supported") } else { Issue.record("expected failure") }
    }

    @Test func editsCannotBypassApprovalThroughRunJSON() async throws {
        let (session, runner, _) = sessionWithLayer()
        let before = session.document
        let json = await runner.runJSON(command: "layer.delete", argumentsJSON: "{\"layer\":{\"active\":true}}")
        #expect(json.contains("not_supported"))
        #expect(session.document == before)
    }

    @Test func theToolQueuesEditsInsteadOfRunningThem() async throws {
        let (session, runner, _) = sessionWithLayer()
        let before = session.document
        let proposals = ProposalCollector()
        let tool = EditLayerTool(backend: CompositorToolBackend(runner: runner, mailbox: CanvasImageMailbox(), proposals: proposals))
        let output = try await tool.call(arguments: .init(action: .setOpacity, layer: "Layer 1", value: "40"))
        #expect(output.contains("proposed"))
        #expect(proposals.edits.map(\.command) == [.layerSetOpacity(LayerSetOpacity(layer: .id(session.activeLayerID!), opacity: 0.4))])
        #expect(session.document == before)

        let hide = try await tool.call(arguments: .init(action: .hide, layer: "Layer 1", value: nil))
        #expect(hide.contains("proposed"))
        #expect(proposals.edits.last?.summary == "'Layer 1' 숨기기")

        // A missing required field comes back as a structured error, not a crash or a guess.
        let noName = try await tool.call(arguments: .init(action: .rename, layer: "Layer 1", value: nil))
        #expect(noName.contains("invalid_arguments"))
    }

    /// A model correcting itself replaces its earlier edit of the same value on the same layer.
    @Test func aLaterSetterOnTheSameLayerSupersedesTheEarlierOne() throws {
        let (_, runner, id) = sessionWithLayer()
        let collector = ProposalCollector()
        collector.append(try runner.propose(decode("layer.rename", "{\"layer\":\"Layer 1\",\"name\":\"Background\"}")).get())
        collector.append(try runner.propose(decode("layer.setOpacity", "{\"layer\":\"Layer 1\",\"opacity\":0.5}")).get())
        collector.append(try runner.propose(decode("layer.rename", "{\"layer\":\"Layer 1\",\"name\":\"배경\"}")).get())
        #expect(collector.edits.map(\.command) == [
            .layerRename(LayerRename(layer: .id(id), name: "배경")),
            .layerSetOpacity(LayerSetOpacity(layer: .id(id), opacity: 0.5))
        ])
    }

    /// Names the model translated or invented are flagged on the approval card.
    @Test func namesMissingFromTheRequestAreFlagged() async throws {
        let (_, runner, _) = sessionWithLayer()
        let proposals = ProposalCollector()
        let tool = EditLayerTool(backend: CompositorToolBackend(runner: runner, mailbox: CanvasImageMailbox(), proposals: proposals))

        proposals.request = "Layer 1 이름을 배경으로 바꿔줘"
        let translated = try await tool.call(arguments: .init(action: .rename, layer: "Layer 1", value: "Background"))
        #expect(translated.contains("warning"))
        #expect(proposals.edits.last?.warning?.contains("Background") == true)

        let exact = try await tool.call(arguments: .init(action: .rename, layer: "Layer 1", value: "배경"))
        #expect(!exact.contains("warning"))
        #expect(proposals.edits.count == 1) // Superseded the flagged one.
        #expect(proposals.edits.last?.warning == nil)
    }

    /// The tool takes opacity in percent; the document stores 0–1.
    @Test func toolOpacityIsReadAsPercent() {
        #expect(EditLayerTool.opacity(from: "50") == 0.5)
        #expect(EditLayerTool.opacity(from: "50%") == 0.5)
        #expect(EditLayerTool.opacity(from: "0.5") == 0.5)
        #expect(EditLayerTool.opacity(from: "1") == 0.01)
        #expect(EditLayerTool.opacity(from: "150") == 1.5) // Rejected later by the runner, not clamped.
        #expect(EditLayerTool.opacity(from: "half") == nil)
    }

    @Test func layerReferencesAcceptBareNamesAndIndices() throws {
        let decoded = try EditCommandRunner.decode(command: "layer.delete", argumentsJSON: "{\"layer\":\"Sky\"}").get()
        #expect(decoded == .layerDelete(LayerDelete(layer: .name("Sky"))))
        let byIndex = try EditCommandRunner.decode(command: "layer.delete", argumentsJSON: "{\"layer\":2}").get()
        #expect(byIndex == .layerDelete(LayerDelete(layer: .index(2))))
        let id = UUID()
        let byID = try EditCommandRunner.decode(command: "layer.delete", argumentsJSON: "{\"layer\":\"\(id.uuidString)\"}").get()
        #expect(byID == .layerDelete(LayerDelete(layer: .id(id))))
    }
}
