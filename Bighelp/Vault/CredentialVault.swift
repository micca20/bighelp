import Foundation
import Observation

/// Hermes' credential vault (`vault.*` on the host socket): logins, cards and
/// addresses an agent's browser tools fill without ever seeing the secret.
/// The vault lives on the person's computer, one per agent. bighelp only
/// passes a new item through once and never stores or reads back a secret.
@MainActor
protocol CredentialVaultService: AnyObject {
    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue
}

/// One saved item as Hermes lists it: a label and where it's used, never the
/// password, card number or address itself.
struct CredentialVaultItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case login, payment, address

        var symbol: String {
            switch self {
            case .login: "key"
            case .payment: "creditcard"
            case .address: "house"
            }
        }
    }

    let id: String
    let kind: Kind
    let label: String
    let origin: String?
    let identifier: String?
    /// "local" for Hermes' own vault, otherwise the password manager it came from.
    let source: String
    let generatesCodes: Bool

    var isLocal: Bool { source == "local" }

    init?(_ value: BighelpJSONValue) {
        guard let object = value.object,
              let id = CredentialVault.text(object["id"], maximumBytes: 256), !id.isEmpty,
              let kind = object["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let label = CredentialVault.text(object["label"], maximumBytes: 512),
              let source = CredentialVault.text(object["backend"], maximumBytes: 64), !source.isEmpty else { return nil }
        self.id = id
        self.kind = kind
        self.label = label
        origin = CredentialVault.text(object["origin"], maximumBytes: 2_048).flatMap { $0.isEmpty ? nil : $0 }
        identifier = CredentialVault.text(object["identifier"], maximumBytes: 512).flatMap { $0.isEmpty ? nil : $0 }
        self.source = source
        generatesCodes = object["has_otp"]?.boolean == true
    }
}

/// A password manager Hermes can read logins from (1Password, Bitwarden, …).
struct CredentialVaultSource: Identifiable, Equatable, Sendable {
    let name: String
    let displayName: String
    let enabled: Bool
    let unlocked: Bool
    let installed: Bool

    var id: String { name }

    init?(_ value: BighelpJSONValue) {
        guard let object = value.object,
              let name = CredentialVault.text(object["name"], maximumBytes: 64), !name.isEmpty,
              let displayName = CredentialVault.text(object["display_name"], maximumBytes: 120) else { return nil }
        self.name = name
        self.displayName = displayName.isEmpty ? name : displayName
        enabled = object["enabled"]?.boolean == true
        unlocked = object["unlocked"]?.boolean == true
        installed = object["installed"]?.boolean == true
    }
}

/// A new item, typed on this device. Its secrets exist only in this value
/// until it's sent once.
enum CredentialVaultEntry {
    case login(site: String, identifier: String, password: String, authenticatorKey: String)
    case card(name: String, number: String, month: String, year: String, securityCode: String, postalCode: String)
    case address(label: String, line1: String, line2: String, city: String, state: String,
                 postalCode: String, country: String)
}

enum CredentialVault {
    /// `scheme://host[:port]` for what someone typed ("example.com",
    /// "https://example.com/login"), or nil when it isn't a web address.
    static func origin(from typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 2_048, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let parts = URLComponents(string: withScheme),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host?.lowercased(), host.contains(".") || host == "localhost",
              parts.user == nil, parts.password == nil else { return nil }
        return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
    }

