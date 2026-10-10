import Foundation

/// Which layer a command means, before it has been resolved to a UUID. The model rarely
/// knows a layer's id up front, so it names one some other way; the runner resolves this
/// against the live document and always hands back the resolved id in its result, so the
/// model's next command can be exact.
enum LayerRef: Equatable, Sendable {
    case id(UUID)
    case name(String)
    case active
    case index(Int)
}

extension LayerRef: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, active, index }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(UUID.self, forKey: .id) { self = .id(value); return }
        if let value = try container.decodeIfPresent(String.self, forKey: .name) { self = .name(value); return }
        if let value = try container.decodeIfPresent(Int.self, forKey: .index) { self = .index(value); return }
        if try container.decodeIfPresent(Bool.self, forKey: .active) == true { self = .active; return }
        throw DecodingError.dataCorruptedError(forKey: .id, in: container,
            debugDescription: "A layer reference needs one of: id, name, index, or active: true.")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .id(let value): try container.encode(value, forKey: .id)
        case .name(let value): try container.encode(value, forKey: .name)
        case .index(let value): try container.encode(value, forKey: .index)
        case .active: try container.encode(true, forKey: .active)
        }
    }
}

extension LayerRef: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case .id(let value): "layer id \(value)"
        case .name(let value): "layer named \"\(value)\""
        case .index(let value): "layer at index \(value)"
        case .active: "the active layer"
        }
    }
}

struct QueryDescribeLayer: Equatable, Sendable {
    var layer: LayerRef
    var includeThumbnail: Bool = false
}

extension QueryDescribeLayer: Codable {
    private enum CodingKeys: String, CodingKey { case layer, includeThumbnail }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layer = try container.decode(LayerRef.self, forKey: .layer)
        // Synthesized `Decodable` ignores a property's default value and requires the key
        // regardless, so a caller that omits an optional argument would fail to decode.
        includeThumbnail = try container.decodeIfPresent(Bool.self, forKey: .includeThumbnail) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layer, forKey: .layer)
        try container.encode(includeThumbnail, forKey: .includeThumbnail)
    }
}

nonisolated struct QueryRenderCanvas: Equatable, Sendable {
    var maxSide: Int = 1024
}

extension QueryRenderCanvas: Codable {
    private enum CodingKeys: String, CodingKey { case maxSide }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxSide = try container.decodeIfPresent(Int.self, forKey: .maxSide) ?? 1024
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxSide, forKey: .maxSide)
    }
}

/// A command the assistant can ask the app to run. Every case is a thin adapter over an
/// existing `EditorSession` entry point — see CLAUDE.md part 2 for why no case may reimplement
/// pixel logic, validation, or undo of its own.
///
/// Stage 1 (the current stage) only defines `query.*` cases, which read state and never call
/// `beginEdit`/`endEdit`. Later stages add `layer.*`, `selection.*`, `mask.*`, `adjustment.*`,
/// `filter.*`, and so on, following the family table in CLAUDE.md 2.4.
enum EditCommand: Sendable {
    case queryDescribeDocument
    case queryDescribeLayer(QueryDescribeLayer)
    case queryRenderCanvas(QueryRenderCanvas)
    case queryGetHistory
    case queryGetCapabilities
}

extension EditCommand: Decodable {
    private enum CodingKeys: String, CodingKey { case command, arguments }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .command)
        switch name {
        case "query.describeDocument":
            self = .queryDescribeDocument
        case "query.describeLayer":
            self = .queryDescribeLayer(try container.decode(QueryDescribeLayer.self, forKey: .arguments))
        case "query.renderCanvas":
            self = .queryRenderCanvas(try container.decodeIfPresent(QueryRenderCanvas.self, forKey: .arguments) ?? QueryRenderCanvas())
        case "query.getHistory":
            self = .queryGetHistory
        case "query.getCapabilities":
            self = .queryGetCapabilities
        default:
            throw EditCommandError.unknownCommand(name)
        }
    }
}

/// Structured so a failure can be handed straight back to the model: a code it can branch on,
/// a message a person can read in the approval panel, and (where useful) a hint toward the fix.
enum EditCommandError: Error, Equatable, Sendable {
    case unknownCommand(String)
    case invalidArguments(command: String, reason: String)
    case noDocument
    case layerNotFound(LayerRef)
    case ambiguousLayerReference(LayerRef, matchCount: Int)
    case renderFailed(String)

    var code: String {
        switch self {
        case .unknownCommand: "unknown_command"
        case .invalidArguments: "invalid_arguments"
        case .noDocument: "no_document"
        case .layerNotFound: "layer_not_found"
        case .ambiguousLayerReference: "ambiguous_layer_reference"
        case .renderFailed: "render_failed"
        }
    }

    var message: String {
        switch self {
        case .unknownCommand(let name):
            "\"\(name)\" is not a command this build understands."
        case .invalidArguments(let command, let reason):
            "\"\(command)\" was called with invalid arguments: \(reason)"
        case .noDocument:
            "No document is open."
        case .layerNotFound(let ref):
            "No layer matches \(ref)."
        case .ambiguousLayerReference(let ref, let matchCount):
            "\(matchCount) layers match \(ref); refer to it by id instead."
        case .renderFailed(let reason):
            "The canvas could not be rendered: \(reason)"
        }
    }

    /// A nudge toward the fix, shown alongside `message`. Empty when there is nothing more to say.
    var hint: String {
        switch self {
        case .unknownCommand: "Call query.getCapabilities for the list of commands this build supports."
        case .invalidArguments: "argumentsJSON must be a JSON object matching this command's schema — see query.getCapabilities."
        case .ambiguousLayerReference: "query.describeDocument lists every layer's id."
        case .layerNotFound: "query.describeDocument lists every layer's id and name."
        default: ""
        }
    }
}
