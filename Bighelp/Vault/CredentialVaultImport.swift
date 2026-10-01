import Foundation

/// Logins read from a password manager's CSV export (Apple Passwords, Chrome,
/// 1Password, Bitwarden, LastPass, Firefox, Proton Pass, Dashlane, KeePassXC).
/// The file is read in memory on this device; nothing from it is kept after
/// the import, and only sites and usernames are ever shown.
struct CredentialVaultImport {
    struct Login: Identifiable, Equatable {
        let id: Int
        let origin: String
        let identifier: String
        let password: String
        let authenticatorKey: String

        var site: String { URLComponents(string: origin)?.host ?? origin }
    }

    enum Problem: Error, Equatable {
        case tooLarge, notText, noColumns

        var message: String {
            switch self {
            case .tooLarge: "That file is too large. Export only logins, then try again."
            case .notText: "That file isn't a CSV export. Export your logins as CSV, then try again."
            case .noColumns: "That file has no website, username and password columns. Export your logins as CSV, then try again."
            }
        }
    }

    static let maximumBytes = 5 * 1_024 * 1_024
    static let maximumRows = 5_000

    let logins: [Login]
    /// Rows without a website, username or password, or repeated in the file.
    let skipped: Int

    /// Rows already in the vault for the same site and username aren't sent again.
    func excluding(_ items: [CredentialVaultItem]) -> (logins: [Login], alreadySaved: Int) {
        let saved = Set(items.filter { $0.kind == .login }.compactMap { item in
            item.origin.map { Self.key($0, item.identifier ?? "") }
        })
        let fresh = logins.filter { !saved.contains(Self.key($0.origin, $0.identifier)) }
        return (fresh, logins.count - fresh.count)
    }

    static func read(_ data: Data) throws(Problem) -> CredentialVaultImport {
        guard data.count <= maximumBytes else { throw .tooLarge }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { throw .notText }
        let rows = parse(text)
        guard let header = rows.first else { throw .noColumns }
        let columns = Columns(header)
        guard columns.site != nil, columns.password != nil, columns.username != nil || columns.email != nil else {
            throw .noColumns
        }
        var logins: [Login] = []
        var seen = Set<String>()
        var skipped = 0
        for row in rows.dropFirst().prefix(maximumRows) where !row.allSatisfy({ $0.isEmpty }) {
            func value(_ index: Int?) -> String {
                guard let index, index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let type = columns.type, !["", "login", "1"].contains(value(type).lowercased()) { skipped += 1; continue }
            let identifier = value(columns.username).isEmpty ? value(columns.email) : value(columns.username)
            // Passwords keep their exact characters, spaces included.
            let password = columns.password.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
            // Bitwarden lists every address of a login in one cell; the first site wins.
            let sites = value(columns.site).split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            guard let origin = sites.lazy.compactMap({ CredentialVault.origin(from: String($0)) }).first,
                  !identifier.isEmpty, identifier.utf8.count <= 512,
                  !password.isEmpty, password.utf8.count <= 4_096,
                  seen.insert(key(origin, identifier)).inserted else {
                skipped += 1
                continue
            }
            let otp = value(columns.authenticator)
            logins.append(Login(id: logins.count, origin: origin, identifier: identifier, password: password,
                                authenticatorKey: otp.utf8.count <= 2_048 ? otp : ""))
        }
        skipped += max(0, rows.count - 1 - maximumRows)
        return CredentialVaultImport(logins: logins, skipped: skipped)
    }

    private static func key(_ origin: String, _ identifier: String) -> String {
        origin.lowercased() + "\u{1f}" + identifier.lowercased()
    }

    /// Which column holds what, from the export's own header names.
    private struct Columns {
        var site: Int?, username: Int?, email: Int?, password: Int?, authenticator: Int?, type: Int?

        init(_ header: [String]) {
            for (index, raw) in header.enumerated() {
                let name = raw.lowercased().filter { $0.isLetter || $0.isNumber }
                switch name {
                case "url", "loginuri", "website", "site", "uri", "address", "loginurl", "weburl", "hostname", "origin":
                    site = site ?? index
                case "username", "loginusername", "user", "login", "loginname", "accountname":
                    username = username ?? index
                case "email", "emailaddress", "username2":
                    email = email ?? index
                case "password", "loginpassword", "pass":
                    password = password ?? index
                case "otpauth", "otp", "totp", "logintotp", "otpsecret", "otpurl", "twofactorsecret", "authenticatorkey":
                    authenticator = authenticator ?? index
                case "type":
                    type = type ?? index
                default:
                    break
                }
            }
        }
    }

    /// RFC 4180: quoted fields may hold commas, quotes ("") and line breaks.
    /// A header with semicolons and no commas uses semicolons.
    static func parse(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let separator: Character = !firstLine.contains(",") && firstLine.contains(";") ? ";" : ","
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    let next = iterator.next()
                    if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"" where field.isEmpty:
                quoted = true
            case separator:
                row.append(field)
                field = ""
            case "\n", "\r", "\r\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { $0 != [""] }
    }
}

#if DEBUG
extension CredentialVaultImport {
    /// `-test-vault-import`: a made-up export instead of the file picker, for tests.
    static var testFixture: Data? {
        guard ProcessInfo.processInfo.arguments.contains("-test-vault-import") else { return nil }
        return Data("""
        Title,URL,Username,Password,Notes,OTPAuth
        Example News,https://news.example.net/login,sam,made-up-pass-1,,
        "Shop, Inc.",shop.example.org,sam@example.com,"made-up ""pass"" 2",a note,
        Wi-Fi,,,,router note,
        Example,https://example.com,sam@example.com,made-up-pass-3,,
        """.utf8)
    }
}
#endif
