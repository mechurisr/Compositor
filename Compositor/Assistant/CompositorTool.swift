import FoundationModels
import Foundation
import CoreGraphics

/// The tools the assistant's model calls: `InspectDocumentTool` reads; `EditLayerTool`,
/// `EditSelectionTool`, and `EditMaskTool` propose edits, one tool per command family. All take typed `@Generable` arguments rather than a JSON string. Measured on the
/// on-device model: with one generic tool taking `command` + `argumentsJSON`, it got a Korean edit
/// request into a valid proposal only 3 times in 10 — the nested JSON string came back cut off at
/// "{", and it invented command names like "query.layer.setOpacity". Guided generation fills typed
/// fields and enum cases reliably, and an enum leaves nothing to invent.
///
/// The typed arguments are turned back into the `EditCommand` wire format and go through
/// `CompositorToolBackend`, so decoding, validation, and errors still have exactly one path
/// (`EditCommandRunner.decode`). A tool per family, not per command, keeps within Apple's
/// three-to-five tools guidance as families are added (CLAUDE.md 2.4).
struct CompositorToolBackend: Sendable {
    let runner: EditCommandRunner
    let mailbox: CanvasImageMailbox
    let proposals: ProposalCollector

    /// Runs a query, or proposes an edit, given in the wire format.
    ///
    /// `query.renderCanvas` is special: base64 pixels in a JSON string are inert text the model
    /// cannot see, and an image `Attachment` in a tool's output is ignored too (see
    /// `CanvasImageMailbox`). So when the model supports vision, the render is left in `mailbox`
    /// for `AssistantSession` to attach to a follow-up prompt.
    func handle(command name: String, arguments: [String: Any] = [:]) async -> String {
        let argumentsJSON = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return await handle(command: name, argumentsJSON: argumentsJSON)
    }

    func handle(command name: String, argumentsJSON: String) async -> String {
        let decoded = await EditCommandRunner.decode(command: name, argumentsJSON: argumentsJSON)
        if case .success(let command) = decoded, command.mutatesDocument {
            return await propose(command)
        }
        guard case .success(.queryRenderCanvas(let renderArguments)) = decoded else {
            return await runner.runJSON(command: name, argumentsJSON: argumentsJSON)
        }
        switch await runner.renderCanvasImage(renderArguments) {
        case .success(let image):
            // Attaching an image to a model without vision makes the framework throw
            // `unsupportedCapability` and fail the whole turn, so only hand it over when it can see.
            guard Self.modelCanSee else {
                return Self.dimensionsJSON(image, note: "This model cannot view images; only the rendered size is available.")
            }
            await mailbox.deposit(image)
            return Self.dimensionsJSON(image, note: "The rendered image will be attached to the next message. "
                + "Do not guess what it shows; reply only that you are looking at the canvas.")
        case .failure(let error):
            return await EditCommandRunner.failureJSON(error)
        }
    }

    /// Edits never run from a tool call: they are checked and queued in `proposals`, and
    /// `AssistantSession` shows them for approval once the turn ends (CLAUDE.md 2.8).
    @MainActor
    private func propose(_ command: EditCommand) -> String {
        switch runner.propose(command, pendingNames: proposals.pendingNames, selectionPending: proposals.selectionPending) {
        case .success(var edit):
            // Still proposed — the person decides, and can fix the name in the card's field — but
            // flagged. The model is told too, though in measurement it never called again to
            // correct itself (0 of 6).
            if let name = proposals.unrequestedName(in: command) {
                edit.warning = "요청에 없던 이름입니다: '\(name)'. 이름 칸에서 고친 뒤 적용하세요."
                proposals.append(edit)
                return "{\"ok\":true,\"status\":\"proposed\",\"warning\":\"The name '\(name)' does not appear in the "
                    + "person's message. If they asked for a different name, call editLayer again now with the name "
                    + "copied exactly from their message, untranslated.\"}"
            }
            proposals.append(edit)
            return "{\"ok\":true,\"status\":\"proposed\",\"note\":\"Queued for the person's approval; it runs only "
                + "when they press Apply. Propose any other edits now, then tell the person in one short sentence "
                + "what you proposed.\"}"
        case .failure(let error):
            return EditCommandRunner.failureJSON(error)
        }
    }

