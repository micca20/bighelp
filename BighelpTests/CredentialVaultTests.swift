import Foundation
import Testing
@testable import Bighelp

@MainActor
struct CredentialVaultTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("https://Example.com/login?next=1", "https://example.com"),
        ("http://192.168.1.20:8080/admin", "http://192.168.1.20:8080"),
        (" shop.example.org ", "https://shop.example.org"),
    ])
    func aTypedSiteBecomesItsOrigin(typed: String, origin: String) {
        #expect(CredentialVault.origin(from: typed) == origin)
    }

    @Test(arguments: ["", "not a site", "javascript:alert(1)", "ftp://example.com", "https://user:pw@example.com", "localhost.x y"])
    func somethingThatIsntASiteIsRefused(typed: String) {
        #expect(CredentialVault.origin(from: typed) == nil)
    }

    @Test func aLoginIsSentTheWayHermesStoresIt() throws {
        let request = try CredentialVault.request(for: .login(site: "example.com/login", identifier: " sam@example.com ",
            password: "made-up-pass", authenticatorKey: "JBSWY3DPEHPK3PXP")).get()
        #expect(request["kind"] == .string("login"))
        #expect(request["label"] == .string("example.com"))
        #expect(request["origin"] == .string("https://example.com"))
        #expect(request["secret"] == .object(["identifier_type": .string("email"), "identifier": .string("sam@example.com"),
                                             "password": .string("made-up-pass"), "otp_secret": .string("JBSWY3DPEHPK3PXP")]))
    }

    @Test func aCardKeepsOnlyItsLastDigitsInTheLabel() throws {
        let request = try CredentialVault.request(for: .card(name: "Sam Example", number: "4242 4242 4242 4242",
            month: "3", year: "29", securityCode: "123", postalCode: "")).get()
        #expect(request["label"] == .string("Card ending 4242"))
        #expect(request["secret"]?.object?["card_number"] == .string("4242424242424242"))
        #expect(request["secret"]?.object?["exp_month"] == .string("03"))
        #expect(request["secret"]?.object?["exp_year"] == .string("2029"))
        #expect(request["secret"]?.object?["billing_postal_code"] == nil)
    }

    @Test func incompleteItemsSayWhatsMissing() {
        #expect(CredentialVault.request(for: .login(site: "example.com", identifier: "", password: "x",
                                                    authenticatorKey: "")).failure == .identifier)
        #expect(CredentialVault.request(for: .card(name: "", number: "4242", month: "1", year: "2030",
                                                   securityCode: "123", postalCode: "")).failure == .cardNumber)
        #expect(CredentialVault.request(for: .address(label: "Home", line1: "1 Main St", line2: "", city: "",
            state: "", postalCode: "00000", country: "US")).failure == .address)
    }

    @Test func savingAddsTheItemForTheChosenAgentAndListsIt() async {
        let service = RecordingVault()
        let model = CredentialVaultModel(service: service, agents: [.init(id: "default", name: "Default"),
                                                                    .init(id: "juniper", name: "Juniper")],
                                         agentID: "juniper")
        await model.load()
        #expect(model.state == .ready)
        let saved = await model.save(.login(site: "example.com", identifier: "sam", password: "made-up-pass",
                                            authenticatorKey: ""))
        #expect(saved)
        #expect(model.items.map(\.label).contains("example.com"))
        #expect(model.items.first { $0.label == "example.com" && $0.identifier == "sam" }?.generatesCodes == false)
        let add = service.calls.first { $0.method == "vault.add" }
        #expect(add?.params["profile"] == .string("juniper"))
        #expect(add?.params["secret"]?.object?["password"] == .string("made-up-pass"))
        #expect(model.message == nil)
    }

    @Test func anOlderHermesSaysToUpdate() async {
        let model = CredentialVaultModel(service: OlderHermes(), agents: [.init(id: "default", name: "Default")],
                                         agentID: "default")
        await model.load()
        #expect(model.state == .unsupported)
    }

    @Test func managersFromOtherSourcesCantBeRemovedHere() async {
        let model = CredentialVaultModel(service: DemoCredentialVaultService(),
                                         agents: [.init(id: "default", name: "Default")], agentID: "default")
        await model.load()
        let manager = try? #require(model.managers.first { $0.name == "onepassword" })
        #expect(manager?.unlocked == false)
        if let manager { #expect(await model.unlock(manager, password: "made-up-master")) }
        let borrowed = model.items.first { !$0.isLocal }
        #expect(borrowed?.source == "onepassword")
        if let borrowed { await model.remove(borrowed) }
        #expect(model.items.contains { $0.id == borrowed?.id })
        #expect(!model.managers.contains { $0.name == "bitwarden" }, "Managers that aren't installed stay hidden")
    }
}