    /// What Hermes stores for a new item, or a plain reason it can't be saved.
    static func request(for entry: CredentialVaultEntry) -> Result<[String: BighelpJSONValue], EntryProblem> {
        func field(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch entry {
        case .login(let site, let identifier, let password, let authenticatorKey):
            guard let origin = origin(from: site) else { return .failure(.site) }
            let name = field(identifier)
            guard !name.isEmpty, name.utf8.count <= 512 else { return .failure(.identifier) }
            guard !password.isEmpty, password.utf8.count <= 4_096 else { return .failure(.password) }
            let type = name.contains("@") ? "email"
                : name.drop(while: { $0 == "+" }).allSatisfy(\.isNumber) ? "phone" : "username"
            var secret: [String: BighelpJSONValue] = [
                "identifier_type": .string(type), "identifier": .string(name), "password": .string(password),
            ]
            let key = field(authenticatorKey)
            if !key.isEmpty {
                guard key.utf8.count <= 2_048 else { return .failure(.authenticatorKey) }
                secret["otp_secret"] = .string(key)
            }
            let host = URLComponents(string: origin)?.host ?? origin
            return .success(["kind": .string("login"), "label": .string(host), "origin": .string(origin),
                             "secret": .object(secret)])
        case .card(let name, let number, let month, let year, let securityCode, let postalCode):
            let digits = number.filter(\.isNumber)
            guard (12...19).contains(digits.count), digits.count == number.filter({ !$0.isWhitespace && $0 != "-" }).count
            else { return .failure(.cardNumber) }
            guard let monthValue = Int(field(month)), (1...12).contains(monthValue) else { return .failure(.expiry) }
            var yearValue = Int(field(year)) ?? 0
            if (0...99).contains(yearValue) { yearValue += 2000 }
            guard (2000...2100).contains(yearValue) else { return .failure(.expiry) }
            let code = field(securityCode)
            guard (3...4).contains(code.count), code.allSatisfy(\.isNumber) else { return .failure(.securityCode) }
            var secret: [String: BighelpJSONValue] = [
                "card_number": .string(digits), "exp_month": .string(String(format: "%02d", monthValue)),
                "exp_year": .string(String(yearValue)), "cvc": .string(code),
            ]
            if !field(name).isEmpty { secret["cardholder_name"] = .string(String(field(name).prefix(200))) }
            if !field(postalCode).isEmpty { secret["billing_postal_code"] = .string(String(field(postalCode).prefix(20))) }
            return .success(["kind": .string("payment"), "label": .string("Card ending \(digits.suffix(4))"),
                             "secret": .object(secret)])
        case .address(let label, let line1, let line2, let city, let state, let postalCode, let country):
            let required = [field(line1), field(city), field(postalCode), field(country)]
            guard required.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 300 }) else { return .failure(.address) }
            var secret: [String: BighelpJSONValue] = [
                "address_line1": .string(required[0]), "city": .string(required[1]),
                "postal_code": .string(required[2]), "country": .string(required[3]),
            ]
            if !field(line2).isEmpty { secret["address_line2"] = .string(String(field(line2).prefix(300))) }
            if !field(state).isEmpty { secret["state"] = .string(String(field(state).prefix(100))) }
            let name = field(label).isEmpty ? "Address" : String(field(label).prefix(120))
            return .success(["kind": .string("address"), "label": .string(name), "secret": .object(secret)])
        }
    }

    enum EntryProblem: Error, Equatable {
        case site, identifier, password, authenticatorKey, cardNumber, expiry, securityCode, address

        var message: String {
            switch self {
            case .site: "Enter the site's address, like example.com."
            case .identifier: "Enter the email or username you sign in with."
            case .password: "Enter the password."
            case .authenticatorKey: "That authenticator key is too long."
            case .cardNumber: "Enter the card number."
            case .expiry: "Enter the expiry month and year."
            case .securityCode: "Enter the 3 or 4 digit security code."
            case .address: "Enter the street, city, postal code and country."
            }
        }
    }

    static func text(_ value: BighelpJSONValue?, maximumBytes: Int) -> String? {
        guard let value, value != .null else { return "" }
        guard let text = value.string, text.utf8.count <= maximumBytes,
              !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return text
    }
}

/// The vault screen's state for one agent on the selected host.
@MainActor
@Observable
final class CredentialVaultModel: Identifiable {
    enum State: Equatable {
        case loading, ready, unsupported, failed
    }

    struct Agent: Identifiable, Equatable {
        let id: String
        let name: String
    }

    let id = UUID()
    let agents: [Agent]
    private(set) var agentID: String
    private(set) var items: [CredentialVaultItem] = []
    private(set) var sources: [CredentialVaultSource] = []
    private(set) var state = State.loading
    private(set) var isWorking = false
    var message: String?
    @ObservationIgnored private let service: any CredentialVaultService

