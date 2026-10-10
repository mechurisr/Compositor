import Testing
@testable import Compositor
import Foundation

@MainActor
struct EditCommandTests {
    private func sessionWithDocument() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 100, emptyLayer: true)
        return session
    }

    @Test func describeDocumentWithNoDocumentReturnsNullManifest() async throws {
        let session = EditorSession()
        let runner = EditCommandRunner(session: session)
        let result = await runner.run(.queryDescribeDocument)
        guard case .success(.document(let digest)) = result else { Issue.record("expected a document digest"); return }
        #expect(digest.manifest == nil)
        #expect(digest.activeLayerID == nil)
    }

    @Test func describeDocumentReportsCanvasAndActiveLayer() async throws {
        let session = sessionWithDocument()
        let runner = EditCommandRunner(session: session)
        let result = await runner.run(.queryDescribeDocument)
        guard case .success(.document(let digest)) = result else { Issue.record("expected a document digest"); return }
        #expect(digest.manifest?.width == 200)
        #expect(digest.manifest?.height == 100)
        #expect(digest.activeLayerID == session.activeLayerID)
        #expect(digest.manifest?.layers.count == 1)
    }

    @Test func describeLayerResolvesByNameIndexAndActive() async throws {
        let session = sessionWithDocument()
        session.addBlankLayer()
        let runner = EditCommandRunner(session: session)
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 2)

        let byName = await runner.run(.queryDescribeLayer(QueryDescribeLayer(layer: .name(layers[0].name))))
        guard case .success(.layer(let digest)) = byName else { Issue.record("expected a layer digest"); return }
        #expect(digest.id == layers[0].id)

        let byIndex = await runner.run(.queryDescribeLayer(QueryDescribeLayer(layer: .index(1))))
        guard case .success(.layer(let digest2)) = byIndex else { Issue.record("expected a layer digest"); return }
        #expect(digest2.id == layers[1].id)

        let byActive = await runner.run(.queryDescribeLayer(QueryDescribeLayer(layer: .active)))
        guard case .success(.layer(let digest3)) = byActive else { Issue.record("expected a layer digest"); return }
        #expect(digest3.id == session.activeLayerID)
    }

    @Test func describeLayerReportsAmbiguousAndMissingNames() async throws {
        let session = sessionWithDocument()
        let first = try #require(session.activeLayerID)
        session.renameLayer(first, to: "Layer 1")
        session.addBlankLayer()
        let second = try #require(session.activeLayerID)
        session.renameLayer(second, to: "Layer 1")
        let runner = EditCommandRunner(session: session)

        let ambiguous = await runner.run(.queryDescribeLayer(QueryDescribeLayer(layer: .name("Layer 1"))))
        guard case .failure(let error) = ambiguous else { Issue.record("expected ambiguity"); return }
        #expect(error.code == "ambiguous_layer_reference")

        let missing = await runner.run(.queryDescribeLayer(QueryDescribeLayer(layer: .name("Nope"))))
        guard case .failure(let error2) = missing else { Issue.record("expected not-found"); return }
        #expect(error2.code == "layer_not_found")
    }

    @Test func renderCanvasRequiresADocument() async throws {
        let session = EditorSession()
        let runner = EditCommandRunner(session: session)
        let result = await runner.run(.queryRenderCanvas(QueryRenderCanvas()))
        guard case .failure(let error) = result else { Issue.record("expected failure"); return }
        #expect(error.code == "no_document")
    }

    @Test func renderCanvasFitsWithinMaxSide() async throws {
        let session = sessionWithDocument()
        let runner = EditCommandRunner(session: session)
        let result = await runner.run(.queryRenderCanvas(QueryRenderCanvas(maxSide: 50)))
        guard case .success(.render(let render)) = result else { Issue.record("expected a render"); return }
        #expect(max(render.width, render.height) <= 50)
        #expect(!render.pngBase64.isEmpty)
    }

    @Test func historyReflectsUndoStack() async throws {
        let session = sessionWithDocument()
        let runner = EditCommandRunner(session: session)
        let before = await runner.run(.queryGetHistory)
        guard case .success(.history(let historyBefore)) = before else { Issue.record("expected history"); return }
        // `createDocument` is itself an undo step, so `canUndo` is already true here.
        #expect(historyBefore.canUndo == true)

        session.addBlankLayer()
        let after = await runner.run(.queryGetHistory)
        guard case .success(.history(let historyAfter)) = after else { Issue.record("expected history"); return }
        #expect(historyAfter.canUndo == true)
        #expect(historyAfter.undoCount == historyBefore.undoCount + 1)
        #expect(historyAfter.revision != historyBefore.revision)
    }

    @Test func getCapabilitiesListsEveryQueryCommand() async throws {
        let session = EditorSession()
        let runner = EditCommandRunner(session: session)
        let result = await runner.run(.queryGetCapabilities)
        guard case .success(.capabilities(let commands)) = result else { Issue.record("expected capabilities"); return }
        #expect(Set(commands.map(\.name)) == Set(EditCommandCatalog.commandNames))
        #expect(commands.filter { $0.name.hasPrefix("query.") }.allSatisfy { $0.mutatesDocument == false })
        #expect(commands.filter { $0.name.hasPrefix("layer.") }.allSatisfy { $0.mutatesDocument })
    }

    @Test func decodesWireFormatFromJSON() throws {
        let json = """
        { "command": "query.describeLayer", "arguments": { "layer": { "name": "Sky" }, "includeThumbnail": true } }
        """.data(using: .utf8)!
        let command = try JSONDecoder().decode(EditCommand.self, from: json)
        guard case .queryDescribeLayer(let args) = command else { Issue.record("expected queryDescribeLayer"); return }
        #expect(args.layer == .name("Sky"))
        #expect(args.includeThumbnail == true)
    }

    @Test func unknownCommandNameFailsWithAStructuredError() throws {
        let json = """
        { "command": "filter.apply", "arguments": {} }
        """.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(EditCommand.self, from: json)
            Issue.record("expected a decoding failure")
        } catch let error as EditCommandError {
            #expect(error == .unknownCommand("filter.apply"))
        }
    }

    /// `runJSON` is what the assistant tools (`CompositorToolBackend`) go through, so this is
    /// the path a model's tool call exercises — checked here without needing a live model.
    @Test func runJSONSucceedsAndFailsAsStructuredEnvelopes() async throws {
        let session = EditorSession()
        let runner = EditCommandRunner(session: session)

        let capabilities = await runner.runJSON(command: "query.getCapabilities", argumentsJSON: "{}")
        #expect(try JSONDecoder().decode(ToolEnvelopeProbe.self, from: Data(capabilities.utf8)).ok == true)

        let unknown = await runner.runJSON(command: "filter.apply", argumentsJSON: "{}")
        let unknownProbe = try JSONDecoder().decode(ToolEnvelopeProbe.self, from: Data(unknown.utf8))
        #expect(unknownProbe.ok == false)
        #expect(unknownProbe.errorCode == "unknown_command")

        let malformed = await runner.runJSON(command: "query.describeLayer", argumentsJSON: "not json")
        let malformedProbe = try JSONDecoder().decode(ToolEnvelopeProbe.self, from: Data(malformed.utf8))
        #expect(malformedProbe.ok == false)
        #expect(malformedProbe.errorCode == "invalid_arguments")

        // An empty string arguments blob (a model that skips the object) falls back to "{}".
        let noDocument = await runner.runJSON(command: "query.renderCanvas", argumentsJSON: "")
        let noDocumentProbe = try JSONDecoder().decode(ToolEnvelopeProbe.self, from: Data(noDocument.utf8))
        #expect(noDocumentProbe.ok == false)
        #expect(noDocumentProbe.errorCode == "no_document")
    }

    /// `CompositorToolBackend` decodes `query.renderCanvas` itself to pick the image path, so a
    /// wrong-typed argument must still come back as an error rather than a default render.
    @Test func decodeRejectsWrongTypedRenderArguments() {
        let decoded = EditCommandRunner.decode(command: "query.renderCanvas", argumentsJSON: "{\"maxSide\":\"512\"}")
        guard case .failure(let error) = decoded else {
            Issue.record("Expected a decode failure, got \(decoded)")
            return
        }
        #expect(error.code == "invalid_arguments")
        #expect(!error.hint.isEmpty)

        let valid = EditCommandRunner.decode(command: "query.renderCanvas", argumentsJSON: "{\"maxSide\":512}")
        guard case .success(.queryRenderCanvas(let arguments)) = valid else {
            Issue.record("Expected query.renderCanvas to decode, got \(valid)")
            return
        }
        #expect(arguments.maxSide == 512)
    }

    @Test func failureJSONEscapesMessages() throws {
        let json = EditCommandRunner.failureJSON(.renderFailed("bad \"quote\"\nand newline"))
        let probe = try JSONDecoder().decode(ToolEnvelopeProbe.self, from: Data(json.utf8))
        #expect(probe.ok == false)
        #expect(probe.errorCode == "render_failed")
    }
}

private struct ToolEnvelopeProbe: Decodable {
    var ok: Bool
    var errorCode: String?
}
