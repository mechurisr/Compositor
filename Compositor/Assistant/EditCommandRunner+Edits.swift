import Foundation
import CoreGraphics

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
        case .selectionAll: "selection.all"
        case .selectionDeselect: "selection.deselect"
        case .selectionInvert: "selection.invert"
        case .selectionRect: "selection.rect"
        case .selectionEllipse: "selection.ellipse"
        case .selectionExpand: "selection.expand"
        case .selectionContract: "selection.contract"
        case .selectionFeather: "selection.feather"
        case .maskAdd: "mask.add"
        case .maskAddFromSelection: "mask.addFromSelection"
        case .maskSetEnabled: "mask.setEnabled"
        case .maskDelete: "mask.delete"
        case .maskClipToBelow: "mask.clipToBelow"
        case .maskReleaseClipping: "mask.releaseClipping"
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
        case .maskAdd(var a): a.layer = ref; return .maskAdd(a)
        case .maskAddFromSelection(var a): a.layer = ref; return .maskAddFromSelection(a)
        case .maskSetEnabled(var a): a.layer = ref; return .maskSetEnabled(a)
        case .maskDelete: return .maskDelete(MaskTarget(layer: ref))
        case .maskClipToBelow: return .maskClipToBelow(MaskTarget(layer: ref))
        case .maskReleaseClipping: return .maskReleaseClipping(MaskTarget(layer: ref))
        default: return self
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
        case .maskSetEnabled(let a): "\(name)|\(a.layer)"
        // Both kinds of mask creation share a key: a layer takes one mask, and a second add in
        // the same proposal (the model once queued two) would fail and roll back the whole batch.
        case .maskAdd(let a): "mask.create|\(a.layer)"
        case .maskAddFromSelection(let a): "mask.create|\(a.layer)"
        default: nil
        }
    }
}