    init(service: any CredentialVaultService, agents: [Agent], agentID: String) {
        self.service = service
        self.agents = agents
        self.agentID = agents.contains { $0.id == agentID } ? agentID : agents.first?.id ?? "default"
    }

    var agentName: String { agents.first { $0.id == agentID }?.name ?? agentID }
    /// Password managers found on the computer; the Hermes vault itself is always on.
    var managers: [CredentialVaultSource] { sources.filter { $0.name != "local" && $0.installed } }

    func select(agentID: String) async {
        guard agentID != self.agentID, agents.contains(where: { $0.id == agentID }) else { return }
        self.agentID = agentID
        items = []
        sources = []
        await load()
    }

    func load() async {
        if items.isEmpty && sources.isEmpty { state = .loading }
        let agent = agentID
        do {
            let listed = try await service.call("vault.list", params: profile)
            let found = try await service.call("vault.sources", params: profile)
            guard agent == agentID else { return }
            items = (listed.object?["items"]?.array ?? []).prefix(500).compactMap(CredentialVaultItem.init)
                .sorted { ($0.isLocal ? 0 : 1, $0.label.lowercased()) < ($1.isLocal ? 0 : 1, $1.label.lowercased()) }
            sources = (found.object?["sources"]?.array ?? []).prefix(32).compactMap(CredentialVaultSource.init)
            state = .ready
        } catch {
            guard agent == agentID else { return }
            state = Self.isUnsupported(error) ? .unsupported : .failed
        }
    }

    /// Sends a new item once. Returns whether Hermes saved it.
    func save(_ entry: CredentialVaultEntry) async -> Bool {
        guard !isWorking else { return false }
        let request: [String: BighelpJSONValue]
        switch CredentialVault.request(for: entry) {
        case .success(let value): request = value
        case .failure(let problem):
            message = problem.message
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.call("vault.add", params: profile.merging(request) { _, new in new })
            message = nil
            await load()
            return true
        } catch {
            message = Self.isUnsupported(error)
                ? "This needs a newer Hermes on your computer."
                : "Hermes couldn't save that. Check the details and try again."
            return false
        }
    }

    private(set) var importProgress: (done: Int, total: Int)?

    /// Saves imported logins one by one. A login whose authenticator key Hermes
    /// refuses is saved without it rather than dropped.
    func importLogins(_ logins: [CredentialVaultImport.Login]) async -> (imported: Int, failed: Int) {
        guard !isWorking, !logins.isEmpty else { return (0, 0) }
        isWorking = true
        defer { isWorking = false; importProgress = nil }
        var imported = 0
        var failed = 0
        importProgress = (0, logins.count)
        for login in logins {
            var keys = [login.authenticatorKey]
            if !login.authenticatorKey.isEmpty { keys.append("") }
            var saved = false
            for key in keys where !saved {
                guard case .success(let request) = CredentialVault.request(for: .login(site: login.origin,
                    identifier: login.identifier, password: login.password, authenticatorKey: key)) else { continue }
                saved = (try? await service.call("vault.add", params: profile.merging(request) { _, new in new })) != nil
            }
            if saved { imported += 1 } else { failed += 1 }
            importProgress = (imported + failed, logins.count)
        }
        message = nil
        await load()
        return (imported, failed)
    }

    func remove(_ item: CredentialVaultItem) async {
        guard item.isLocal, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.call("vault.remove", params: profile.merging(["id": .string(item.id)]) { _, new in new })
            items.removeAll { $0.id == item.id }
        } catch {
            message = "Hermes couldn't remove that. Try again."
        }
    }

    func setEnabled(_ source: CredentialVaultSource, _ enabled: Bool) async {
        await run("vault.source.set", ["name": .string(source.name), "enabled": .boolean(enabled)],
                  failure: "Hermes couldn't change \(source.displayName). Try again.")
    }

    /// The master password goes to the manager on the computer once and is dropped.
    func unlock(_ source: CredentialVaultSource, password: String) async -> Bool {
        guard !password.isEmpty, password.utf8.count <= 4_096 else { return false }
        return await run("vault.unlock", ["name": .string(source.name), "password": .string(password)],
                         failure: "That didn't unlock \(source.displayName). Check the master password.")
    }

    func lock(_ source: CredentialVaultSource) async {
        await run("vault.lock", ["name": .string(source.name)], failure: "Hermes couldn't lock \(source.displayName).")
    }

    @discardableResult
    private func run(_ method: String, _ params: [String: BighelpJSONValue], failure: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await service.call(method, params: profile.merging(params) { _, new in new })
            message = nil
            await load()
            return true
        } catch {
            message = failure
            return false
        }
    }

    private var profile: [String: BighelpJSONValue] { ["profile": .string(agentID)] }

    private static func isUnsupported(_ error: any Error) -> Bool {
        if case DirectHermesError.rpcRejected(code: -32601)? = error as? DirectHermesError { return true }
        return false
    }
}

