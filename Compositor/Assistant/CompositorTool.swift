import FoundationModels

/// The single tool the assistant's model calls to read or edit the open document. One generic
/// tool rather than one per `EditCommand` case: Apple's guidance caps a request at three to five
/// tools before they eat too much of the context window, and Stage 1 alone already has five
/// `query.*` commands with more families to come (CLAUDE.md 2.4). `command`/`argumentsJSON`
/// mirror the wire format `EditCommand` already decodes, so this stays a thin adapter over
/// `EditCommandRunner.runJSON` rather than a second command surface.
struct CompositorTool: Tool {
    let runner: EditCommandRunner

    let name = "compositorCommand"
    let description = """
        Reads or edits the open Compositor document. Call with `command`, a dotted name such as \
        "query.describeDocument", and `argumentsJSON`, that command's JSON arguments as a string \
        (use "{}" for none). Call "query.getCapabilities" first if you don't already know what's \
        available.
        """

    @Generable
    struct Arguments {
        @Guide(description: "A command name from query.getCapabilities, e.g. \"query.describeDocument\".")
        var command: String
        @Guide(description: "The command's JSON arguments as a string, e.g. \"{}\" or \"{\\\"layer\\\":{\\\"active\\\":true}}\".")
        var argumentsJSON: String
    }

    func call(arguments: Arguments) async throws -> String {
        await runner.runJSON(command: arguments.command, argumentsJSON: arguments.argumentsJSON)
    }
}