    /// For tools that turn a described region into coordinates themselves.
    @MainActor
    func canvasSize() -> CGSize? { runner.session.document?.size }

    static var modelCanSee: Bool {
        if #available(macOS 27.0, *) { return SystemLanguageModel.default.capabilities.contains(.vision) }
        return false
    }

    private static func dimensionsJSON(_ image: CGImage, note: String) -> String {
        "{\"ok\":true,\"width\":\(image.width),\"height\":\(image.height),\"note\":\"\(note)\"}"
    }
}

struct InspectDocumentTool: Tool {
    let backend: CompositorToolBackend

    let name = "inspectDocument"
    let description = "Reads the open document. renderCanvas shows what the canvas looks like (the image arrives in the next message)."

    // No describeLayer: describeDocument already lists every layer, and the model called
    // describeLayer without a layer name, got "not found", and concluded the layer didn't exist.
    @Generable
    enum Query: String, CaseIterable {
        case describeDocument, renderCanvas, getHistory
    }

    @Generable
    struct Arguments {
        @Guide(description: "describeDocument: size, every layer, selection. renderCanvas: see the canvas. getHistory: undo history.")
        var query: Query
    }

    func call(arguments: Arguments) async throws -> String {
        await backend.handle(command: "query.\(arguments.query.rawValue)")
    }
}

struct EditLayerTool: Tool {
    let backend: CompositorToolBackend

    let name = "editLayer"
    let description = "Proposes a change to a layer. Nothing changes until the person presses Apply."

    // `show`/`hide` rather than one visibility action with a Bool: given a generic command name,
    // the model once proposed `layer.delete` for "숨겨줘" (hide it).
    @Generable
    enum Action: String, CaseIterable {
        case add, rename, show, hide, setOpacity, setBlendMode, delete
    }

    /// One `value` string for every action rather than a typed field per action. Measured: given
    /// separate optional `name` / `opacity` / `blendMode` fields (even a blend-mode enum), the model
    /// never filled `blendMode` and wrote the mode into the name field instead ("Layer 1 - Multiply"),
    /// failing every blend-mode request. It reliably puts the value in one string field.
    @Generable
    struct Arguments {
        var action: Action
        @Guide(description: "Name of the layer to change. Omit for add.")
        var layer: String?
        @Guide(description: "rename/add: the new name, exactly as the person wrote it. setOpacity: percent, e.g. 50. setBlendMode: a mode name, e.g. Multiply.")
        var value: String?
    }

    func call(arguments: Arguments) async throws -> String {
        var json: [String: Any] = [:]
        if let layer = arguments.layer { json["layer"] = layer }
        let value = arguments.value.map(EditCommand.trimmed)
        let command: String
        switch arguments.action {
        case .add:
            command = "layer.add"
            json = [:]
            if let value, !value.isEmpty { json["name"] = value }
        case .rename:
            command = "layer.rename"
            if let value { json["name"] = value }
        case .show, .hide:
            command = "layer.setVisibility"
            json["visible"] = arguments.action == .show
        case .setOpacity:
            command = "layer.setOpacity"
            // Left out when unparseable, so the runner reports the missing argument.
            if let opacity = value.flatMap(Self.opacity(from:)) { json["opacity"] = opacity }
        case .setBlendMode:
            command = "layer.setBlendMode"
            if let value { json["blendMode"] = value }
        case .delete:
            command = "layer.delete"
        }
        return await backend.handle(command: command, arguments: json)
    }

    /// The tool speaks percent ("50", "50%"); the document stores 0–1. A bare decimal no greater
    /// than 1 ("0.5") is taken as already a fraction. Out-of-range results pass through for the
    /// runner to reject rather than being clamped here.
    static func opacity(from text: String) -> Double? {
        let isPercent = text.hasSuffix("%")
        guard let number = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: "% "))), number.isFinite else { return nil }
        if !isPercent, text.contains("."), number <= 1 { return number }
        return number / 100
    }
}

struct EditSelectionTool: Tool {
    let backend: CompositorToolBackend

    let name = "editSelection"
    let description = "Proposes a change to the selection. Nothing changes until the person presses Apply."

