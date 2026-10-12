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
        ),
        // Edits are proposed, not run: the person approves them, and they apply as one undo step.
        CommandDescriptor(
            name: "layer.add",
            summary: "Adds an empty layer above the active one (inside the active folder). Give it a name to refer to it in later edits of the same proposal.",
            mutatesDocument: true,
            argumentsSketch: "{ name?: String }",
            preconditions: "A document must be open. Proposed for approval; runs only when the person presses Apply."
        ),
        CommandDescriptor(
            name: "layer.rename",
            summary: "Renames a layer or folder.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, name: String }",
            preconditions: "`layer` must resolve to one layer; `name` must not be empty. Proposed for approval."
        ),
        CommandDescriptor(
            name: "layer.setVisibility",
            summary: "Shows or hides a layer or folder.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, visible: Bool }",
            preconditions: "`layer` must resolve to one layer. Proposed for approval."
        ),
        CommandDescriptor(
            name: "layer.setOpacity",
            summary: "Sets a layer's or folder's opacity. A folder's opacity multiplies into each layer inside it.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, opacity: Double (0–1; 60% is 0.6) }",
            preconditions: "`layer` must resolve to one layer; opacity outside 0–1 is rejected. Proposed for approval."
        ),
        CommandDescriptor(
            name: "layer.setBlendMode",
            summary: "Sets a layer's blend mode, e.g. \"Multiply\", \"Screen\", \"Overlay\" (Photoshop names).",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, blendMode: String }",
            preconditions: "`layer` must resolve to a layer that is not a folder (folders always blend as Normal). Proposed for approval."
        ),
        CommandDescriptor(
            name: "layer.delete",
            summary: "Deletes a layer, or a folder together with everything inside it.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef }",
            preconditions: "`layer` must resolve to one layer that supplies no live mask to other layers. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.all",
            summary: "Selects the whole canvas.",
            mutatesDocument: true,
            argumentsSketch: "{}",
            preconditions: "A document must be open. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.deselect",
            summary: "Removes the selection, so edits apply to the whole layer again.",
            mutatesDocument: true,
            argumentsSketch: "{}",
            preconditions: "A document must be open. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.invert",
            summary: "Selects everything that was not selected.",
            mutatesDocument: true,
            argumentsSketch: "{}",
            preconditions: "Needs a selection (current, or made earlier in the same proposal). Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.rect",
            summary: "Selects a rectangle in document pixels (top-left origin, y down), replacing, adding to, or subtracting from the selection.",
            mutatesDocument: true,
            argumentsSketch: "{ x: Double, y: Double, width: Double, height: Double, mode?: \"replace\" | \"add\" | \"subtract\" = \"replace\" }",
            preconditions: "At least 1×1 and must overlap the canvas (clipped to it). subtract needs a selection. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.ellipse",
            summary: "Selects the ellipse inscribed in a rectangle, combined like selection.rect.",
            mutatesDocument: true,
            argumentsSketch: "{ x: Double, y: Double, width: Double, height: Double, mode?: \"replace\" | \"add\" | \"subtract\" = \"replace\" }",
            preconditions: "As selection.rect. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.expand",
            summary: "Grows the selection outward by a number of pixels, with rounded corners.",
            mutatesDocument: true,
            argumentsSketch: "{ amount: Int (1–500) }",
            preconditions: "Needs a selection. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.contract",
            summary: "Shrinks the selection inward by a number of pixels.",
            mutatesDocument: true,
            argumentsSketch: "{ amount: Int (1–500) }",
            preconditions: "Needs a selection. Contracting past the middle leaves an explicit empty selection. Proposed for approval."
        ),
        CommandDescriptor(
            name: "selection.feather",
            summary: "Softens the selection's edge by a number of pixels; repeating it softens further.",
            mutatesDocument: true,
            argumentsSketch: "{ amount: Int (1–250) }",
            preconditions: "Needs a selection. Proposed for approval."
        ),
        CommandDescriptor(
            name: "mask.add",
            summary: "Adds a layer mask that shows everything (reveal: true, white) or hides everything (reveal: false, black).",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, reveal: Bool }",
            preconditions: "`layer` must have no mask yet. Proposed for approval."
        ),
        CommandDescriptor(
            name: "mask.addFromSelection",
            summary: "Adds a layer mask made from the selection, which is deselected in the same step. shows: \"selection\" keeps only the selected area visible; \"outside\" hides it.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, shows: \"selection\" | \"outside\" }",
            preconditions: "Needs a selection; `layer` must have no mask yet. Proposed for approval."
        ),
        CommandDescriptor(
            name: "mask.setEnabled",
            summary: "Turns a layer's mask on or off without deleting it.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef, enabled: Bool }",
            preconditions: "`layer` must have a mask. Proposed for approval."
        ),
        CommandDescriptor(
            name: "mask.delete",
            summary: "Deletes a layer's mask.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef }",
            preconditions: "`layer` must have a mask. Proposed for approval."
        ),
        CommandDescriptor(
            name: "mask.clipToBelow",
            summary: "Clips a layer to the layer directly below it (a clipping mask), sharing that layer's base if it is itself clipped.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef }",
            preconditions: "`layer` must not be a folder or already clipped, and needs a non-folder layer directly below it in the same folder. Proposed for approval."
        ),
        CommandDescriptor(
            name: "mask.releaseClipping",
            summary: "Releases a clipping mask; clipped layers above it that share its base are released too.",
            mutatesDocument: true,
            argumentsSketch: "{ layer: LayerRef }",
            preconditions: "`layer` must be clipped. Proposed for approval."
        )
    ]

    static var commandNames: [String] { commands.map(\.name) }
}
