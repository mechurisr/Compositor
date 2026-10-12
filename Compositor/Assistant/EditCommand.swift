import Foundation
import CoreGraphics

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
        // The on-device model often writes a bare `"layer": "Sky"` or `"layer": 0` instead of an
        // object, and it gives up rather than retrying after a decode error — so accept those
        // unambiguous shorthands: a string is a name (or an id, if it parses as one), an integer
        // an index.
        if let single = try? decoder.singleValueContainer() {
            if let text = try? single.decode(String.self) {
                self = UUID(uuidString: text).map(LayerRef.id) ?? .name(text)
                return
            }
            if let index = try? single.decode(Int.self) {
                self = .index(index)
                return
            }
        }
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

struct LayerAdd: Codable, Equatable, Sendable {
    /// Optional so a later command in the same proposal can refer to the new layer by name —
    /// proposals run only after approval, so the model never sees the new layer's id.
    var name: String?
}

struct LayerRename: Codable, Equatable, Sendable {
    var layer: LayerRef
    var name: String
}

struct LayerSetVisibility: Codable, Equatable, Sendable {
    var layer: LayerRef
    var visible: Bool
}

struct LayerSetOpacity: Codable, Equatable, Sendable {
    var layer: LayerRef
    /// 0–1, as stored. Values outside that range are rejected rather than clamped, so a model
    /// that sends 60 for 60% is told so instead of silently getting 100%.
    var opacity: Double
}

struct LayerSetBlendMode: Codable, Equatable, Sendable {
    var layer: LayerRef
    /// A `LayerBlendMode` raw value such as "Multiply"; matched case-insensitively.
    var blendMode: String
}

struct LayerDelete: Codable, Equatable, Sendable {
    var layer: LayerRef
}

/// A rectangle or ellipse in document pixels (top-left origin, y down), combined with the current
/// selection the way the marquee tool does.
struct SelectionShape: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case replace, add, subtract }
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var mode: Mode = .replace

    private enum CodingKeys: String, CodingKey { case x, y, width, height, mode }

    init(x: Double, y: Double, width: Double, height: Double, mode: Mode = .replace) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.mode = mode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .replace
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Pixels for Expand / Contract / Feather.
struct SelectionAmount: Codable, Equatable, Sendable {
    var amount: Int
}

/// A plain mask: all white (everything shows) or all black (everything hidden).
struct MaskAdd: Codable, Equatable, Sendable {
    var layer: LayerRef
    var reveal: Bool
}

/// A mask made from the selection, which it uses up (deselects) in the same step.
struct MaskFromSelection: Codable, Equatable, Sendable {
    /// What stays visible: the selected area, or everything outside it. Named by the result rather
    /// than by mask color, since this app's own default (`addMask(revealing: true)`, the Layers
    /// panel's button) *hides* the selection — the opposite of Photoshop.
    enum Shows: String, Codable, Sendable { case selection, outside }
    var layer: LayerRef
    var shows: Shows
}

struct MaskSetEnabled: Codable, Equatable, Sendable {
    var layer: LayerRef
    var enabled: Bool
}

/// The layer a mask command acts on.
struct MaskTarget: Codable, Equatable, Sendable {
    var layer: LayerRef
}

/// A command the assistant can ask the app to run. Every case is a thin adapter over an
/// existing `EditorSession` entry point — see CLAUDE.md part 2 for why no case may reimplement
/// pixel logic, validation, or undo of its own.
///
/// `query.*` cases read state and never call `beginEdit`/`endEdit`. Stage 2's `layer.*` cases
/// change the document; the assistant never runs them directly but queues them as a proposal
/// the person approves (CLAUDE.md 2.8), which `EditCommandRunner.applyBatch` then runs as one
/// undo step.
enum EditCommand: Equatable, Sendable {
    case queryDescribeDocument
    case queryDescribeLayer(QueryDescribeLayer)
    case queryRenderCanvas(QueryRenderCanvas)
    case queryGetHistory
    case queryGetCapabilities
    case layerAdd(LayerAdd)
    case layerRename(LayerRename)
    case layerSetVisibility(LayerSetVisibility)
    case layerSetOpacity(LayerSetOpacity)
    case layerSetBlendMode(LayerSetBlendMode)
    case layerDelete(LayerDelete)
    case selectionAll
    case selectionDeselect
    case selectionInvert
    case selectionRect(SelectionShape)
    case selectionEllipse(SelectionShape)
    case selectionExpand(SelectionAmount)
    case selectionContract(SelectionAmount)
    case selectionFeather(SelectionAmount)
    case maskAdd(MaskAdd)
    case maskAddFromSelection(MaskFromSelection)
    case maskSetEnabled(MaskSetEnabled)
    case maskDelete(MaskTarget)
    case maskClipToBelow(MaskTarget)
    case maskReleaseClipping(MaskTarget)

    /// Whether running this changes the document — and so must go through approval. The
    /// selection lives in the document (it is undoable), so selection commands count.
    var mutatesDocument: Bool {
        switch self {
        case .queryDescribeDocument, .queryDescribeLayer, .queryRenderCanvas, .queryGetHistory, .queryGetCapabilities:
            false
        default:
            true
        }
    }