    /// Adding is an action of its own rather than a `mode` field, and subtracting isn't offered.
    /// Measured: with an optional mode the model set "subtract" on plain "select the bottom half"
    /// requests (2 of 15); with a subtractRectangle action it still chose it for "아래쪽 절반"
    /// (bottom half) 2 of 3 times. Subtracting is rare and gets the opposite of what was asked, so
    /// the runner supports it (`selection.rect` mode "subtract") but the model isn't given it.
    @Generable
    enum Action: String, CaseIterable {
        case selectAll, deselect, invert
        case rectangle, ellipse, addRectangle, addEllipse
        case expand, contract, feather
    }

    /// Where a rectangle or ellipse goes, worked out here from the canvas size. Measured: asked for
    /// "a 100×100 square in the middle" of a 400×200 canvas, the model placed it at (100, 100),
    /// (200, 100), and (50, 100) — never the center (150, 50) — and for "the left half" it often
    /// left the width out. Naming the region and doing the arithmetic in code avoids both.
    @Generable
    enum Region: String, CaseIterable {
        case topHalf, bottomHalf, leftHalf, rightHalf, center, custom
    }

    @Generable
    struct Arguments {
        @Guide(description: "rectangle: a box shape. ellipse: an oval or circle shape. Plain rectangle/ellipse replace the selection; addRectangle/addEllipse keep it and add the shape.")
        var action: Action
        @Guide(description: "For a shape: topHalf (upper half), bottomHalf (lower half), leftHalf, rightHalf; center with width and height; or custom with x, y, width, height.")
        var region: Region?
        @Guide(description: "custom: left edge in document pixels from the top-left corner.")
        var x: Double?
        @Guide(description: "custom: top edge, pixels down from the top.")
        var y: Double?
        @Guide(description: "custom or center: width in pixels.")
        var width: Double?
        @Guide(description: "custom or center: height in pixels.")
        var height: Double?
        @Guide(description: "expand/contract/feather only: pixels.")
        var amount: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        var json: [String: Any] = [:]
        let command: String
        switch arguments.action {
        case .selectAll: command = "selection.all"
        case .deselect: command = "selection.deselect"
        case .invert: command = "selection.invert"
        case .rectangle, .ellipse, .addRectangle, .addEllipse:
            let ellipse = [.ellipse, .addEllipse].contains(arguments.action)
            command = ellipse ? "selection.ellipse" : "selection.rect"
            let frame = Self.frame(for: arguments, canvas: await backend.canvasSize())
            json["x"] = frame.x; json["y"] = frame.y
            json["width"] = frame.width; json["height"] = frame.height
            json["mode"] = [.addRectangle, .addEllipse].contains(arguments.action) ? "add" : "replace"
        case .expand: command = "selection.expand"; json["amount"] = arguments.amount
        case .contract: command = "selection.contract"; json["amount"] = arguments.amount
        case .feather: command = "selection.feather"; json["amount"] = arguments.amount
        }
        return await backend.handle(command: command, arguments: json.compactMapValues { $0 })
    }

    /// The shape's frame. Missing values stay missing, so the runner reports them rather than a
    /// guess being proposed; with no canvas, only custom coordinates can be used.
    static func frame(for arguments: Arguments, canvas: CGSize?) -> (x: Double?, y: Double?, width: Double?, height: Double?) {
        let region = arguments.region ?? (arguments.x == nil && arguments.y == nil && arguments.width != nil ? .center : .custom)
        guard region != .custom, let canvas else { return (arguments.x, arguments.y, arguments.width, arguments.height) }
        let w = Double(canvas.width), h = Double(canvas.height)
        switch region {
        case .leftHalf: return (0, 0, w / 2, h)
        case .rightHalf: return (w / 2, 0, w / 2, h)
        case .topHalf: return (0, 0, w, h / 2)
        case .bottomHalf: return (0, h / 2, w, h / 2)
        case .center:
            // One side given means a square: asked for "100x100 in the middle", the model often
            // sent the width alone. The card shows the size, so a wrong guess is visible.
            guard let width = arguments.width ?? arguments.height, let height = arguments.height ?? arguments.width else {
                return (nil, nil, nil, nil)
            }
            return ((w - width) / 2, (h - height) / 2, width, height)
        case .custom: return (arguments.x, arguments.y, arguments.width, arguments.height)
        }
    }
}

struct EditMaskTool: Tool {
    let backend: CompositorToolBackend

