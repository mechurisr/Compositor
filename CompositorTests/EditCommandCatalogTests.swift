import Testing
@testable import Compositor
import Foundation

/// Drift protection between `EditCommandCatalog` and `EditCommand.init(from:)` (CLAUDE.md 2.7):
/// a command added to the decoder but never described here, or described here but never wired
/// into the decoder, fails one of these tests instead of surfacing only when a model tries it.
struct EditCommandCatalogTests {
    /// Every command `EditCommand.init(from:)` currently decodes, paired with a minimal valid
    /// JSON payload. Kept as a literal list rather than derived by reflection, so a name that
    /// only exists on one side of the drift shows up here as a mismatch.
    private static let implementedCommands: [String: String] = [
        "query.describeDocument": "{}",
        "query.describeLayer": "{ \"layer\": { \"active\": true } }",
        "query.renderCanvas": "{}",
        "query.getHistory": "{}",
        "query.getCapabilities": "{}"
    ]

    @Test func catalogListsExactlyTheImplementedCommands() {
        #expect(Set(EditCommandCatalog.commandNames) == Set(Self.implementedCommands.keys))
    }

    @Test func everyCatalogEntryDecodesWithoutAnUnknownCommandError() throws {
        for name in EditCommandCatalog.commandNames {
            let arguments = try #require(Self.implementedCommands[name])
            let json = "{ \"command\": \"\(name)\", \"arguments\": \(arguments) }".data(using: .utf8)!
            _ = try JSONDecoder().decode(EditCommand.self, from: json)
        }
    }

    @Test func everyCatalogEntryIsReadOnlyInStageOne() {
        #expect(EditCommandCatalog.commands.allSatisfy { !$0.mutatesDocument })
    }
}
