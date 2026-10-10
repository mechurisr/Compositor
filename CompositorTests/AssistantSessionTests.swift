import Testing
@testable import Compositor
import FoundationModels
import Foundation

/// The on-device model may not be available in a test environment (Apple Intelligence off, an
/// ineligible Mac, or a model still downloading), so these tests check `availability` first and
/// only make live model assertions when it reports `.available` — matching the fallback pattern
/// Apple's own docs recommend for any Foundation Models feature.
@MainActor
struct AssistantSessionTests {
    @Test func reportsAnUnavailableReasonInsteadOfCrashing() async throws {
        let session = AssistantSession(editorSession: EditorSession())
        guard case .unavailable = SystemLanguageModel.default.availability else {
            return // Covered by the live test below.
        }
        session.refreshAvailability()
        guard case .unavailable(let reason) = session.availability else {
            Issue.record("expected .unavailable to mirror SystemLanguageModel's own state")
            return
        }
        #expect(!reason.isEmpty)
        let reply = await session.send("문서를 설명해줘")
        #expect(reply == reason)
    }

    @Test func answersAQuestionAboutAnEmptyDocumentWhenAvailable() async throws {
        guard case .available = SystemLanguageModel.default.availability else {
            return // Covered by the unavailable-path test above.
        }
        let session = AssistantSession(editorSession: EditorSession())
        let reply = await session.send("Is a document currently open? Answer yes or no and say why.")
        #expect(!reply.isEmpty)
        #expect(session.isResponding == false)
    }

    /// End-to-end check that the model really sees the canvas: images in tool output are ignored
    /// by the on-device model (it guessed "red" for every color), so this only passes if
    /// `AssistantSession` re-asks with the render attached directly.
    @Test func seesTheCanvasColorWhenVisionIsAvailable() async throws {
        guard case .available = SystemLanguageModel.default.availability, CompositorToolBackend.modelCanSee else {
            return
        }
        let editor = EditorSession()
        editor.createDocument(width: 256, height: 256, emptyLayer: true)
        editor.foregroundColor = PaletteColor(red: 0.1, green: 0.2, blue: 0.95)
        await editor.fillSelection(with: .foreground)

        let session = AssistantSession(editorSession: editor)
        let reply = await session.send("Render the canvas and tell me which single color fills it, in one word.")
        // The reply may have been translated into the machine's preferred language.
        #expect(["blue", "파란", "파랑"].contains { reply.lowercased().contains($0) }, "reply was: \(reply)")
    }

    /// Korean questions must still reach the tool (naming the language in the instructions once
    /// made the model narrate tool calls as text instead), and the reply must come back in Korean.
    @Test func answersKoreanQuestionsInKoreanUsingTools() async throws {
        guard case .available = SystemLanguageModel.default.availability,
              AssistantSession.replyLanguageCode() == "ko" else {
            return
        }
        let editor = EditorSession()
        editor.createDocument(width: 320, height: 240, emptyLayer: true)
        let session = AssistantSession(editorSession: editor)
        let reply = await session.send("캔버스 크기가 어떻게 돼?")
        #expect(reply.contains("320") && reply.contains("240"), "reply was: \(reply)")
        #expect(reply.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }, "reply was: \(reply)")
    }

    /// A Korean edit request ends as a proposal (not a direct edit), and applying it changes the
    /// document as one undo step.
    @Test func proposesAnEditInsteadOfApplyingItAndAppliesOnApproval() async throws {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let editor = EditorSession()
        editor.createDocument(width: 200, height: 100, emptyLayer: true)
        let before = editor.document
        let undoCount = editor.history.undoCount

        let session = AssistantSession(editorSession: editor)
        let reply = await session.send("Layer 1 불투명도를 50%로 바꿔줘")
        #expect(editor.document == before, "edits must wait for approval")
        let proposal = try #require(session.proposal, "no proposal; reply was: \(reply)")
        #expect(proposal.edits.contains { $0.command == .layerSetOpacity(LayerSetOpacity(layer: .id(editor.activeLayerID!), opacity: 0.5)) },
                "proposed: \(proposal.edits.map(\.summary))")

        await session.applyProposal()
        #expect(session.proposal == nil)
        #expect(editor.document?.layers.first?.opacity == 0.5)
        #expect(editor.history.undoCount == undoCount + 1)
    }

    @Test func aProposalIsNotAppliedAfterThePersonEditsTheDocument() async throws {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let editor = EditorSession()
        editor.createDocument(width: 200, height: 100, emptyLayer: true)
        let session = AssistantSession(editorSession: editor)
        _ = await session.send("Layer 1을 숨겨줘")
        guard session.proposal != nil else { return } // The model's call; covered by the test above.

        editor.addBlankLayer() // The person edits before approving.
        let after = editor.document
        await session.applyProposal()
        #expect(editor.document == after)
        #expect(session.messages.last?.text.contains("바뀌어서") == true)
    }

    /// The app ships only an English localization, so the directive must follow the person's
    /// preferred language, not the app's resolved `Locale.current`.
    @Test func instructionsFollowThePreferredLanguage() {
        #expect(AssistantSession.replyLanguageCode(preferredLanguages: ["ko-KR", "en-US"]) == "ko")
        #expect(AssistantSession.replyLanguageCode(preferredLanguages: ["en-GB"]) == nil)
        #expect(AssistantSession.replyLanguageCode(preferredLanguages: []) == nil)

        let korean = AssistantSession.instructions(preferredLanguages: ["ko-KR", "en-US"])
        #expect(korean.contains("same language the person writes in"))
        // Naming the language stops the on-device model from calling tools on Korean questions.
        #expect(!korean.contains("Korean"))

        let english = AssistantSession.instructions(preferredLanguages: ["en-GB"])
        #expect(!english.contains("same language the person writes in"))
        #expect(AssistantSession.instructions(preferredLanguages: []) == english)
    }
}
