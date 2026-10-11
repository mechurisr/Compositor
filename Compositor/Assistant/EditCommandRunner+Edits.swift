import Foundation

/// A mutating command checked against the live document and waiting for the person's approval.
/// `command` is pinned: an `.active` or `.index` reference is replaced by the id it resolved to,
/// so what runs is exactly what the approval card described, whatever is active by then.
struct ProposedEdit: Identifiable, Equatable, Sendable {
    /// Kept across re-validation (`renamingProposedLayer`), so the card's rows — and a name field
    /// being typed in — keep their identity.
    var id = UUID()
    let command: EditCommand
    /// What the approval card shows, in the panel's language.
    let summary: String
    /// Deletes something; the card marks it.
    let isDestructive: Bool
    /// Something the person should double-check before approving, shown on the card.
    var warning: String?
}

struct BatchReport: Equatable, Sendable {
    var undoName: String
    var appliedCount: Int
}

extension EditCommand {
    /// The wire name, as in `{"command": …}` and the catalog.
    var name: String {
        switch self {
        case .queryDescribeDocument: "query.describeDocument"
        case .queryDescribeLayer: "query.describeLayer"
        case .queryRenderCanvas: "query.renderCanvas"
        case .queryGetHistory: "query.getHistory"
        case .queryGetCapabilities: "query.getCapabilities"
        case .layerAdd: "layer.add"
        case .layerRename: "layer.rename"
        case .layerSetVisibility: "layer.setVisibility"
        case .layerSetOpacity: "layer.setOpacity"
        case .layerSetBlendMode: "layer.setBlendMode"
        case .layerDelete: "layer.delete"
        }
    }

    /// The same command aimed at `ref` instead.
    func targeting(_ ref: LayerRef) -> EditCommand {
        switch self {
        case .queryDescribeLayer(var a): a.layer = ref; return .queryDescribeLayer(a)
        case .layerRename(var a): a.layer = ref; return .layerRename(a)
        case .layerSetVisibility(var a): a.layer = ref; return .layerSetVisibility(a)
        case .layerSetOpacity(var a): a.layer = ref; return .layerSetOpacity(a)
        case .layerSetBlendMode(var a): a.layer = ref; return .layerSetBlendMode(a)
        case .layerDelete(var a): a.layer = ref; return .layerDelete(a)
        case .queryDescribeDocument, .queryRenderCanvas, .queryGetHistory, .queryGetCapabilities, .layerAdd: return self
        }
    }

    /// A layer name this command will create, so later commands in the same proposal can use it.
    var createdLayerName: String? {
        switch self {
        case .layerAdd(let a): a.name.map(EditCommand.trimmed).flatMap { $0.isEmpty ? nil : $0 }
        case .layerRename(let a): EditCommand.trimmed(a.name)
        default: nil
        }
    }

    static func trimmed(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The same add or rename, creating `name` instead.
    func creatingName(_ name: String) -> EditCommand {
        switch self {
        case .layerAdd: return .layerAdd(LayerAdd(name: name))
        case .layerRename(var a): a.name = name; return .layerRename(a)
        default: return self
        }
    }

    /// Setters that leave one value on one layer: a later one in the same proposal supersedes an
    /// earlier one, so a model correcting itself doesn't leave both on the approval card.
    var supersedingKey: String? {
        switch self {
        case .layerRename(let a): "\(name)|\(a.layer)"
        case .layerSetVisibility(let a): "\(name)|\(a.layer)"
        case .layerSetOpacity(let a): "\(name)|\(a.layer)"
        case .layerSetBlendMode(let a): "\(name)|\(a.layer)"
        default: nil
        }
    }
}

extension EditorSession {
    /// Why layer edits can't start right now, phrased for the model and the panel — or nil when they
    /// can. Mirrors `canEditLayers` condition for condition (keep the two in step), plus an open
    /// opacity drag: `setLayerOpacity` writes to the layer being dragged, not the active one.
    var layerEditBlocker: String? {
        if document == nil { return "no document is open" }
        if isProjectBusy { return "the app is busy with another operation" }
        if isImporting { return "an import is in progress" }
        if textDraft != nil { return "a text layer is being typed" }
        if brushStroke != nil { return "a brush stroke is in progress" }
        if warpStroke != nil { return "a warp stroke is in progress" }
        if transformEdit != nil { return "a transform is pending" }
        if cropRect != nil { return "a crop is pending" }
        if gradientEdit != nil { return "a gradient is being edited" }
        if pixelMove != nil { return "selected pixels are being moved" }
        if hueSaturation != nil { return "the Hue/Saturation panel is open" }
        if levels != nil { return "the Levels panel is open" }
        if filterEdit != nil { return "a filter panel is open" }
        if adjustmentEditingID != nil { return "an adjustment layer is being edited" }
        if selectionAmountOperation != nil { return "a selection amount prompt is open" }
        if renamingLayerID != nil { return "a layer is being renamed" }
        if showsNewDocument { return "the New Document sheet is open" }
        if showsImporter { return "the import dialog is open" }
        if opacityEditLayerID != nil { return "a layer's opacity is being adjusted" }
        return nil
    }

