import Foundation
import CoreGraphics

/// The output of a successful command. One case per `EditCommand` case; encoding to JSON is
/// what a future `AssistantClient` will hand back to the model as a tool result.
enum EditCommandOutput: Encodable, Sendable {
    case document(DocumentDigest)
    case layer(LayerDigest)
    case render(CanvasRenderDigest)
    case history(HistoryDigest)
    case capabilities([CommandDescriptor])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .document(let value): try container.encode(value)
        case .layer(let value): try container.encode(value)
        case .render(let value): try container.encode(value)
        case .history(let value): try container.encode(value)
        case .capabilities(let value): try container.encode(value)
        }
    }
}

/// Executes `EditCommand`s against one session. Stage 1 only runs `query.*`: no case here
/// calls `beginEdit`/`endEdit`, so nothing it does can be undone — which is also why it needs
/// none of `EditorSession`'s busy/gating checks yet (CLAUDE.md 2.1's rule 3 and 2.5's gating
/// step apply once a mutating family lands).
@MainActor
final class EditCommandRunner {
    let session: EditorSession
    init(session: EditorSession) { self.session = session }

    func run(_ command: EditCommand) async -> Result<EditCommandOutput, EditCommandError> {
        switch command {
        case .queryDescribeDocument:
            return .success(.document(DocumentDigest(session: session)))

        case .queryDescribeLayer(let arguments):
            return resolveLayer(arguments.layer).flatMap { layer in
                do {
                    return .success(.layer(try LayerDigest(layer: layer, includeThumbnail: arguments.includeThumbnail)))
                } catch let error as EditCommandError {
                    return .failure(error)
                } catch {
                    return .failure(.renderFailed(error.localizedDescription))
                }
            }

        case .queryRenderCanvas(let arguments):
            guard let snapshot = session.projectSnapshot() else { return .failure(.noDocument) }
            do {
                let raster = try await ImageExporter.shared.render(snapshot)
                let maxSide = min(max(arguments.maxSide, 1), 4096)
                let fitted = try PNGEncoding.fitted(raster.image, maxSide: maxSide)
                let base64 = try PNGEncoding.base64(fitted)
                return .success(.render(CanvasRenderDigest(width: fitted.width, height: fitted.height, pngBase64: base64)))
            } catch let error as EditCommandError {
                return .failure(error)
            } catch {
                return .failure(.renderFailed(error.localizedDescription))
            }

        case .queryGetHistory:
            return .success(.history(HistoryDigest(session: session)))

        case .queryGetCapabilities:
            return .success(.capabilities(EditCommandCatalog.commands))
        }
    }

    /// Resolution rule shared by every command that takes a `LayerRef`: `.name` must be unique
    /// among the document's layers, since two layers may share a name and only the model's next
    /// command — carrying the resolved id this returns — can be certain which one was meant.
    private func resolveLayer(_ ref: LayerRef) -> Result<ImageLayer, EditCommandError> {
        guard let document = session.document else { return .failure(.noDocument) }
        switch ref {
        case .id(let id):
            guard let layer = document.layers.first(where: { $0.id == id }) else { return .failure(.layerNotFound(ref)) }
            return .success(layer)
        case .active:
            guard let layer = session.activeLayer else { return .failure(.layerNotFound(ref)) }
            return .success(layer)
        case .index(let index):
            guard document.layers.indices.contains(index) else { return .failure(.layerNotFound(ref)) }
            return .success(document.layers[index])
        case .name(let name):
            let matches = document.layers.filter { $0.name == name }
            if matches.count == 1 { return .success(matches[0]) }
            return .failure(matches.isEmpty ? .layerNotFound(ref) : .ambiguousLayerReference(ref, matchCount: matches.count))
        }
    }
}
