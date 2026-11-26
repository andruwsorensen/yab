import YabStore
import AppKit
import CryptoKit
import Foundation
import Network
import Security

// A Gmail account connected to yab (docs/mail.md, OAuth): Google's consent
// page in the system's sign-in sheet, its answer caught on a port of this Mac, the refresh token
// kept in the keychain and nowhere else, a fresh access token asked for when
// the last one runs out. Disconnecting takes the token back at Google and
// deletes the account's store.
//
// The OAuth client is yab's own, a Desktop one, named by YAB_GOOGLE_CLIENT_ID
// and YAB_GOOGLE_CLIENT_SECRET (a Desktop client's secret is not a secret:
// Google says so) in the environment or the app's Info.plist. A build
// without one says so where Connect would be.

/// Where a sign-in goes: its consent page, its token endpoint, and the
/// name the answer comes back to on this Mac. Google's (MailClient), and
/// Microsoft's for an Outlook calendar (OutlookClient).
public protocol OAuthDoor: Sendable {
    func consent(redirect: String, challenge: String, state: String, hint: String?) -> URL
    func tokens(_ form: [String: String], session: URLSession) async throws -> [String: Any]
    /// "127.0.0.1" for Google; Microsoft's desktop redirect is "localhost".
    var loopback: String { get }
    /// Where the person sees the consent page (OAuthPresenter).
    var presenter: OAuthPresenter { get }
}

/// Where a person's sign-in is shown. Google turns its sign-in away in a
/// web view an app draws ("This browser or app may not be secure", #456),
/// even one that says it is Safari, and its OAuth policy asks native apps
/// for the system's browser: Google's goes to the Mac's own sign-in sheet
/// (ASWebAuthenticationSession), drawn by Safari or the default browser,
/// the answer still caught on the loopback port. Microsoft's takes a Yab tab.
public enum OAuthPresenter: String, Sendable {
    /// A Yab tab, or a peek over the mail page.
    case tab
    /// ASWebAuthenticationSession: the system's sign-in sheet.
    case systemSheet
    /// The person's other browser, for a sign-in an agent asked for: an
    /// agent must not drive its own consent page.
    case otherBrowser

    /// The way a sign-in opens: asked for by an agent (`outside`), in
    /// another browser; asked for by the person, the door's own.
    public static func choose(for door: any OAuthDoor, outside: Bool) -> OAuthPresenter {
        outside ? .otherBrowser : door.presenter
    }
}

public struct MailClient: Sendable, OAuthDoor {
    public let id: String
    public let secret: String
    public static let scope = "https://www.googleapis.com/auth/gmail.modify"
    /// Your meetings, read only, asked for with the mail in one consent so
    /// the next one shows beside your tabs (Meetings).
    static let calendarScope = "https://www.googleapis.com/auth/calendar.events.readonly"
    /// Which calendars the account shows (calendarList), read only, so a
    /// team's or a second calendar is read beside the primary
    /// (MeetingsGoogle.calendars). A scope Google has to approve for Yab's
    /// client first (docs/meetings-on-tabs.md, Every calendar): asked only
    /// once `listsCalendars` is on, at a connect, never by itself.
    static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"

    /// On since 2026-10-15, once Google's console had the calendar list
    /// scope; YAB_GOOGLE_CALENDAR_LIST=1 asks for it in a build with this off.
    public static let shipsCalendarList = true
    public static var listsCalendars: Bool {
        shipsCalendarList || ProcessInfo.processInfo.environment["YAB_GOOGLE_CALENDAR_LIST"] == "1"
    }

    public static var scopes: String { scopes(listing: listsCalendars) }
    static func scopes(listing: Bool) -> String {
        ([scope, calendarScope] + (listing ? [calendarListScope] : [])).joined(separator: " ")
    }

    public var loopback: String { "127.0.0.1" }
    public var presenter: OAuthPresenter { .systemSheet }

    public static func accepts(_ granted: String) -> Bool {
        granted.split(separator: " ").contains { $0 == scope }
    }

    /// Google hasn't finished reviewing Yab's use of Gmail: its sign-in
    /// warns that it hasn't verified the app, and people are told first how
    /// to get past it (MailClient.warnFirst). False once Google approves.
    public static let underReview = true