/// The selected host's own vault, over its authenticated socket.
@MainActor
final class DirectHermesCredentialVaultService: CredentialVaultService {
    private let workspace: DirectHermesWorkspaceStore

    init(workspace: DirectHermesWorkspaceStore) { self.workspace = workspace }

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        try await workspace.vaultRequest(method, params: params)
    }
}

/// Demo mode: made-up items in memory, never a real secret.
@MainActor
final class DemoCredentialVaultService: CredentialVaultService {
    private var items: [BighelpJSONValue] = [
        .object(["id": .string("demo-login"), "kind": .string("login"), "label": .string("example.com"),
                 "origin": .string("https://example.com"), "identifier": .string("sam@example.com"),
                 "backend": .string("local"), "has_otp": .boolean(true)]),
        .object(["id": .string("demo-address"), "kind": .string("address"), "label": .string("Home"),
                 "backend": .string("local")]),
    ]
    private var managerUnlocked = false
    private var managerEnabled = true

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        switch method {
        case "vault.list":
            let manager: [BighelpJSONValue] = managerUnlocked && managerEnabled ? [
                .object(["id": .string("demo-manager"), "kind": .string("login"), "label": .string("shop.example.org"),
                         "origin": .string("https://shop.example.org"), "identifier": .string("sam"),
                         "backend": .string("onepassword")]),
            ] : []
            return .object(["items": .array(items + manager)])
        case "vault.sources":
            return .object(["sources": .array([
                .object(["name": .string("local"), "display_name": .string("Hermes vault"), "enabled": .boolean(true),
                         "needs_unlock": .boolean(false), "unlocked": .boolean(true), "installed": .boolean(true)]),
                .object(["name": .string("onepassword"), "display_name": .string("1Password"),
                         "enabled": .boolean(managerEnabled), "needs_unlock": .boolean(true),
                         "unlocked": .boolean(managerUnlocked), "installed": .boolean(true)]),
                .object(["name": .string("bitwarden"), "display_name": .string("Bitwarden"), "enabled": .boolean(false),
                         "needs_unlock": .boolean(true), "unlocked": .boolean(false), "installed": .boolean(false)]),
            ])])
        case "vault.add":
            let id = "demo-" + UUID().uuidString.prefix(8).lowercased()
            var item: [String: BighelpJSONValue] = ["id": .string(id), "kind": params["kind"] ?? .string("login"),
                "label": params["label"] ?? .string("Item"), "backend": .string("local")]
            if let origin = params["origin"] { item["origin"] = origin }
            if let secret = params["secret"]?.object {
                item["identifier"] = secret["identifier"]
                item["has_otp"] = .boolean(secret["otp_secret"] != nil)
            }
            items.append(.object(item))
            return .object(["id": .string(id)])
        case "vault.remove":
            let id = params["id"]?.string
            items.removeAll { $0.object?["id"]?.string == id }
            return .object(["removed": .boolean(true)])
        case "vault.source.set":
            managerEnabled = params["enabled"]?.boolean == true
            if !managerEnabled { managerUnlocked = false }
            return .object(["name": params["name"] ?? .null, "enabled": .boolean(managerEnabled)])
        case "vault.unlock":
            managerUnlocked = true
            return .object(["name": params["name"] ?? .null, "unlocked": .boolean(true)])
        case "vault.lock":
            managerUnlocked = false
            return .object(["locked": .boolean(true)])
        default:
            throw DirectHermesError.rpcRejected(code: -32601)
        }
    }
}
