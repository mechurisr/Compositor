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
        "query.getCapabilities": "{}",
        "layer.add": "{}",
        "layer.rename": "{ \"layer\": { \"active\": true }, \"name\": \"Sky\" }",
        "layer.setVisibility": "{ \"layer\": { \"active\": true }, \"visible\": false }",
        "layer.setOpacity": "{ \"layer\": { \"active\": true }, \"opacity\": 0.5 }",
        "layer.setBlendMode": "{ \"layer\": { \"active\": true }, \"blendMode\": \"Multiply\" }",
        "layer.delete": "{ \"layer\": { \"active\": true } }",
        "selection.all": "{}",
        "selection.deselect": "{}",
        "selection.invert": "{}",
        "selection.rect": "{ \"x\": 0, \"y\": 0, \"width\": 10, \"height\": 10 }",
        "selection.ellipse": "{ \"x\": 0, \"y\": 0, \"width\": 10, \"height\": 10, \"mode\": \"add\" }",
        "selection.expand": "{ \"amount\": 4 }",
        "selection.contract": "{ \"amount\": 4 }",
        "selection.feather": "{ \"amount\": 4 }"
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

    /// The catalog's flag is what the model reads; `EditCommand.mutatesDocument` is what decides
    /// whether a call is proposed for approval. They must agree.
    @MainActor @Test func catalogMutationFlagMatchesTheCommand() throws {
        for descriptor in EditCommandCatalog.commands {
            let arguments = try #require(Self.implementedCommands[descriptor.name])
            let command = try EditCommandRunner.decode(command: descriptor.name, argumentsJSON: arguments).get()
            #expect(command.mutatesDocument == descriptor.mutatesDocument, "\(descriptor.name)")
            #expect(command.name == descriptor.name)
        }
    }
}
