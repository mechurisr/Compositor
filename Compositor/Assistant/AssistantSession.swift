import FoundationModels
import Observation
import Foundation
import SwiftUI
import NaturalLanguage

struct AssistantMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    var text: String
}

/// Edits the model proposed in one turn, waiting for the person to press Apply or Discard.
struct AssistantProposal: Identifiable, Equatable {
    let id = UUID()
    let edits: [ProposedEdit]
    /// The document revision the model planned against. If the person edits the document before
    /// approving, the plan may no longer fit, so it isn't applied (CLAUDE.md 2.8).
    let baseRevision: UUID

    /// The undo step's name after "AI: ".
    var label: String {
        guard let first = edits.first?.summary else { return "" }
        return edits.count == 1 ? first : "\(first) 외 \(edits.count - 1)건"
    }
}

/// Chat state for one document tab's AI assistant, backed by Apple's on-device model so using
/// the assistant needs no API key and no network request — see CLAUDE.md's "2부" for why this
/// exists and the design it follows. The model reads the document through `InspectDocumentTool`; its
/// edits are only proposed, become `proposal`, and run when the person approves them.
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
    /// What the model proposed in its last turn, until the person applies or discards it.
    private(set) var proposal: AssistantProposal?
    private var languageSession: LanguageModelSession?
    private let runner: EditCommandRunner
    /// What happened to the last proposal, told to the model with the next message so its picture
    /// of the document stays right.
    @ObservationIgnored private var proposalOutcomeNote: String?
    @ObservationIgnored private let canvasMailbox = CanvasImageMailbox()
    @ObservationIgnored private let proposals = ProposalCollector()
    @ObservationIgnored private let panel = FloatingPanelController(name: "assistantPanel")

    init(editorSession: EditorSession) {
        runner = EditCommandRunner(session: editorSession)
        refreshAvailability()
    }

    func showPanel() {
        panel.show(title: "Assistant", content: AssistantPanel(assistant: self))
    }

    func closePanel() { panel.close() }

    var isPanelVisible: Bool { panel.isVisible }

    func togglePanel() {
        if isPanelVisible { closePanel() } else { showPanel() }
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
        let backend = CompositorToolBackend(runner: runner, mailbox: canvasMailbox, proposals: proposals)
        return LanguageModelSession(tools: [InspectDocumentTool(backend: backend), EditLayerTool(backend: backend)],
                                    instructions: Self.instructions())
    }

    private static let baseInstructions = """
        You are an assistant embedded in Compositor, a macOS image editor. Use the \
        inspectDocument tool to read the open document: describeDocument shows the canvas, its \
        layers, and the current selection — call it before answering questions about them. \
        Whenever a question is about what the canvas looks like — what is drawn on it, its \
        colors, or its content — call inspectDocument with renderCanvas to see it.

        Non-obvious facts about this app: coordinates are document pixels with the origin at the \
        top left, y increasing downward, and rotation clockwise. Layers are bottom-to-top in a \
        flat array; a layer's parentID gives its folder. A null selection means the whole canvas; \
        an empty (but non-null) selection means nothing at all — never treat it as "everything." \
        A layer mask is white-reveals/black-hides; a layer can also be clipped by another layer's \
        alpha (maskSourceID) or by an ancestor folder's mask. Folders are pass-through: a folder's \
        opacity and mask apply to each descendant individually, not to a flattened group.

        To change a layer, call the editLayer tool — once per change. Changes do not happen \
        right away: each one is queued as a proposal the person approves with an Apply button. \
        After add or rename, refer to that layer by its new name. Write layer names exactly as \
        the person typed them, in their language — never translate a name. Once you have \
        proposed everything, tell the person in one short sentence what you proposed.

        Keep replies short and concrete. If a tool returns an error, read its message and hint \
        before trying again.
        """

    /// For a non-English speaker, only a soft same-language nudge — never the language's name.
    /// Measured on the on-device model: naming the language ("You MUST respond in Korean", or even
    /// "write your final reply in Korean") together with a Korean question stopped it from calling
    /// tools at all (0 of 3), so it narrated plans and invented answers instead. This nudge keeps
    /// tool calling (3 of 3) but only gets the language right most of the time, so `localized(_:)`
    /// translates whatever still comes back in the wrong language.
    static func instructions(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard replyLanguageCode(preferredLanguages: preferredLanguages) != nil else { return baseInstructions }
        return baseInstructions + "\n\nAlways reply in the same language the person writes in."
    }

    /// The language replies should end up in, or `nil` for English (nothing to do). Reads
    /// `Locale.preferredLanguages` rather than `Locale.current`: the app ships only an English
    /// localization, so `Locale.current` resolves to English (e.g. `en_KR`) even for a person
    /// whose system language is Korean.
    static func replyLanguageCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String? {
        guard let preferred = preferredLanguages.first,
              let code = Locale(identifier: preferred).language.languageCode?.identifier,
              code != "en" else { return nil }
        return code
    }

    /// Translates `reply` into the person's language when the tool-using session answered in
    /// another one (English tool output and the English canvas follow-up prompt pull it that
    /// way). A separate tool-free session, so naming the language here can't disturb tool calls.
    private func localized(_ reply: String) async -> String {
        guard let code = Self.replyLanguageCode() else { return reply }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(reply)
        guard let detected = recognizer.dominantLanguage, detected != NLLanguage(rawValue: code) else { return reply }
        let languageName = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        let translator = LanguageModelSession(instructions: """
            Translate the user's text into \(languageName). Output only the translation. Keep \
            numbers, names, and identifiers unchanged.
            """)
        return (try? await translator.respond(to: reply).content) ?? reply
    }

    /// Sends one user message and returns the model's reply.
    func send(_ text: String) async -> String {
        refreshAvailability()
        guard case .available = availability, let languageSession else {
            if case .unavailable(let reason) = availability { return reason }
            return "온디바이스 모델을 사용할 수 없습니다."
        }
        isResponding = true
        defer {
            isResponding = false
            _ = canvasMailbox.take() // Never let a stale render leak into the next turn.
        }
        let prompt = proposalOutcomeNote.map { "\($0)\n\n\(text)" } ?? text
        proposalOutcomeNote = nil
        _ = proposals.takeAll()
        proposals.request = text
        do {
            let response = try await languageSession.respond(to: prompt)
            let reply: String
            // The model asked to see the canvas mid-turn. It couldn't actually see it then (images
            // in tool output are ignored — see `CanvasImageMailbox`), so its reply is discarded
            // and the question is re-asked once in the same session with the image attached
            // directly. Only once: a render requested during the follow-up is dropped.
            if #available(macOS 27.0, *), let image = canvasMailbox.take() {
                let followUp = try await languageSession.respond(to: Self.canvasFollowUp(question: text, image: image))
                reply = await localized(followUp.content)
            } else {
                reply = await localized(response.content)
            }
            // A turn that proposed edits replaces any earlier proposal still waiting.
            let edits = proposals.takeAll()
            if !edits.isEmpty { proposal = AssistantProposal(edits: edits, baseRevision: runner.session.history.revision) }
            return reply
        } catch {
            _ = proposals.takeAll() // Half a turn's edits are not a plan anyone agreed to.
            return "오류가 발생했습니다: \(error.localizedDescription)"
        }
    }

    /// Runs the waiting proposal as one undo step. Refuses if the document changed since the
    /// model planned it — its layer references or intent may no longer fit.
    func applyProposal() async {
        guard let proposal, !isResponding else { return }
        self.proposal = nil
        guard runner.session.history.revision == proposal.baseRevision else {
            messages.append(AssistantMessage(role: .assistant,
                text: "제안한 뒤에 문서가 바뀌어서 적용하지 않았습니다. 다시 요청해 주세요."))
            proposalOutcomeNote = "(The document changed after your last proposal, so it was not applied.)"
            return
        }
        switch await runner.applyBatch(proposal.edits.map(\.command), label: proposal.label) {
        case .success(let report):
            messages.append(AssistantMessage(role: .assistant,
                text: "적용했습니다. ⌘Z 한 번으로 모두 되돌릴 수 있습니다. (\(report.undoName))"))
            proposalOutcomeNote = "(The person applied your last proposal.)"
        case .failure(.busy(let blocker)):
            // The person's turn, not a bad plan: keep the proposal so Apply works once they finish.
            self.proposal = proposal
            messages.append(AssistantMessage(role: .assistant,
                text: "지금은 적용할 수 없습니다(\(blocker)). 하던 작업을 마친 뒤 다시 적용을 눌러 주세요."))
        case .failure(let error):
            messages.append(AssistantMessage(role: .assistant, text: "적용하지 못했습니다: \(error.message)"))
            proposalOutcomeNote = "(Your last proposal could not be applied: \(error.message) Nothing was changed.)"
        }
    }

    func discardProposal() {
        guard proposal != nil else { return }
        proposal = nil
        messages.append(AssistantMessage(role: .assistant, text: "제안을 취소했습니다."))
        proposalOutcomeNote = "(The person discarded your last proposal; nothing was changed.)"
    }

    @available(macOS 27.0, *)
    @PromptBuilder
    private static func canvasFollowUp(question: String, image: CGImage) -> Prompt {
        """
        Here is the canvas you asked to see with query.renderCanvas, rendered at \
        \(image.width)x\(image.height) pixels. Using what you see in it, answer my earlier \
        message: "\(question)"
        """
        Attachment(image)
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