    public static var configured: MailClient? {
        let env = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        guard let id = env["YAB_GOOGLE_CLIENT_ID"] ?? info["YABGoogleClientID"] as? String, !id.isEmpty else { return nil }
        return MailClient(id: id, secret: env["YAB_GOOGLE_CLIENT_SECRET"] ?? info["YABGoogleClientSecret"] as? String ?? "")
    }

    /// Google's consent page for this client, answering to `redirect`.
    public func consent(redirect: String, challenge: String, state: String, hint: String? = nil) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: MailClient.scopes),
            // An account that gave the mail before keeps it, asked again.
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ] + (hint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        return parts.url!
    }

    /// A PKCE verifier and its challenge (RFC 7636, S256): 32 random bytes
    /// from the system's generator, or from Swift's, which draws on the same,
    /// should it ever refuse; never the zeros it started as.
    static func pkce() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = bytes.map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        let verifier = MailClient.url64(Data(bytes))
        return (verifier, challenge(verifier))
    }

    static func challenge(_ verifier: String) -> String {
        url64(Data(SHA256Digest.of(Data(verifier.utf8))))
    }

    static func url64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The token endpoint: a code for tokens, or a refresh token for an
    /// access token.
    public func tokens(_ form: [String: String], session: URLSession = MailGmail.uncached) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = form
        all["client_id"] = id
        if !secret.isEmpty { all["client_secret"] = secret }
        request.httpBody = all.map { "\($0.key)=\(MailClient.formEscape($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 400 || status == 401, json["error"] as? String == "invalid_grant" { throw MailTrouble.signedOut }
        guard status == 200 else { throw MailTrouble.status(status) }
        return json
    }

    static func formEscape(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}

public enum SHA256Digest {
    public static func of(_ data: Data) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

// MARK: - the keychain

/// Refresh tokens, one generic item an account, next to the passwords
/// (MailSecret), and Outlook calendar's and MailRevoke's beside them.
///
/// Kept on this Mac only: `AfterFirstUnlockThisDeviceOnly`, in the data
/// protection keychain, which Migration Assistant and a restored backup
/// don't carry to another Mac. That keychain wants the application
/// identifier entitlement, which only a build signed with Yab's
/// provisioning profile has (build.sh); any other (Yab Dev, a test run)
/// gets errSecMissingEntitlement and keeps the item in the login keychain,
/// the file keychain, which ignores the class (evals/keychain), as before.
/// Items an older Yab left in the login keychain move over once at launch
/// (`moveToThisDevice`).
public enum MailKeychain {
    public static let service = Store.world.map { "Fast Mail (\($0))" } ?? DevelopmentKeychain.service("Fast Mail")

    /// Which keychain an item is asked in.
    public enum Place: Sendable { case thisDevice, login }

    /// Whether this build may use the data protection keychain: asked once,
    /// by adding an item and deleting it again. A lookup doesn't tell: it
    /// answers errSecItemNotFound to a build without the entitlement too.
    public static let entitled: Bool = {
        let check = identity("entitlement check \(UUID().uuidString)", in: .thisDevice)
        var add = check
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = Keychain.add(add as CFDictionary, nil)
        Keychain.delete(check as CFDictionary)
        return status != errSecMissingEntitlement
    }()

    /// Where a new item goes.
    static var home: Place { entitled ? .thisDevice : .login }

    /// The places an item is looked for: this Mac's keychain first, then
    /// the login keychain, where an item not moved yet still is.
    static var places: [Place] { entitled ? [.thisDevice, .login] : [.login] }

    static func identity(_ account: String, in place: Place, service: String = service) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account.lowercased(),
                                    kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        // Said either way: a query without it reaches both keychains in a
        // build entitled to the data protection one, so dropping the login
        // copy took this Mac's too, the token just saved or moved there
        // (0.32.0-0.33.0, evals/keychain/delete_scope.swift).
        query[kSecUseDataProtectionKeychain as String] = place == .thisDevice
        return query
    }

    @discardableResult
    public static func save(_ token: String, for account: String) -> Bool {
        save(token, for: account, in: home)
    }