@MainActor
struct CredentialVaultImportTests {
    @Test(arguments: [
        ("Apple Passwords", "Title,URL,Username,Password,Notes,OTPAuth\nNews,https://news.example.net/login,sam,pw1,,otpauth://totp/x?secret=JBSWY3DPEHPK3PXP"),
        ("Chrome", "name,url,username,password,note\nnews.example.net,https://news.example.net/,sam,pw1,"),
        ("Firefox", "\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://news.example.net\",\"sam\",\"pw1\",\"\""),
        ("1Password", "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\nNews,news.example.net,sam,pw1,,false,false,,"),
        ("Bitwarden", "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,News,,,0,\"https://news.example.net,https://m.example.net\",sam,pw1,\n,,note,Secret note,text,,0,,,,"),
        ("LastPass", "url,username,password,totp,extra,name,grouping,fav\nhttps://news.example.net,sam,pw1,,,News,,0\nhttp://sn,,,,note,Note,,0"),
        ("Proton Pass", "name,url,email,username,password,note,totp,createTime,modifyTime,vault\nNews,https://news.example.net,sam@example.com,sam,pw1,,,1,1,Personal"),
        ("KeePassXC", "\"Group\",\"Title\",\"Username\",\"Password\",\"URL\",\"Notes\",\"TOTP\"\n\"Root\",\"News\",\"sam\",\"pw1\",\"https://news.example.net\",\"\",\"\""),
    ])
    func commonExportsGiveTheSameLogin(source: String, csv: String) throws {
        let file = try CredentialVaultImport.read(Data(csv.utf8))
        #expect(file.logins.count == 1, "\(source)")
        #expect(file.logins.first?.origin == "https://news.example.net", "\(source)")
        #expect(file.logins.first?.identifier == "sam", "\(source)")
        #expect(file.logins.first?.password == "pw1", "\(source)")
    }

    @Test func quotedFieldsKeepCommasQuotesAndLineBreaks() throws {
        let csv = "\u{FEFF}url,username,password\r\nshop.example.org,sam,\"made-up, \"\"pass\"\"\nline 2\"\r\n"
        let file = try CredentialVaultImport.read(Data(csv.utf8))
        #expect(file.logins.first?.password == "made-up, \"pass\"\nline 2")
        #expect(file.logins.first?.origin == "https://shop.example.org")
    }

    @Test func rowsWithoutASiteUsernameOrPasswordAndRepeatsAreSkipped() throws {
        let csv = "url,username,password\n,sam,pw\nexample.com,,pw\nexample.com,sam,\nexample.com,sam,pw\nEXAMPLE.com,Sam,pw2"
        let file = try CredentialVaultImport.read(Data(csv.utf8))
        #expect(file.logins.count == 1)
        #expect(file.skipped == 4)
    }

    @Test func somethingThatIsntAnExportSaysSo() {
        #expect(throws: CredentialVaultImport.Problem.noColumns) {
            try CredentialVaultImport.read(Data("name,notes\nWi-Fi,router".utf8))
        }
        #expect(throws: CredentialVaultImport.Problem.tooLarge) {
            try CredentialVaultImport.read(Data(count: CredentialVaultImport.maximumBytes + 1))
        }
    }

    @Test func loginsAlreadyInTheVaultArentSentAgainAndTheRestAreSaved() async throws {
        let service = RecordingVault()
        let model = CredentialVaultModel(service: service, agents: [.init(id: "default", name: "Default")],
                                         agentID: "default")
        await model.load()
        let file = try CredentialVaultImport.read(Data("""
        url,username,password,totp
        https://example.com,sam@example.com,pw0,
        https://news.example.net,sam,pw1,not-a-real-key
        """.utf8))
        let pending = file.excluding(model.items)
        #expect(pending.alreadySaved == 1)
        let result = await model.importLogins(pending.logins)
        #expect(result.imported == 1 && result.failed == 0)
        #expect(model.items.contains { $0.label == "news.example.net" })
        #expect(service.calls.filter { $0.method == "vault.add" }.count == 1)
    }
}

@MainActor
private final class RecordingVault: CredentialVaultService {
    let demo = DemoCredentialVaultService()
    var calls: [(method: String, params: [String: BighelpJSONValue])] = []

    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        calls.append((method, params))
        return try await demo.call(method, params: params)
    }
}

@MainActor
private final class OlderHermes: CredentialVaultService {
    func call(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        throw DirectHermesError.rpcRejected(code: -32601)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}
