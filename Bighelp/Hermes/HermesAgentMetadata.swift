import Foundation

@MainActor
protocol HermesAgentMetadataStoring: AnyObject {
    func profiles() throws -> [AgentProfile]
    func profile(id: String) throws -> AgentProfile?
    func save(_ profile: AgentProfile) throws
    func saveCanonicalBaseline(_ profile: AgentProfile) throws
    func replaceAll(_ profiles: [AgentProfile]) throws
}
