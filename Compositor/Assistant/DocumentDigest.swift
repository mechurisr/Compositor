import Foundation
import CoreGraphics

/// A read-only JSON view of the selection, since `DocumentSelection.path` is a `CGPath`
/// (not itself meaningfully serializable) but its bounds, feather, and emptiness are exactly
/// what CLAUDE.md 2.6 asks the digest to carry.
struct SelectionDigest: Encodable, Sendable {
    var isEmpty: Bool
    var bounds: CGRect
    var feather: Double
    var antialiased: Bool

    init(_ selection: DocumentSelection) {
        isEmpty = selection.isEmpty
        bounds = selection.path.boundingBoxOfPath
        feather = Double(selection.feather)
        antialiased = selection.antialiased
    }
}

struct HistoryDigest: Encodable, Sendable {
    var canUndo: Bool
    var canRedo: Bool
    var undoName: String
    var redoName: String
    var undoCount: Int
    var revision: UUID

    @MainActor init(session: EditorSession) {
        canUndo = session.canUndo
        canRedo = session.canRedo
        undoName = session.history.undoName
        redoName = session.history.redoName
        undoCount = session.history.undoCount
        revision = session.history.revision
    }
}

/// What `query.describeDocument` returns. `manifest` is the same `Codable` schema the project
/// file format uses (`docs/project-format.md`) — reused rather than re-described, per CLAUDE.md
/// 2.6 — with session-only state that never gets saved appended alongside it.
struct DocumentDigest: Encodable, Sendable {
    var manifest: ProjectManifest?
    var activeLayerID: UUID?
    var isMaskSelected: Bool
    var selection: SelectionDigest?
    var tool: String
    var history: HistoryDigest

    @MainActor init(session: EditorSession) {
        manifest = session.projectSnapshot()?.manifest
        activeLayerID = session.activeLayerID
        isMaskSelected = session.isMaskSelected
        selection = session.selection.map(SelectionDigest.init)
        tool = session.tool.rawValue
        history = HistoryDigest(session: session)
    }
}

/// What `query.describeLayer` returns: metadata a model can reason about without ever
/// receiving the layer's actual pixels.
struct LayerDigest: Encodable, Sendable {
    var id: UUID
    var name: String
    var isVisible: Bool
    var parentID: UUID?
    var isGroup: Bool
    var opacity: Double
    var blendMode: LayerBlendMode
    var hasPixels: Bool
    var transform: LayerTransform
    var hasMask: Bool
    var maskSourceID: UUID?
    var adjustment: LayerAdjustment?
    var hasEffects: Bool
    var hasText: Bool
    var thumbnailPNGBase64: String?

    init(layer: ImageLayer, includeThumbnail: Bool) throws {
        id = layer.id
        name = layer.name
        isVisible = layer.isVisible
        parentID = layer.parentID
        isGroup = layer.isGroup
        opacity = layer.opacity
        blendMode = layer.blendMode
        hasPixels = layer.asset != nil
        transform = layer.transform
        hasMask = layer.mask != nil
        maskSourceID = layer.maskSourceID
        adjustment = layer.adjustment
        hasEffects = layer.effects != nil
        hasText = layer.text != nil
        if includeThumbnail, let thumbnail = layer.asset?.thumbnail {
            thumbnailPNGBase64 = try PNGEncoding.base64(thumbnail)
        }
    }
}

/// What `query.renderCanvas` returns: a flattened, downscaled render of the whole document.
struct CanvasRenderDigest: Encodable, Sendable {
    var width: Int
    var height: Int
    var pngBase64: String
}
