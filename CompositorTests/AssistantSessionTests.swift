import Testing
@testable import Compositor
import FoundationModels

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
}
