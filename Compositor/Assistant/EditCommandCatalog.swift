import Foundation

/// One command's machine-readable schema: what a model needs to call it correctly, and what a
/// person reads if a tool definition needs explaining. This is the single source both the
/// (future) Anthropic tool definitions and this file's own coverage test are generated from —
/// see `EditCommandCatalogTests`, which fails if a case in `EditCommand` has no entry here, or
/// an entry here names a command `EditCommandRunner` cannot decode.
struct CommandDescriptor: Encodable, Sendable {
    var name: String
    var summary: String
    var mutatesDocument: Bool
    /// A short, human-readable sketch of the arguments — not a JSON Schema document yet.
    var argumentsSketch: String
    var preconditions: String
}

enum EditCommandCatalog {
    static let commands: [CommandDescriptor] = [
        CommandDescriptor(
            name: "query.describeDocument",
            summary: "The full document manifest (canvas size, every layer, guides) plus session-only state: active layer, selection bounds/feather/emptiness, current tool, and undo history. No image bytes.",
            mutatesDocument: false,
            argumentsSketch: "{}",
            preconditions: "None. Returns a null manifest if no document is open."
        ),
        CommandDescriptor(
            name: "query.describeLayer",
            summary: "Metadata for one layer: visibility, opacity, blend mode, transform, group/mask/adjustment/clipping-mask presence. Optionally a thumbnail.",
            mutatesDocument: false,
            argumentsSketch: "{ layer: LayerRef, includeThumbnail?: Bool = false }",
            preconditions: "A document must be open and `layer` must resolve to exactly one layer."
        ),
        CommandDescriptor(
            name: "query.renderCanvas",
            summary: "Renders the flattened canvas (respecting visibility, opacity, blend modes, masks, and adjustments) to a PNG downscaled to fit `maxSide`, so the model can see what the document actually looks like.",
            mutatesDocument: false,
            argumentsSketch: "{ maxSide?: Int = 1024 }",
            preconditions: "A document must be open."
        ),
        CommandDescriptor(
            name: "query.getHistory",
            summary: "Undo/redo availability, the names of the next undo and redo steps, how many steps are on the undo stack, and the document's current revision id.",
            mutatesDocument: false,
            argumentsSketch: "{}",
            preconditions: "None."
        ),
        CommandDescriptor(
            name: "query.getCapabilities",
            summary: "This catalog: every command this build understands, and whether each one can change the document.",
            mutatesDocument: false,
            argumentsSketch: "{}",
            preconditions: "None."
        )
    ]

    static var commandNames: [String] { commands.map(\.name) }
}