    static func save(_ token: String, for account: String, in place: Place, service: String = service) -> Bool {
        Keychain.quietly {
            let data = Data(token.utf8)
            let base = identity(account, in: place, service: service)
            var saved = Keychain.update(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess
            if !saved {
                var fresh = base
                fresh[kSecValueData as String] = data
                fresh[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                fresh[kSecAttrLabel as String] = service
                let status = Keychain.add(fresh as CFDictionary, nil)
                // Refused for want of the entitlement after all: kept as before.
                if status == errSecMissingEntitlement { return save(token, for: account, in: .login, service: service) }
                saved = status == errSecSuccess
            }
            // A copy left in the login keychain would only go stale there.
            if saved, place == .thisDevice { Keychain.delete(identity(account, in: .login, service: service) as CFDictionary) }
            return saved
        }
    }

    public static func token(for account: String) -> String? {
        for place in places {
            if let token = token(for: account, in: place) { return token }
        }
        return nil
    }

    static func token(for account: String, in place: Place, service: String = service) -> String? {
        var query = identity(account, in: place, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard Keychain.quietly({ Keychain.copyMatching(query as CFDictionary, &out) }) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func forget(_ account: String) {
        for place in places { forget(account, in: place) }
    }

    static func forget(_ account: String, in place: Place, service: String = service) {
        _ = Keychain.quietly { Keychain.delete(identity(account, in: place, service: service) as CFDictionary) }
    }

    /// The accounts kept in a place, from the items' attributes alone.
    static func accounts(in place: Place, service: String = service) -> [String] {
        var query = identity("", in: place, service: service)
        query.removeValue(forKey: kSecAttrAccount as String)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard Keychain.quietly({ Keychain.copyMatching(query as CFDictionary, &out) }) == errSecSuccess else { return [] }
        let items = out as? [[String: Any]] ?? (out as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Where `moveToThisDevice` reads, writes and deletes: the keychain,
    /// or a test's own.
    public struct Move {
        public var accounts: () -> [String]
        public var read: (_ account: String) -> String?
        /// Added, never written over: a token saved meanwhile is newer.
        public var add: (_ token: String, _ account: String) -> Bool
        public var readBack: (_ account: String) -> String?
        public var drop: (_ account: String) -> Void

        public init(accounts: @escaping () -> [String], read: @escaping (_ account: String) -> String?,
                    add: @escaping (_ token: String, _ account: String) -> Bool,
                    readBack: @escaping (_ account: String) -> String?, drop: @escaping (_ account: String) -> Void) {
            self.accounts = accounts
            self.read = read
            self.add = add
            self.readBack = readBack
            self.drop = drop
        }

        /// From the login keychain into this Mac's.
        public static func keychain(service: String = MailKeychain.service) -> Move {
            Move(accounts: { MailKeychain.accounts(in: .login, service: service) },
                 read: { MailKeychain.token(for: $0, in: .login, service: service) },
                 add: { token, account in
                     var fresh = identity(account, in: .thisDevice, service: service)
                     fresh[kSecValueData as String] = Data(token.utf8)
                     fresh[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                     fresh[kSecAttrLabel as String] = service
                     let status = Keychain.quietly { Keychain.add(fresh as CFDictionary, nil) }
                     return status == errSecSuccess || status == errSecDuplicateItem
                 },
                 readBack: { MailKeychain.token(for: $0, in: .thisDevice, service: service) },
                 drop: { MailKeychain.forget($0, in: .login, service: service) })
        }
    }

    /// Every item an older Yab kept in the login keychain, moved into this
    /// Mac's keychain: read, added there, read back, and only then deleted
    /// from the login keychain, so a step that fails leaves the old item
    /// and the account signed in. One the build can't read (another app's,
    /// a Yab Dev's) stays where it is. Nothing to do on a build without
    /// the entitlement. Returns the accounts moved.
    @discardableResult
    public static func moveToThisDevice(_ move: Move? = nil) -> [String] {
        guard let move = move ?? (entitled ? Move.keychain() : nil) else { return [] }
        // Held throughout, so a save meanwhile waits for the move.
        return Keychain.quietly {
            var moved: [String] = []
            for account in move.accounts() {
                guard let token = move.read(account), move.add(token, account) else { continue }
                // A token saved there since is newer, and the old one goes all the same.
                guard move.readBack(account) != nil else { continue }
                move.drop(account)
                moved.append(account)
            }
            return moved
        }
    }
}

// MARK: - taking a token back

/// An account's token taken back at Google when it is disconnected
/// (MailCenter.disconnect). Offline then, or Google not answering, the
/// token is kept in the keychain, under an item of its own, and asked
/// again at each launch until Google says it is gone: taken back now, or
/// no longer one it knows. Nothing else of the account is kept for it.
@MainActor
public enum MailRevoke {
    /// The keychain items still holding a token to take back.
    public static let key = "mail.revoking"

    /// Where the tokens are kept: the keychain, or a test's own.
    public struct Keep {
        public var save: (_ token: String, _ item: String) -> Bool = { MailKeychain.save($0, for: $1) }
        public var token: (_ item: String) -> String? = { MailKeychain.token(for: $0) }
        public var forget: (_ item: String) -> Void = { MailKeychain.forget($0) }

        public init(save: @escaping (_ token: String, _ item: String) -> Bool = { MailKeychain.save($0, for: $1) },
                    token: @escaping (_ item: String) -> String? = { MailKeychain.token(for: $0) },
                    forget: @escaping (_ item: String) -> Void = { MailKeychain.forget($0) }) {
            self.save = save
            self.token = token
            self.forget = forget
        }
    }

    /// Google's door, or a test world's stand-in (YAB_REVOKE_URL).
    static var endpoint: URL {
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_REVOKE_URL"].flatMap(URL.init(string:)) { return given }
        return URL(string: "https://oauth2.googleapis.com/revoke")!
    }

    /// A token to take back: kept first, so a quit or a Mac offline loses
    /// nothing, then asked.
    public static func revoke(_ token: String, settings: UserDefaults = Store.settings, keep: Keep = Keep(),
                       session: URLSession = MailGmail.uncached) async {
        let item = "revoke|" + UUID().uuidString.lowercased()
        guard keep.save(token, item) else {
            // Nowhere to keep it: asked once, as before.
            _ = await ask(token, session: session)
            return
        }
        settings.set((settings.stringArray(forKey: key) ?? []) + [item], forKey: key)
        await retry(settings: settings, keep: keep, session: session)
    }

    private static var running = false
    private static var again = false

    /// Every token still kept, asked again, each let go once Google no
    /// longer knows it; at each launch, and after a Disconnect. One look
    /// at a time: asked again meanwhile, it looks once more after.
    public static func retry(settings: UserDefaults = Store.settings, keep: Keep = Keep(), session: URLSession = MailGmail.uncached) async {
        guard !running else {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            let items = settings.stringArray(forKey: key) ?? []
            var gone = Set<String>()
            for item in items {
                guard let token = keep.token(item) else {
                    gone.insert(item)
                    continue
                }
                if await ask(token, session: session) {
                    keep.forget(item)
                    gone.insert(item)
                }
            }
            // Kept meanwhile by another Disconnect: still there.
            settings.set((settings.stringArray(forKey: key) ?? []).filter { !gone.contains($0) }, forKey: key)
        } while again
        running = false
    }

    /// One ask: true once Google no longer knows the token, taken back now
    /// (200) or before (400, invalid_token); false while it can't be reached
    /// or says anything else.
    public static func ask(_ token: String, session: URLSession) async -> Bool {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "token=\(MailClient.formEscape(token))".data(using: .utf8)
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 200 { return true }
        return http.statusCode == 400 && String(decoding: data, as: UTF8.self).contains("invalid_token")
    }
}

// MARK: - an access token

/// An account's access token, asked for again a minute before it runs out.
public final class MailAuth: @unchecked Sendable {
    public let account: String
    public let client: MailClient
    private let lock = NSLock()
    private var access: (token: String, until: Date)?

    public init(account: String, client: MailClient) {
        self.account = account
        self.client = client
    }

    public func token() async throws -> String {
        lock.lock()
        if let access, access.until > Date().addingTimeInterval(60) { lock.unlock(); return access.token }
        lock.unlock()
        guard let refresh = MailKeychain.token(for: account) else { throw MailTrouble.signedOut }
        let got = try await client.tokens(["grant_type": "refresh_token", "refresh_token": refresh])
        guard let token = got["access_token"] as? String else { throw MailTrouble.unreadable }
        let life = (got["expires_in"] as? Double) ?? 3600
        lock.lock()
        access = (token, Date().addingTimeInterval(life))
        lock.unlock()
        return token
    }
}

// MARK: - signing in

/// What Google gave at the end of a sign-in: the tokens, and the scopes
/// it let through (its page lets the calendar be left out).
public struct MailGrant {
    public let refresh: String
    public let access: String
    public let scopes: String

    public var calendar: Bool { scopes.split(separator: " ").contains { $0 == MailClient.calendarScope } }
    /// Its calendar list came too: every calendar it shows is read.
    public var calendarList: Bool { scopes.split(separator: " ").contains { $0 == MailClient.calendarListScope } }
}

/// A foreign callback must not consume the real sign-in's listener.
public enum MailOAuthCallback {
    public static func read(_ request: String, state: String) -> (code: String?, error: String?)? {
        let words = request.split(separator: " ")
        guard words.count >= 2, words[0] == "GET", let url = URLComponents(string: "http://localhost" + words[1]), url.path == "/oauth" else { return nil }
        let items = url.queryItems ?? []
        func one(_ key: String) -> String? {
            let values = items.filter { $0.name == key }
            return values.count == 1 ? values[0].value : nil
        }
        guard one("state") == state else { return nil }
        let code = one("code"), error = one("error")
        guard items.filter({ $0.name == "code" }).count <= 1,
              items.filter({ $0.name == "error" }).count <= 1 else { return nil }
        guard (code != nil) != (error != nil), code == nil || code?.isEmpty == false else { return nil }
        return (code, error)
    }
}

/// One sign-in: a port on this Mac waiting for Google's answer, the
/// consent page shown (OAuthPresenter), the code traded for tokens.
@MainActor
public final class MailSignIn {
    private var listener: NWListener?
    private let client: any OAuthDoor
    private let pkce = MailClient.pkce()
    private let state = UUID().uuidString
    private var done: ((Result<MailGrant, Error>) -> Void)?
    private var exchanging = false
    /// Google has answered on the port: the code is being traded.
    public var answered: Bool { exchanging }
    public private(set) var redirect = ""

    public init(client: any OAuthDoor) { self.client = client }

    /// Starts listening and hands back the consent page to open. `hint`:
    /// the address to connect, so Google asks only for the yes.
    public func start(hint: String? = nil, done: @escaping (Result<MailGrant, Error>) -> Void) throws -> URL {
        self.done = done
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.answer(connection) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        _ = ready.wait(timeout: .now() + 2)
        guard let port = listener.port?.rawValue else { throw MailTrouble.offline("no port for Google's answer") }
        redirect = "http://\(client.loopback):\(port)/oauth"
        return client.consent(redirect: redirect, challenge: pkce.challenge, state: state, hint: hint)
    }

    public func cancel() {
        listener?.cancel()
        listener = nil
        done = nil
    }

    private func answer(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let page = """
            <!doctype html><meta charset="utf-8"><meta name="color-scheme" content="light dark"><title>yab</title>
            <body style="font:15px -apple-system;display:grid;place-items:center;height:90vh">
            <p>Return to Yab to see the result of this sign-in. You can close this tab.</p>
            """
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n" + page
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            guard path.split(separator: "?", maxSplits: 1).first == "/oauth" else { return }
            Task { @MainActor in
                guard let self, self.done != nil, !self.exchanging,
                      let callback = MailOAuthCallback.read(line, state: self.state) else { return }
                self.exchanging = true
                self.listener?.cancel()
                self.listener = nil
                guard let code = callback.code else {
                    self.finish(.failure(MailTrouble.status(callback.error == "access_denied" ? 403 : 400)))
                    return
                }
                do {
                    let got = try await self.client.tokens(["grant_type": "authorization_code", "code": code,
                                                            "redirect_uri": self.redirect, "code_verifier": self.pkce.verifier],
                                                           session: MailGmail.uncached)
                    guard let refresh = got["refresh_token"] as? String, let access = got["access_token"] as? String else {
                        throw MailTrouble.unreadable
                    }
                    self.finish(.success(MailGrant(refresh: refresh, access: access, scopes: got["scope"] as? String ?? "")))
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func finish(_ result: Result<MailGrant, Error>) {
        let done = self.done
        self.done = nil
        done?(result)
    }
}
