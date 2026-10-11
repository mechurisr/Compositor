import Foundation
import CoreGraphics

/// The output of a successful command. One case per `EditCommand` case; `runJSON` is what
/// hands this back to a model as a tool result, JSON-encoded.
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
/// `@unchecked` because `session` (an `EditorSession`) isn't itself `Sendable` — but every
/// access to it happens on `MainActor`, which is exactly what makes a reference to this class
/// safe to hand to a model tool that may be invoked from any executor (`Tool: Sendable`).
@MainActor
final class EditCommandRunner: @unchecked Sendable {
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
            do {
                let fitted = try await renderCanvas(arguments)
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

        default:
            // Edits never run one at a time from here: they are proposed (`propose`) and, once the
            // person approves, run together as one undo step (`applyBatch`).
            return .failure(.notSupported("\(command.name) changes the document, so it must be proposed and approved."))
        }
    }

    /// Shared by `run(_:)` and `renderCanvasImage(_:)`, which need the same render at two
    /// different endpoints: one base64-encodes it for the plain-JSON result contract, the other
    /// hands the `CGImage` itself to a caller that can attach it as real multimodal input.
    private func renderCanvas(_ arguments: QueryRenderCanvas) async throws -> CGImage {
        guard let snapshot = session.projectSnapshot() else { throw EditCommandError.noDocument }
        let raster = try await ImageExporter.shared.render(snapshot)
        let maxSide = min(max(arguments.maxSide, 1), 4096)
        return try PNGEncoding.fitted(raster.image, maxSide: maxSide)
    }

    /// For a caller (the assistant's tool) that can give the model a real image rather than
    /// inert base64 text it has no way to actually see.
    func renderCanvasImage(_ arguments: QueryRenderCanvas) async -> Result<CGImage, EditCommandError> {
        do {
            return .success(try await renderCanvas(arguments))
        } catch let error as EditCommandError {
            return .failure(error)
        } catch {
            return .failure(.renderFailed(error.localizedDescription))
        }
    }

    /// Resolution rule shared by every command that takes a `LayerRef`: `.name` must be unique
    /// among the document's layers, since two layers may share a name and only the model's next
    /// command — carrying the resolved id this returns — can be certain which one was meant.
    func resolveLayer(_ ref: LayerRef) -> Result<ImageLayer, EditCommandError> {
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

private struct ToolResultEnvelope: Encodable {
    var ok: Bool
    var output: EditCommandOutput?
    var errorCode: String?
    var errorMessage: String?
    var errorHint: String?
}

extension EditCommandRunner {
    /// String-in, string-out adapter for callers that only have a command name and a JSON
    /// arguments blob — a model's tool call, in particular — rather than an `EditCommand` already
    /// decoded. Deliberately framework-agnostic (no `FoundationModels` import) so it can be unit
    /// tested without an on-device model, and reused if a different model backend is added later.
    ///
    /// Never throws: any failure (malformed JSON, an unknown command, a command-level error) comes
    /// back as `{"ok": false, ...}` so the caller can read and react to it, per CLAUDE.md 2.5's
    /// result contract.
    func runJSON(command name: String, argumentsJSON: String) async -> String {
        switch Self.decode(command: name, argumentsJSON: argumentsJSON) {
        case .failure(let error):
            return Self.failureJSON(error)
        case .success(let command):
            switch await run(command) {
            case .success(let output):
                return Self.encode(ToolResultEnvelope(ok: true, output: output))
            case .failure(let error):
                return Self.failureJSON(error)
            }
        }
    }

    /// The one place a command name plus a JSON arguments blob becomes an `EditCommand`, so a
    /// caller that needs to special-case a command (the assistant's tool attaching a real image
    /// for `query.renderCanvas`) decodes and reports errors exactly as `runJSON` does.
    static func decode(command name: String, argumentsJSON: String) -> Result<EditCommand, EditCommandError> {
        let arguments = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandJSON = "{\"command\":\(jsonString(name)),\"arguments\":\(arguments.isEmpty ? "{}" : arguments)}"
        do {
            return .success(try JSONDecoder().decode(EditCommand.self, from: Data(commandJSON.utf8)))
        } catch let error as EditCommandError {
            return .failure(error)
        } catch {
            return .failure(.invalidArguments(command: name, reason: "they did not decode: \(error.localizedDescription)"))
        }
    }

    /// The `{"ok": false, ...}` envelope for `error`, JSON-escaped properly.
    static func failureJSON(_ error: EditCommandError) -> String {
        encode(ToolResultEnvelope(ok: false, errorCode: error.code, errorMessage: error.message, errorHint: error.hint))
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    private static func encode(_ envelope: ToolResultEnvelope) -> String {
        guard let data = try? JSONEncoder().encode(envelope), let text = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"errorCode\":\"encode_failed\",\"errorMessage\":\"Could not encode the result.\"}"
        }
        return text
    }
}
