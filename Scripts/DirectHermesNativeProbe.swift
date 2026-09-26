import Foundation

@MainActor private final class ProbeVault: DirectHermesCredentialVault {
    var value: DirectHermesSavedConnection?
    func load() throws -> DirectHermesSavedConnection? { value }
    func save(_ connection: DirectHermesSavedConnection) throws { value = connection }
    func delete() throws { value = nil }
}

@main
struct DirectHermesNativeProbe {
    @MainActor static func main() async {
        do {
            guard let path = ProcessInfo.processInfo.environment["DIRECT_PROBE_CONFIG"] else {
                throw DirectHermesError.invalidResponse
            }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let input = try JSONDecoder().decode([String: String].self, from: handle.readToEnd() ?? Data())
            guard let address = input["address"], let username = input["username"], let password = input["password"] else {
                throw DirectHermesError.invalidResponse
            }
            let vault = ProbeVault()
            var denied = false
            do {
                let wrong = try await DirectHermesClient.connect(address: address,
                    auth: .password(username: username, password: UUID().uuidString), allowPrivateHTTP: true, vault: vault)
                await wrong.disconnect()
            } catch DirectHermesError.invalidCredentials { denied = true }
            guard denied else { throw DirectHermesError.invalidResponse }
            let client = try await DirectHermesClient.connect(address: address,
                auth: .password(username: username, password: password), allowPrivateHTTP: true, vault: vault)
            try vault.save(client.savedConnection)
            var kinds: [String] = []
            var text = ""
            var settled = false
            client.onEvent = { event in
                kinds.append(event.type)
                if event.type == "message.delta" { text += event.payload["text"]?.string ?? "" }
                if event.type == "message.complete" { text = event.payload["text"]?.string ?? text }
                if event.type == "session.info", event.payload["running"]?.boolean == false { settled = true }
            }
            let profiles = try await client.request("profiles.list", params: ["include_sessions": .boolean(false)])
            guard profiles.object?["profiles"]?.array?.isEmpty == false else { throw DirectHermesError.invalidResponse }
            let session = try await client.request("session.create", params: ["profile": .string("default"), "source": .string("desktop")])
            guard let sid = session.object?["session_id"]?.string else { throw DirectHermesError.invalidResponse }
            settled = false
            let result = try await client.request("prompt.submit", params: ["session_id": .string(sid), "text": .string("Run pwd once, then finish the direct streaming fixture.")])
            guard result.object?["status"]?.string == "streaming" else { throw DirectHermesError.invalidResponse }
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while !settled && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard settled, kinds.contains("tool.start"), kinds.contains("tool.complete"), kinds.contains("message.delta"),
                  text == "Direct streaming fixture complete." else { throw DirectHermesError.invalidResponse }
            let history = try await client.request("session.history", params: ["session_id": .string(sid)])
            guard history.object?["messages"]?.array?.isEmpty == false else { throw DirectHermesError.invalidResponse }
            let saved = client.savedConnection
            await client.disconnect()
            let restored = try await DirectHermesClient.restore(saved, vault: vault)
            let status = try await restored.request("session.activate", params: ["session_id": .string(sid)])
            guard status.object?["session_id"]?.string == sid else { throw DirectHermesError.invalidResponse }
            await restored.disconnect()
            let receipt: [String: LoopdyJSONValue] = ["outcome": .string("passed"), "native_password_auth": .boolean(true),
                "wrong_password_rejected": .boolean(denied), "native_streaming_and_real_tool": .boolean(true),
                "reconnect_without_resend": .boolean(true), "event_types": .array(Set(kinds).sorted().map(LoopdyJSONValue.string))]
            print(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))
        } catch {
            let safe = DirectHermesHTTP.safeError(error)
            print("Native probe failed: \(safe.localizedDescription)")
            exit(1)
        }
    }
}
