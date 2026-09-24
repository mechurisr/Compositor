import FoundationModels
import Observation
import Foundation
import SwiftUI

struct AssistantMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// Chat state for one document tab's AI assistant, backed by Apple's on-device model so using
/// the assistant needs no API key and no network request — see CLAUDE.md's "2부" for why this
/// exists and the design it follows. Stage 1's only tool (`CompositorTool`) can only run
/// `query.*` commands, so nothing this session does can change the document yet.
@MainActor
@Observable
final class AssistantSession {
    enum Availability: Equatable {
        case checking
        case available
        case unavailable(String)
    }

    private(set) var availability: Availability = .checking
    private(set) var isResponding = false
    private(set) var messages: [AssistantMessage] = []
    private var languageSession: LanguageModelSession?
    private let runner: EditCommandRunner
    @ObservationIgnored private let panel = FloatingPanelController(name: "assistantPanel")

    init(editorSession: EditorSession) {
        runner = EditCommandRunner(session: editorSession)
        refreshAvailability()
    }

    func showPanel() {
        panel.show(title: "Assistant", content: AssistantPanel(assistant: self))
    }

    func closePanel() { panel.close() }

    func togglePanel() {
        if panel.isVisible { closePanel() } else { showPanel() }
    }

    /// Apple Intelligence can be turned on, finish downloading, or become unavailable while the
    /// app is running, so callers re-check this (e.g. when the assistant panel appears) instead
    /// of trusting a value cached at launch.
    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            availability = .available
            if languageSession == nil { languageSession = makeSession() }
        case .unavailable(.appleIntelligenceNotEnabled):
            availability = .unavailable("Apple Intelligence가 꺼져 있습니다. 시스템 설정 > Apple Intelligence에서 켜주세요.")
        case .unavailable(.deviceNotEligible):
            availability = .unavailable("이 Mac은 Apple Intelligence를 지원하지 않습니다.")
        case .unavailable(.modelNotReady):
            availability = .unavailable("모델을 내려받거나 준비하는 중입니다. 잠시 후 다시 시도해주세요.")
        case .unavailable:
            availability = .unavailable("온디바이스 모델을 사용할 수 없습니다.")
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(tools: [CompositorTool(runner: runner)], instructions: Self.instructions)
    }

    private static let instructions = """
        You are an assistant embedded in Compositor, a macOS image editor. You can inspect the \
        open document by calling the compositorCommand tool with a command name and its JSON \
        arguments; call "query.getCapabilities" first if you don't already know what commands \
        exist, and "query.describeDocument" to see the canvas, its layers, and the current \
        selection before answering questions about them.

        Non-obvious facts about this app: coordinates are document pixels with the origin at the \
        top left, y increasing downward, and rotation clockwise. Layers are bottom-to-top in a \
        flat array; a layer's parentID gives its folder. A null selection means the whole canvas; \
        an empty (but non-null) selection means nothing at all — never treat it as "everything." \
        A layer mask is white-reveals/black-hides; a layer can also be clipped by another layer's \
        alpha (maskSourceID) or by an ancestor folder's mask. Folders are pass-through: a folder's \
        opacity and mask apply to each descendant individually, not to a flattened group.

        Keep replies short and concrete. If a command fails, read its error message and hint \
        before trying again.
        """

    /// Sends one user message and returns the model's reply.
    func send(_ text: String) async -> String {
        refreshAvailability()
        guard case .available = availability, let languageSession else {
            if case .unavailable(let reason) = availability { return reason }
            return "온디바이스 모델을 사용할 수 없습니다."
        }
        isResponding = true
        defer { isResponding = false }
        do {
            let response = try await languageSession.respond(to: text)
            return response.content
        } catch {
            return "오류가 발생했습니다: \(error.localizedDescription)"
        }
    }

    /// What the chat panel calls: appends the user's message and the model's reply to
    /// `messages`. `send(_:)` stays separate and return-value-based so tests can call it without
    /// a view.
    func submit(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isResponding else { return }
        messages.append(AssistantMessage(role: .user, text: trimmed))
        let reply = await send(trimmed)
        messages.append(AssistantMessage(role: .assistant, text: reply))
    }
}
