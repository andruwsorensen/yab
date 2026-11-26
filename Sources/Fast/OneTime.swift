import YabStore
import Foundation
import CryptoKit
import Security

// Two-factor codes: the six digits a site asks for after the password, made
// here instead of in a separate app. A site gives you a setup key once, as a
// QR code, an otpauth:// link, or the key written out, and every code after
// that is arithmetic on it and the time (RFC 6238).
//
// The key is kept next to the passwords, in the keychain, one generic item
// per login. Like the passwords, it never goes into a page: the page asks for
// the current code and gets six digits.

enum OneTime {
    struct Setup {
        var secret: Data
        var digits = 6
        var period = 30
        var algorithm = "SHA1"
    }

    // MARK: - reading a setup key

    /// An otpauth://totp/… link, or the key on its own as sites write it out
    /// in groups, in either case.
    static func parse(_ text: String) -> Setup? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: text), url.scheme?.lowercased() == "otpauth" {
            guard url.host?.lowercased() == "totp" else { return nil }
            let items = Dictionary(
                (url.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
            guard let secret = items["secret"].flatMap(base32) else { return nil }
            var setup = Setup(secret: secret)
            if let digits = items["digits"].flatMap(Int.init), (6...8).contains(digits) { setup.digits = digits }
            if let period = items["period"].flatMap(Int.init), period > 0 { setup.period = period }
            if let algorithm = items["algorithm"]?.uppercased(), ["SHA1", "SHA256", "SHA512"].contains(algorithm) {
                setup.algorithm = algorithm
            }
            return setup
        }
        return base32(text).map { Setup(secret: $0) }
    }

    /// RFC 4648 base32, forgiving about spaces, dashes, case and padding.
    static func base32(_ text: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let clean = text.uppercased().filter { !" -=\t\n".contains($0) }
        guard clean.count >= 16 else { return nil }
        var bits = 0, value = 0
        var out = Data()
        for char in clean {
            guard let index = alphabet.firstIndex(of: char) else { return nil }
            value = (value << 5) | index
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - the code

    static func code(_ setup: Setup, at date: Date = Date()) -> (code: String, left: Int) {
        let now = Int(date.timeIntervalSince1970)
        var counter = UInt64(now / setup.period).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let key = SymmetricKey(data: setup.secret)
        let mac: [UInt8]
        switch setup.algorithm {
        case "SHA256": mac = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case "SHA512": mac = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        default: mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        }
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let number = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var modulo: UInt32 = 1
        for _ in 0..<setup.digits { modulo *= 10 }
        let digits = String(number % modulo)
        let code = String(repeating: "0", count: setup.digits - digits.count) + digits
        return (code, setup.period - now % setup.period)
    }

    // MARK: - the keychain

    private static let service = Store.world.map { "Fast 2FA (\($0))" } ?? DevelopmentKeychain.service("Fast 2FA")

    private static func identity(_ host: String, _ user: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host + "\u{1}" + user,
        ]
    }

    /// Kept only if it reads as a setup key. The text is kept as given, so a
    /// link's digits and period come back with it. `record`: the wall stamp
    /// of the sync record it is written from (SyncWallet.write).
    @discardableResult
    static func save(_ text: String, host: String, user: String, from record: Int64? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parse(text) != nil, let data = text.data(using: .utf8) else { return false }
        return Vault.writing("code/" + host + "\u{1}" + user, from: record) { () -> Bool in
            let status = Vault.quietly { Keychain.update(identity(host, user) as CFDictionary, [kSecValueData as String: data] as CFDictionary) }
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }
            var fresh = identity(host, user)
            fresh[kSecValueData as String] = data
            fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            fresh[kSecAttrLabel as String] = service
            return Vault.quietly { Keychain.add(fresh as CFDictionary, nil) } == errSecSuccess
        }
    }

    static func setup(host: String, user: String) -> Setup? {
        var query = identity(host, user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard Vault.quietly({ Keychain.copyMatching(query as CFDictionary, &out) }) == errSecSuccess,
              let data = out as? Data, let text = String(data: data, encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    /// The key as it was given, for sync to carry: a link keeps its digits
    /// and period.
    static func text(host: String, user: String) -> String? {
        var query = identity(host, user)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard Vault.quietly({ Keychain.copyMatching(query as CFDictionary, &out) }) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// When each key last changed, by its login's id, without reading one.
    static func modified() -> [String: Date] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard Vault.quietly({ Keychain.copyMatching(query as CFDictionary, &out) }) == errSecSuccess,
              let rows = out as? [[String: Any]]
        else { return [:] }
        var dates: [String: Date] = [:]
        for row in rows {
            if let id = row[kSecAttrAccount as String] as? String { dates[id] = row[kSecAttrModificationDate as String] as? Date ?? .distantPast }
        }
        return dates
    }

    /// The key follows its login when that is renamed. False when there is
    /// none to move.
    @discardableResult
    static func move(host: String, user: String, toHost: String, toUser: String) -> Bool {
        Vault.quietly {
            Keychain.update(identity(host, user) as CFDictionary,
                          [kSecAttrAccount as String: toHost + "\u{1}" + toUser] as CFDictionary)
        } == errSecSuccess
    }

    static func forget(host: String, user: String, from record: Int64? = nil) {
        Vault.removing("code/" + host + "\u{1}" + user, from: record) {
            _ = Vault.quietly { Keychain.delete(identity(host, user) as CFDictionary) }
        }
    }

    /// Which logins have a key, by their ids, and without reading a key.
    static func ids() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard Vault.quietly({ Keychain.copyMatching(query as CFDictionary, &out) }) == errSecSuccess,
              let rows = out as? [[String: Any]]
        else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
