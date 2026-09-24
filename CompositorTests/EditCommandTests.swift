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
        #expect(commands.allSatisfy { $0.mutatesDocument == false })
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
        { "command": "layer.setOpacity", "arguments": {} }
        """.data(using: .utf8)!
        do {
            _ = try JSONDecoder().decode(EditCommand.self, from: json)
            Issue.record("expected a decoding failure")
        } catch let error as EditCommandError {
            #expect(error == .unknownCommand("layer.setOpacity"))
        }
    }
}
