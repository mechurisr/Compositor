import FoundationModels
import Foundation
import CoreGraphics

/// The single tool the assistant's model calls to read or edit the open document. One generic
/// tool rather than one per `EditCommand` case: Apple's guidance caps a request at three to five
/// tools before they eat too much of the context window, and Stage 1 alone already has five
/// `query.*` commands with more families to come (CLAUDE.md 2.4). `command`/`argumentsJSON`
/// mirror the wire format `EditCommand` already decodes, so this stays a thin adapter over
/// `EditCommandRunner` rather than a second command surface.
///
/// `query.renderCanvas` is the one special case: base64 pixels in a JSON string are inert text
/// the model cannot see, and an image `Attachment` in a tool's output is ignored too (see
/// `CanvasImageMailbox`). So when the model supports vision, that command renders through
/// `EditCommandRunner.renderCanvasImage(_:)` and leaves the image in `mailbox` for
/// `AssistantSession` to attach to a follow-up prompt.
struct CompositorTool: Tool {
    let runner: EditCommandRunner
    let mailbox: CanvasImageMailbox

    let name = "compositorCommand"
    let description = """
        Reads or edits the open Compositor document. Call with `command`, a dotted name such as \
        "query.describeDocument", and `argumentsJSON`, that command's JSON arguments as a string \
        (use "{}" for none). Call "query.getCapabilities" first if you don't already know what's \
        available. Use "query.renderCanvas" whenever you need to see what the canvas looks like; \
        the image arrives in the next message.
        """

    @Generable
    struct Arguments {
        @Guide(description: "A command name from query.getCapabilities, e.g. \"query.describeDocument\".")
        var command: String
        @Guide(description: "The command's JSON arguments as a string, e.g. \"{}\" or \"{\\\"layer\\\":{\\\"active\\\":true}}\".")
        var argumentsJSON: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Decoding goes through the runner either way, so a malformed `query.renderCanvas` call
        // gets the same structured `invalid_arguments` error as any other command instead of
        // silently rendering with defaults.
        let decoded = await EditCommandRunner.decode(command: arguments.command, argumentsJSON: arguments.argumentsJSON)
        guard case .success(.queryRenderCanvas(let renderArguments)) = decoded else {
            return await runner.runJSON(command: arguments.command, argumentsJSON: arguments.argumentsJSON)
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

    static var modelCanSee: Bool {
        if #available(macOS 27.0, *) { return SystemLanguageModel.default.capabilities.contains(.vision) }
        return false
    }

    private static func dimensionsJSON(_ image: CGImage, note: String) -> String {
        "{\"ok\":true,\"width\":\(image.width),\"height\":\(image.height),\"note\":\"\(note)\"}"
    }
}

/// Carries a rendered canvas from `CompositorTool` to `AssistantSession`. Images in a tool's
/// output never reach the on-device model — measured: with a solid blue/green/yellow canvas
/// returned as an `Attachment` from the tool, it answered "red" every time, while the same image
/// attached directly to a prompt was named correctly. So the tool only parks the image here, and
/// the session re-asks with the image attached to a prompt of its own.
@MainActor
final class CanvasImageMailbox {
    private var pending: CGImage?

    func deposit(_ image: CGImage) { pending = image }

    func take() -> CGImage? {
        defer { pending = nil }
        return pending
    }
}