    /// Needs a selection to work on (Select → Modify, Inverse).
    var needsSelection: Bool {
        switch self {
        case .selectionInvert, .selectionExpand, .selectionContract, .selectionFeather, .maskAddFromSelection: true
        default: false
        }
    }

    /// Leaves a selection behind, so a later `needsSelection` edit in the same proposal has one.
    var createsSelection: Bool {
        switch self {
        case .selectionAll, .selectionRect, .selectionEllipse: true
        default: false
        }
    }

    /// The layer this command targets, if any.
    var layerRef: LayerRef? {
        switch self {
        case .queryDescribeLayer(let a): a.layer
        case .layerRename(let a): a.layer
        case .layerSetVisibility(let a): a.layer
        case .layerSetOpacity(let a): a.layer
        case .layerSetBlendMode(let a): a.layer
        case .layerDelete(let a): a.layer
        case .maskAdd(let a): a.layer
        case .maskAddFromSelection(let a): a.layer
        case .maskSetEnabled(let a): a.layer
        case .maskDelete(let a), .maskClipToBelow(let a), .maskReleaseClipping(let a): a.layer
        default: nil
        }
    }
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
        case "layer.add":
            self = .layerAdd(try container.decodeIfPresent(LayerAdd.self, forKey: .arguments) ?? LayerAdd())
        case "layer.rename":
            self = .layerRename(try container.decode(LayerRename.self, forKey: .arguments))
        case "layer.setVisibility":
            self = .layerSetVisibility(try container.decode(LayerSetVisibility.self, forKey: .arguments))
        case "layer.setOpacity":
            self = .layerSetOpacity(try container.decode(LayerSetOpacity.self, forKey: .arguments))
        case "layer.setBlendMode":
            self = .layerSetBlendMode(try container.decode(LayerSetBlendMode.self, forKey: .arguments))
        case "layer.delete":
            self = .layerDelete(try container.decode(LayerDelete.self, forKey: .arguments))
        case "selection.all":
            self = .selectionAll
        case "selection.deselect":
            self = .selectionDeselect
        case "selection.invert":
            self = .selectionInvert
        case "selection.rect":
            self = .selectionRect(try container.decode(SelectionShape.self, forKey: .arguments))
        case "selection.ellipse":
            self = .selectionEllipse(try container.decode(SelectionShape.self, forKey: .arguments))
        case "selection.expand":
            self = .selectionExpand(try container.decode(SelectionAmount.self, forKey: .arguments))
        case "selection.contract":
            self = .selectionContract(try container.decode(SelectionAmount.self, forKey: .arguments))
        case "selection.feather":
            self = .selectionFeather(try container.decode(SelectionAmount.self, forKey: .arguments))
        case "mask.add":
            self = .maskAdd(try container.decode(MaskAdd.self, forKey: .arguments))
        case "mask.addFromSelection":
            self = .maskAddFromSelection(try container.decode(MaskFromSelection.self, forKey: .arguments))
        case "mask.setEnabled":
            self = .maskSetEnabled(try container.decode(MaskSetEnabled.self, forKey: .arguments))
        case "mask.delete":
            self = .maskDelete(try container.decode(MaskTarget.self, forKey: .arguments))
        case "mask.clipToBelow":
            self = .maskClipToBelow(try container.decode(MaskTarget.self, forKey: .arguments))
        case "mask.releaseClipping":
            self = .maskReleaseClipping(try container.decode(MaskTarget.self, forKey: .arguments))
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
    /// The person has something open that the matching menu item would also wait for.
    case busy(String)
    /// Valid, but something the assistant isn't allowed to do on its own (it would need a choice
    /// only the person can make).
    case notSupported(String)
    /// The session method ran but the document didn't change, e.g. its own guard refused.
    case notApplied(String)

    var code: String {
        switch self {
        case .unknownCommand: "unknown_command"
        case .invalidArguments: "invalid_arguments"
        case .noDocument: "no_document"
        case .layerNotFound: "layer_not_found"
        case .ambiguousLayerReference: "ambiguous_layer_reference"
        case .renderFailed: "render_failed"
        case .busy: "busy"
        case .notSupported: "not_supported"
        case .notApplied: "not_applied"
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
        case .busy(let blocker):
            "The document can't be edited right now: \(blocker)."
        case .notSupported(let reason):
            reason
        case .notApplied(let what):
            "\(what) did not change the document."
        }
    }

    /// A nudge toward the fix, shown alongside `message`. Empty when there is nothing more to say.
    var hint: String {
        switch self {
        case .unknownCommand: "Call query.getCapabilities for the list of commands this build supports."
        case .invalidArguments: "argumentsJSON must be a JSON object matching this command's schema — see query.getCapabilities."
        case .ambiguousLayerReference: "query.describeDocument lists every layer's id."
        case .layerNotFound: "query.describeDocument lists every layer's id and name."
        case .busy: "Wait for the person to finish, then try again."
        default: ""
        }
    }
}
