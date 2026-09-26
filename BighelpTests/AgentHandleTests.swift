import Foundation
import Testing
@testable import Bighelp

struct AgentHandleTests {
    @Test func collisionSafeHandlesDoNotChangeIdentity() {
        let profiles = [
            AgentProfile.fixture(id: "one", name: "Research"),
            AgentProfile.fixture(id: "two", name: "Research")
        ]

        #expect(AgentHandle.directory(for: profiles).map(\.handle) == ["research", "research-2"])
        #expect(profiles.map(\.id) == ["one", "two"])
    }

    @Test func uniqueHandleSkipsExistingSuffixes() {
        let profiles = [
            AgentProfile.fixture(id: "one", name: "Research"),
            AgentProfile.fixture(id: "two", name: "Research 2")
        ]

        #expect(AgentHandle.unique(base: "Research", excluding: nil, profiles: profiles) == "research-3")
    }

    @Test func localeSensitiveNamesUseFixedPOSIXHandleSemantics() {
        let turkish = Locale(identifier: "tr_TR")

        #expect(AgentHandle.normalized("Istanbul", locale: turkish) == "ıstanbul")
        #expect(AgentHandle.unique(base: "Istanbul", excluding: nil, profiles: []) == "istanbul")
    }
}

private extension AgentProfile {
    static func fixture(id: String, name: String) -> AgentProfile {
        AgentProfile(
            id: id,
            name: name,
            role: "Specialist",
            summary: "Fixture profile",
            instructions: "Help carefully.",
            avatarFileName: nil,
            isDefault: false
        )
    }
}