    let name = "editMask"
    let description = "Proposes a layer mask or clipping-mask change. Nothing changes until the person presses Apply."

    /// Named by what ends up visible, not by mask color: this app's own Add Mask with a selection
    /// *hides* the selection (unlike Photoshop), so "white"/"black" would mislead. And never "hide":
    /// with an addHideAll action, "Photo 숨겨줘" (hide Photo) got a hide-all mask instead of
    /// editLayer's hide.
    @Generable
    enum Action: String, CaseIterable {
        case addMaskShowingAll, addMaskShowingNothing, addMaskShowingOnlySelection, addMaskShowingAllButSelection
        case enableMask, disableMask, deleteMask
        case clipToLayerBelow, releaseClipping
    }

    @Generable
    struct Arguments {
        @Guide(description: "addMaskShowingAll: white mask. addMaskShowingNothing: black mask, the layer is fully masked out. addMaskShowingOnlySelection / addMaskShowingAllButSelection: built from the selection. disableMask: turn the mask off but keep it. deleteMask: remove the mask entirely. clipToLayerBelow: clipping mask onto the layer below.")
        var action: Action
        @Guide(description: "Name of the layer.")
        var layer: String
    }

    func call(arguments: Arguments) async throws -> String {
        var json: [String: Any] = ["layer": arguments.layer]
        let command: String
        switch arguments.action {
        case .addMaskShowingAll: command = "mask.add"; json["reveal"] = true
        case .addMaskShowingNothing: command = "mask.add"; json["reveal"] = false
        case .addMaskShowingOnlySelection: command = "mask.addFromSelection"; json["shows"] = "selection"
        case .addMaskShowingAllButSelection: command = "mask.addFromSelection"; json["shows"] = "outside"
        case .enableMask: command = "mask.setEnabled"; json["enabled"] = true
        case .disableMask: command = "mask.setEnabled"; json["enabled"] = false
        case .deleteMask: command = "mask.delete"
        case .clipToLayerBelow: command = "mask.clipToBelow"
        case .releaseClipping: command = "mask.releaseClipping"
        }
        return await backend.handle(command: command, arguments: json)
    }
}

/// Carries a rendered canvas from the tools to `AssistantSession`. Images in a tool's output never
/// reach the on-device model — measured: with a solid blue/green/yellow canvas returned as an
/// `Attachment` from the tool, it answered "red" every time, while the same image attached
/// directly to a prompt was named correctly. So the tool only parks the image here, and the
/// session re-asks with the image attached to a prompt of its own.
@MainActor
final class CanvasImageMailbox {
    private var pending: CGImage?

    func deposit(_ image: CGImage) { pending = image }

    func take() -> CGImage? {
        defer { pending = nil }
        return pending
    }
}

/// Edits the model proposed during the current turn, in order. `AssistantSession` takes them when
/// the turn ends and shows them for approval.
@MainActor
final class ProposalCollector {
    private(set) var edits: [ProposedEdit] = []
    /// The person's message this turn, to check names the model writes against what they typed.
    var request = ""

    /// Names layers will have once the queued edits run, so a later edit can target them by name.
    var pendingNames: Set<String> { Set(edits.compactMap(\.command.createdLayerName)) }
    /// Whether a queued edit leaves a selection, for Expand / Contract / Feather / Inverse after it.
    var selectionPending: Bool { edits.contains { $0.command.createsSelection } }

    /// Queues `edit`, replacing an earlier edit that sets the same value on the same layer.
    func append(_ edit: ProposedEdit) {
        if let key = edit.command.supersedingKey, let index = edits.firstIndex(where: { $0.command.supersedingKey == key }) {
            edits[index] = edit
        } else {
            edits.append(edit)
        }
    }

    /// A name the model wrote that isn't in the person's message. Measured: asked (in Korean) to
    /// rename a layer to "배경" or "하늘", the model wrote "Background", "hallo", or "hail" — while a
    /// quoted name ('인물') came through intact every time. Instructions didn't fix it.
    func unrequestedName(in command: EditCommand) -> String? {
        guard let name = command.createdLayerName, !request.isEmpty,
              request.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) == nil else { return nil }
        return name
    }

    func takeAll() -> [ProposedEdit] {
        defer { edits = [] }
        return edits
    }
}
