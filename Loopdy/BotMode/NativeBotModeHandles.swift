import Foundation

enum NativeBotModeHandles {
    static func preferred(profileID: String, name: String) -> String {
        let normalizedName = AgentHandle.normalized(name)
        let candidate = HermesBotModeWireCodec.identifier(normalizedName)
            ? normalizedName : AgentHandle.normalized(profileID)
        let bounded = String(candidate.prefix(120))
        let base = HermesBotModeWireCodec.identifier(bounded) ? bounded : "agent"
        return ["all", "everyone"].contains(base) ? "\(base)-agent" : base
    }

    static func directory(for profiles: [AgentProfile]) -> [AgentHandle] {
        var assigned: Set<String> = []
        return profiles.map { profile in
            let base = preferred(profileID: profile.id, name: profile.name)
            var handle = base
            var suffix = 2
            while assigned.contains(handle) {
                handle = "\(base)-\(suffix)"
                suffix += 1
            }
            assigned.insert(handle)
            return AgentHandle(profileID: profile.id, handle: handle)
        }
    }
}