    /// Layers outside `id`'s subtree whose live mask (`maskSourceID`) comes from inside it.
    /// Deleting `id` would make `deleteLayer` stop for a Bake / Remove Links alert.
    func liveMaskDependents(ofDeleting id: UUID) -> [UUID] {
        let removed = descendantIDs(of: id).union([id])
        return (document?.layers ?? []).filter { !removed.contains($0.id) && $0.maskSourceID.map(removed.contains) == true }.map(\.id)
    }
}

extension EditCommandRunner {
    /// Checks a mutating command against the current document without running it, and describes
    /// it for the approval card. `pendingNames` are names earlier edits in the same proposal will
    /// create (`createdLayerName`), so a command may target a layer that doesn't exist yet.
    func propose(_ command: EditCommand, pendingNames: Set<String> = []) -> Result<ProposedEdit, EditCommandError> {
        guard command.mutatesDocument else {
            return .failure(.invalidArguments(command: command.name, reason: "it does not change the document, so call it directly"))
        }
        guard let document = session.document else { return .failure(.noDocument) }

        // Resolve the target now, pinning `.active`/`.index` to an id. A name only a pending edit
        // will create is left as a name and resolved when the batch runs.
        var target: ImageLayer?
        var pinned = command
        var label = ""
        if let ref = command.layerRef {
            if case .name(let name) = ref, pendingNames.contains(name), !document.layers.contains(where: { $0.name == name }) {
                label = "'\(name)'"
            } else {
                switch resolveLayer(ref) {
                case .success(let layer):
                    target = layer
                    label = "'\(layer.name)'"
                    pinned = command.targeting(.id(layer.id))
                case .failure(let error):
                    return .failure(error)
                }
            }
        }

        switch command {
        case .layerAdd(let a):
            if let name = a.name, EditCommand.trimmed(name).isEmpty {
                return .failure(.invalidArguments(command: command.name, reason: "name is empty; omit it for a default name"))
            }
            let summary = command.createdLayerName.map { "새 레이어 '\($0)' 추가" } ?? "새 레이어 추가"
            return .success(ProposedEdit(command: pinned, summary: summary, isDestructive: false))

        case .layerRename(let a):
            let name = EditCommand.trimmed(a.name)
            guard !name.isEmpty else { return .failure(.invalidArguments(command: command.name, reason: "name is empty")) }
            return .success(ProposedEdit(command: pinned, summary: "\(label) 이름을 '\(name)'(으)로 변경", isDestructive: false))

        case .layerSetVisibility(let a):
            return .success(ProposedEdit(command: pinned, summary: "\(label) \(a.visible ? "보이기" : "숨기기")", isDestructive: false))

        case .layerSetOpacity(let a):
            guard a.opacity.isFinite, (0...1).contains(a.opacity) else {
                return .failure(.invalidArguments(command: command.name,
                    reason: "opacity must be between 0 and 1 (60% is 0.6); got \(a.opacity)"))
            }
            let percent = Int((a.opacity * 100).rounded())
            return .success(ProposedEdit(command: pinned, summary: "\(label) 불투명도 \(percent)%", isDestructive: false))

        case .layerSetBlendMode(let a):
            guard let mode = Self.blendMode(named: a.blendMode) else {
                return .failure(.invalidArguments(command: command.name,
                    reason: "unknown blendMode \"\(a.blendMode)\"; use one of: \(LayerBlendMode.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            if target?.isGroup == true {
                return .failure(.notSupported("Folders are pass-through and always blend as Normal; set the blend mode on the layers inside instead."))
            }
            return .success(ProposedEdit(command: pinned, summary: "\(label) 블렌드 모드 \(mode.rawValue)", isDestructive: false))

        case .layerDelete:
            if let target {
                if !session.liveMaskDependents(ofDeleting: target.id).isEmpty {
                    return .failure(.notSupported("\(label) supplies a live mask to other layers; deleting it needs a choice (bake or unlink) only the person can make in the Layers panel."))
                }
                if target.isGroup {
                    let count = session.descendantIDs(of: target.id).count
                    return .success(ProposedEdit(command: pinned, summary: "폴더 \(label)와 안의 레이어 \(count)개 삭제", isDestructive: true))
                }
            }
            return .success(ProposedEdit(command: pinned, summary: "\(label) 삭제", isDestructive: true))

        case .queryDescribeDocument, .queryDescribeLayer, .queryRenderCanvas, .queryGetHistory, .queryGetCapabilities:
            return .failure(.invalidArguments(command: command.name, reason: "it does not change the document"))
        }
    }

    /// The person correcting, on the approval card, the name an add or rename will create — the
    /// fix for Korean names the model translated or garbled (CLAUDE.md 2.14). Later edits that
    /// refer to the old name follow it, and the whole proposal is checked again with `propose`,
    /// so the result is exactly as valid as if the model had written it. The corrected edit loses
    /// its warning (the person chose the name); ids are kept.
    func renamingProposedLayer(in edits: [ProposedEdit], editID: UUID, to name: String) -> Result<[ProposedEdit], EditCommandError> {
        guard let index = edits.firstIndex(where: { $0.id == editID }),
              let old = edits[index].command.createdLayerName else {
            return .failure(.invalidArguments(command: "rename", reason: "that edit doesn't name a layer"))
        }
        let new = EditCommand.trimmed(name)
        guard !new.isEmpty else { return .failure(.invalidArguments(command: edits[index].command.name, reason: "name is empty")) }

        var commands = edits.map(\.command)
        commands[index] = commands[index].creatingName(new)
        for later in commands.indices where later > index && commands[later].layerRef == .name(old) {
            commands[later] = commands[later].targeting(.name(new))
        }

        var rebuilt: [ProposedEdit] = []
        var pending: Set<String> = []
        for (position, command) in commands.enumerated() {
            switch propose(command, pendingNames: pending) {
            case .success(var edit):
                edit.id = edits[position].id
                edit.warning = position == index ? nil : edits[position].warning
                rebuilt.append(edit)
                if let created = command.createdLayerName { pending.insert(created) }
            case .failure(let error):
                return .failure(error)
            }
        }
        return .success(rebuilt)
    }

    /// Runs approved edits as one undo step named "AI: `label`" — the outer `beginEdit` folds every
    /// session method's own begin/end pair into it (`DocumentHistory`'s depth counter), so one ⌘Z
    /// takes back the whole proposal. Stops at the first failure and undoes what already ran.
    func applyBatch(_ commands: [EditCommand], label: String) async -> Result<BatchReport, EditCommandError> {
        if let blocker = session.layerEditBlocker { return .failure(.busy(blocker)) }
        let startRevision = session.history.revision
        session.beginEdit("AI: \(label)")
        var failure: EditCommandError?
        for command in commands {
            if case .failure(let error) = apply(command) {
                failure = error
                break
            }
        }
        session.endEdit()
        if let failure {
            // Leaves the partial step on the redo stack; acceptable, and far simpler than reaching
            // into `DocumentHistory` to discard it.
            if session.history.revision != startRevision { session.undo() }
            return .failure(failure)
        }
        return .success(BatchReport(undoName: session.history.undoName, appliedCount: commands.count))
    }

    /// One edit, through the same session method the menu or Layers panel calls. Those methods
    /// return silently when their own guard refuses, so each case checks the document afterwards.
    private func apply(_ command: EditCommand) -> Result<Void, EditCommandError> {
        switch command {
        case .layerAdd:
            let before = session.document?.layers.count ?? 0
            session.addBlankLayer()
            guard session.document?.layers.count == before + 1, let id = session.activeLayerID else {
                return .failure(.notApplied(command.name))
            }
            if let name = command.createdLayerName {
                session.renameLayer(id, to: name)
                return check(id, command) { $0.name == name }
            }
            return .success(())

        case .layerRename(let a):
            return resolveLayer(a.layer).flatMap { layer in
                session.renameLayer(layer.id, to: a.name)
                return check(layer.id, command) { $0.name == EditCommand.trimmed(a.name) }
            }

        case .layerSetVisibility(let a):
            return resolveLayer(a.layer).flatMap { layer in
                guard layer.isVisible != a.visible else { return .success(()) }
                session.toggleLayerVisibility(layer.id)
                return check(layer.id, command) { $0.isVisible == a.visible }
            }

        case .layerSetOpacity(let a):
            return resolveLayer(a.layer).flatMap { layer in
                guard layer.opacity != a.opacity else { return .success(()) }
                return select(layer.id, for: command).flatMap {
                    session.setLayerOpacity(a.opacity)
                    return check(layer.id, command) { $0.opacity == a.opacity }
                }
            }

        case .layerSetBlendMode(let a):
            guard let mode = Self.blendMode(named: a.blendMode) else {
                return .failure(.invalidArguments(command: command.name, reason: "unknown blendMode \"\(a.blendMode)\""))
            }
            return resolveLayer(a.layer).flatMap { layer in
                guard layer.blendMode != mode else { return .success(()) }
                return select(layer.id, for: command).flatMap {
                    session.setLayerBlendMode(mode)
                    return check(layer.id, command) { $0.blendMode == mode }
                }
            }

        case .layerDelete(let a):
            return resolveLayer(a.layer).flatMap { layer in
                // Checked again here: the document may have changed since the proposal.
                guard session.liveMaskDependents(ofDeleting: layer.id).isEmpty else {
                    return .failure(.notSupported("'\(layer.name)' supplies a live mask to other layers; delete it in the Layers panel."))
                }
                session.deleteLayer(layer.id)
                guard session.document?.layers.contains(where: { $0.id == layer.id }) == false else {
                    return .failure(.notApplied(command.name))
                }
                return .success(())
            }

        case .queryDescribeDocument, .queryDescribeLayer, .queryRenderCanvas, .queryGetHistory, .queryGetCapabilities:
            return .failure(.invalidArguments(command: command.name, reason: "it does not change the document"))
        }
    }

    /// Opacity and blend mode act on the active layer, as they do for the person.
    private func select(_ id: UUID, for command: EditCommand) -> Result<Void, EditCommandError> {
        session.selectLayer(id)
        return session.activeLayerID == id ? .success(()) : .failure(.notApplied("Selecting the layer for \(command.name)"))
    }

    private func check(_ id: UUID, _ command: EditCommand, _ applied: (ImageLayer) -> Bool) -> Result<Void, EditCommandError> {
        guard let layer = session.document?.layers.first(where: { $0.id == id }), applied(layer) else {
            return .failure(.notApplied(command.name))
        }
        return .success(())
    }

    static func blendMode(named name: String) -> LayerBlendMode? {
        let wanted = EditCommand.trimmed(name).lowercased()
        return LayerBlendMode.allCases.first { $0.rawValue.lowercased() == wanted }
    }
}
