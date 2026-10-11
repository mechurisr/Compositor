import FoundationModels
import Foundation
import CoreGraphics

/// The two tools the assistant's model calls: `InspectDocumentTool` reads, `EditLayerTool` proposes
/// edits. Both take typed `@Generable` arguments rather than a JSON string. Measured on the
/// on-device model: with one generic tool taking `command` + `argumentsJSON`, it got a Korean edit
/// request into a valid proposal only 3 times in 10 — the nested JSON string came back cut off at
/// "{", and it invented command names like "query.layer.setOpacity". Guided generation fills typed
/// fields and enum cases reliably, and an enum leaves nothing to invent.
///
/// The typed arguments are turned back into the `EditCommand` wire format and go through
/// `CompositorToolBackend`, so decoding, validation, and errors still have exactly one path
/// (`EditCommandRunner.decode`). Two tools, not one per command, keeps within Apple's three-to-five
/// tools guidance as command families are added (CLAUDE.md 2.4).
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
        switch runner.propose(command, pendingNames: proposals.pendingNames) {
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