extension EditorSession {
    /// Why layer edits can't start right now, phrased for the model and the panel — or nil when they
    /// can. Mirrors `canEditLayers` condition for condition (keep the two in step), plus an open
    /// opacity drag: `setLayerOpacity` writes to the layer being dragged, not the active one — and
    /// a lasso or marquee being drawn, which the selection commands' `canModifySelection` waits for.
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
        if lassoDraft != nil { return "a selection is being drawn" }
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
    /// create (`createdLayerName`), so a command may target a layer that doesn't exist yet;
    /// `selectionPending` says an earlier edit leaves a selection (`createsSelection`).
    func propose(_ command: EditCommand, pendingNames: Set<String> = [],
                 selectionPending: Bool = false) -> Result<ProposedEdit, EditCommandError> {
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

        case .selectionAll, .selectionDeselect, .selectionInvert, .selectionRect, .selectionEllipse,
             .selectionExpand, .selectionContract, .selectionFeather:
            return proposeSelection(command, canvas: CGRect(origin: .zero, size: document.size),
                                    hasSelection: (session.selection?.isEmpty == false) || selectionPending)
                .map { ProposedEdit(command: command, summary: $0, isDestructive: false) }

        case .maskAdd, .maskAddFromSelection, .maskSetEnabled, .maskDelete, .maskClipToBelow, .maskReleaseClipping:
            return proposeMask(command, target: target, label: label,
                               hasSelection: (session.selection?.isEmpty == false) || selectionPending)
                .map { ProposedEdit(command: pinned, summary: $0.summary, isDestructive: $0.destructive) }

        case .queryDescribeDocument, .queryDescribeLayer, .queryRenderCanvas, .queryGetHistory, .queryGetCapabilities:
            return .failure(.invalidArguments(command: command.name, reason: "it does not change the document"))
        }
    }

    /// Mask commands' checks and card summary. `target` is nil for a layer an earlier edit in the
    /// same proposal will create; it has no mask and no clipping yet, which is all a new layer can be.
    private func proposeMask(_ command: EditCommand, target: ImageLayer?, label: String,
                             hasSelection: Bool) -> Result<(summary: String, destructive: Bool), EditCommandError> {
        let hasMask = target?.mask != nil
        switch command {
        case .maskAdd(let a):
            if hasMask { return .failure(.notSupported("\(label) already has a mask; delete it first, or change it in the Layers panel.")) }
            return .success((a.reveal ? "\(label)에 마스크 추가 (전부 보임)" : "\(label)에 마스크 추가 (전부 숨김)", false))
        case .maskAddFromSelection(let a):
            if hasMask { return .failure(.notSupported("\(label) already has a mask; delete it first.")) }
            guard hasSelection else {
                return .failure(.notSupported("mask.addFromSelection needs a selection; select something first."))
            }
            let what = a.shows == .selection ? "선택 영역만 보이게" : "선택 영역을 숨기게"
            return .success(("\(label)에 마스크 추가 (\(what), 선택 해제됨)", false))
        case .maskSetEnabled(let a):
            guard hasMask else { return .failure(.notSupported("\(label) has no mask.")) }
            return .success(("\(label) 마스크 \(a.enabled ? "켜기" : "끄기")", false))
        case .maskDelete:
            guard hasMask else { return .failure(.notSupported("\(label) has no mask.")) }
            return .success(("\(label) 마스크 삭제", true))
        case .maskClipToBelow:
            guard let target else { return .failure(.notSupported("A new layer can be clipped once it exists; propose it after Apply.")) }
            guard target.maskSourceID == nil else { return .failure(.notSupported("\(label) is already clipped.")) }
            guard session.canToggleClippingMask(target.id), let below = layerBelow(target) else {
                return .failure(.notSupported("\(label) can't be clipped: it needs a non-folder layer directly below it in the same folder."))
            }
            return .success(("\(label)을(를) 아래 '\(below.name)'에 클리핑", false))
        case .maskReleaseClipping:
            guard let target, let source = target.maskSourceID else { return .failure(.notSupported("\(label) is not clipped.")) }
            // Releasing a layer releases the clipped layers above it that share its base.
            let siblings = (session.document?.layers ?? []).filter { $0.parentID == target.parentID }
            let above = siblings.drop { $0.id != target.id }.dropFirst().prefix { $0.maskSourceID == source }.count
            return .success((above > 0 ? "\(label) 클리핑 해제 (위의 \(above)개도 함께)" : "\(label) 클리핑 해제", false))
        default:
            return .failure(.invalidArguments(command: command.name, reason: "not a mask command"))
        }
    }

    /// The sibling just below `layer` in its folder — what a clipping mask attaches to.
    private func layerBelow(_ layer: ImageLayer) -> ImageLayer? {
        let siblings = (session.document?.layers ?? []).filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == layer.id }), index > 0 else { return nil }
        return siblings[index - 1]
    }

    /// Selection commands' checks and card summary. A shape must overlap the canvas: clipped to it,
    /// one entirely outside would leave an explicit *empty* selection, which every later edit treats
    /// as "touch nothing" (CLAUDE.md 1.3) — almost certainly not what was asked.
    private func proposeSelection(_ command: EditCommand, canvas: CGRect, hasSelection: Bool) -> Result<String, EditCommandError> {
        if command.needsSelection, !hasSelection {
            return .failure(.notSupported("\(command.name) needs a selection; select something first (selection.rect, selection.all, …)."))
        }
        switch command {
        case .selectionAll: return .success("전체 선택")
        case .selectionDeselect: return .success("선택 해제")
        case .selectionInvert: return .success("선택 반전")
        case .selectionRect(let shape), .selectionEllipse(let shape):
            let rect = shape.rect.standardized
            guard [shape.x, shape.y, shape.width, shape.height].allSatisfy(\.isFinite), rect.width >= 1, rect.height >= 1 else {
                return .failure(.invalidArguments(command: command.name, reason: "width and height must be at least 1 pixel"))
            }
            guard rect.intersects(canvas) else {
                return .failure(.invalidArguments(command: command.name,
                    reason: "the shape lies outside the \(Int(canvas.width))×\(Int(canvas.height)) canvas"))
            }
            if shape.mode == .subtract, !hasSelection {
                return .failure(.notSupported("Subtracting needs a selection to subtract from."))
            }
            let kind = if case .selectionEllipse = command { "타원" } else { "사각형" }
            let mode = switch shape.mode { case .replace: "선택"; case .add: "선택에 추가"; case .subtract: "선택에서 빼기" }
            return .success("\(kind) \(mode) (\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))×\(Int(rect.height)))")
        case .selectionExpand(let a), .selectionContract(let a):
            guard (1...500).contains(a.amount) else {
                return .failure(.invalidArguments(command: command.name, reason: "amount must be 1–500 pixels; got \(a.amount)"))
            }
            let verb = if case .selectionExpand = command { "확장" } else { "축소" }
            return .success("선택 영역 \(a.amount)px \(verb)")
        case .selectionFeather(let a):
            guard (1...250).contains(a.amount) else {
                return .failure(.invalidArguments(command: command.name, reason: "amount must be 1–250 pixels; got \(a.amount)"))
            }
            return .success("선택 영역 경계 \(a.amount)px 부드럽게")
        default:
            return .failure(.invalidArguments(command: command.name, reason: "not a selection command"))
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
        var selectionPending = false
        for (position, command) in commands.enumerated() {
            defer { selectionPending = selectionPending || command.createsSelection }
            switch propose(command, pendingNames: pending, selectionPending: selectionPending) {
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

        case .selectionAll, .selectionDeselect, .selectionInvert, .selectionRect, .selectionEllipse,
             .selectionExpand, .selectionContract, .selectionFeather:
            return applySelection(command)

        case .maskAdd, .maskAddFromSelection, .maskSetEnabled, .maskDelete, .maskClipToBelow, .maskReleaseClipping:
            guard let ref = command.layerRef else { return .failure(.notApplied(command.name)) }
            return resolveLayer(ref).flatMap { applyMask(command, to: $0) }

        case .queryDescribeDocument, .queryDescribeLayer, .queryRenderCanvas, .queryGetHistory, .queryGetCapabilities:
            return .failure(.invalidArguments(command: command.name, reason: "it does not change the document"))
        }
    }

    /// Through the Select menu's own methods (and the marquee's `applySelection`), so the result —
    /// clipping to the canvas, antialiasing, feather stacking — is what the person would get.
    private func applySelection(_ command: EditCommand) -> Result<Void, EditCommandError> {
        if command.needsSelection, session.selection?.isEmpty != false {
            return .failure(.notSupported("\(command.name) needs a selection, and there is none."))
        }
        let before = session.selection
        switch command {
        case .selectionAll: session.selectAll()
        case .selectionDeselect: session.deselect(); return session.selection == nil ? .success(()) : .failure(.notApplied(command.name))
        case .selectionInvert: session.invertSelection()
        case .selectionRect(let shape):
            session.applySelection(CGPath(rect: shape.rect.standardized, transform: nil), mode: Self.mode(shape.mode), name: "Rectangular Marquee")
        case .selectionEllipse(let shape):
            session.applySelection(CGPath(ellipseIn: shape.rect.standardized, transform: nil), mode: Self.mode(shape.mode), name: "Elliptical Marquee")
        case .selectionExpand(let a): session.expandSelection(by: a.amount)
        case .selectionContract(let a): session.contractSelection(by: a.amount)
        case .selectionFeather(let a): session.featherSelection(by: a.amount)
        default: return .failure(.invalidArguments(command: command.name, reason: "not a selection command"))
        }
        // Re-selecting what is already selected is fine; otherwise the selection must have changed.
        guard session.selection != nil, session.selection != before || command.createsSelection else {
            return .failure(.notApplied(command.name))
        }
        return .success(())
    }

    /// Through the Layers panel's own mask methods. Those act on the active layer, so the layer is
    /// selected first, as it would be by the person; adding a mask also targets it for painting
    /// (`isMaskSelected`), exactly as the panel does.
    private func applyMask(_ command: EditCommand, to layer: ImageLayer) -> Result<Void, EditCommandError> {
        switch command {
        case .maskAdd(let a):
            return select(layer.id, for: command).flatMap {
                session.addLayerMask(revealing: a.reveal)
                return check(layer.id, command) { $0.mask != nil }
            }
        case .maskAddFromSelection(let a):
            guard session.selection?.isEmpty == false else { return .failure(.notSupported("There is no selection to make the mask from.")) }
            return select(layer.id, for: command).flatMap {
                // This app's `addMask(revealing: true)` hides the selection; false shows only it.
                session.addMask(revealing: a.shows == .outside)
                return check(layer.id, command) { $0.mask != nil }
            }
        case .maskSetEnabled(let a):
            guard let mask = layer.mask else { return .failure(.notSupported("'\(layer.name)' has no mask.")) }
            guard mask.isEnabled != a.enabled else { return .success(()) }
            return select(layer.id, for: command).flatMap {
                session.toggleLayerMask()
                return check(layer.id, command) { $0.mask?.isEnabled == a.enabled }
            }
        case .maskDelete:
            guard layer.mask != nil else { return .failure(.notSupported("'\(layer.name)' has no mask.")) }
            return select(layer.id, for: command).flatMap {
                session.deleteLayerMask()
                return check(layer.id, command) { $0.mask == nil }
            }
        case .maskClipToBelow:
            guard layer.maskSourceID == nil else { return .success(()) }
            session.toggleClippingMask(layer.id)
            return check(layer.id, command) { $0.maskSourceID != nil }
        case .maskReleaseClipping:
            guard layer.maskSourceID != nil else { return .success(()) }
            session.removeLiveMask(from: layer.id)
            return check(layer.id, command) { $0.maskSourceID == nil }
        default:
            return .failure(.invalidArguments(command: command.name, reason: "not a mask command"))
        }
    }

    private static func mode(_ mode: SelectionShape.Mode) -> SelectionMode {
        switch mode {
        case .replace: .replace
        case .add: .add
        case .subtract: .subtract
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
