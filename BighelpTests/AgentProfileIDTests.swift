import Foundation
import Testing
@testable import Bighelp

struct AgentProfileIDTests {
    @Test func displayNamesProduceValidLowercaseHostIDs() throws {
        for name in ["My AGENT", "MiXeD Bot 🎸", "Élodie", "東京", "🌱", String(repeating: "ABC ", count: 100)] {
            let id = AgentProfileID.generated(from: name)
            #expect(id.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil)
        }
        #expect(AgentProfileID.generated(from: "My AGENT") == "my-agent")
        #expect(AgentProfileID.generated(from: "Élodie") == "elodie")
        #expect(AgentProfileID.generated(from: "🌱") == "agent")
    }

    @Test func reservedNamesAndCaseCollisionsDoNotReuseExistingIDs() {
        #expect(AgentProfileID.generated(from: "DEFAULT") == "default-2")
        #expect(AgentProfileID.generated(from: "Hermes") == "hermes-2")
        let existing: Set<String> = ["NOVA", "nova-2"]
        #expect(AgentProfileID.generated(from: "Nova", occupied: existing) == "nova-3")
        #expect(existing == ["NOVA", "nova-2"])
    }
}
