import Foundation
import Security
import YabStore

// Connecting an agent with your own API key, for someone with no Claude or
// ChatGPT plan: Settings › Agents' way in, Use an API Key (AgentsIntro).
//
// Claude: the key is kept in this Mac's keychain under Yab's own service
// and handed to every claude Yab runs as ANTHROPIC_API_KEY, through the env
// Shell.find gives everything (tasks, PlanText, WarmClaude, the folders'
// summaries). Claude Code in print mode, which is how Yab always runs it,
// takes that key with no question; only its interactive mode asks once.
// The extra plan accounts (their own CLAUDE_CONFIG_DIR) never get it.
//
// ChatGPT: `codex login --with-api-key`, the key on stdin, so Codex keeps
// it in its own ~/.codex/auth.json as it does for anyone who types that.
//
// Either way PlanAccounts.read then counts the agent as signed in, and the
// rest of Connect (AgentSetup's skill, tools and command) goes on as it
// does after a plan's sign-in.
enum AgentKey {
    private static let service = DevelopmentKeychain.service("dev.serafim.fast.agent-key")

    /// The env name each CLI takes its key by.
    static let anthropic = "ANTHROPIC_API_KEY"
    static let openAI = "OPENAI_API_KEY"

    /// What a key of each starts with, for the field's placeholder.
    static func placeholder(_ cli: String) -> String { cli == "codex" ? "sk-…" : "sk-ant-…" }
    /// Who bills it, in its hint line and its trouble.
    static func provider(_ cli: String) -> String { cli == "codex" ? "OpenAI" : "Anthropic" }
    static func keysPage(_ cli: String) -> URL {
        URL(string: cli == "codex" ? "https://platform.openai.com/api-keys" : "https://console.anthropic.com/settings/keys")!
    }

    static func hint(_ cli: String) -> String {
        "Billed per use by \(provider(cli)). Kept in this Mac’s keychain."
    }
    static func refused(_ cli: String) -> String { "\(provider(cli)) didn’t take this key. Check it and paste it again." }
    static func unreachable(_ cli: String) -> String { "Couldn’t reach \(provider(cli)). Check your connection and try again." }
    static func unsaved(_ cli: String) -> String { "\(AgentSetupModel.name(cli)) didn’t keep the key." }

    // MARK: - Claude's, in the keychain

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "claude", kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    /// Read from the keychain once, then kept in memory: every run of
    /// claude asks for it.
    nonisolated(unsafe) private static var kept: String??

    /// Claude's key, if one is kept.
    static func claude() -> String? {
        if AgentFixture.requested { return nil }
        if let kept { return kept }
        let key = load()
        kept = .some(key)
        return key
    }

    private static func load() -> String? {
        // A test world reads it from a file its probe names, never a
        // keychain item of its own.
        if Store.testing {
            return ProcessInfo.processInfo.environment["YAB_CLAUDE_KEY_FILE"]
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        var ask = query
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard Keychain.copySaved(ask as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// Kept, or with nil taken away. A test world keeps it in memory only.
    static func keep(claude key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        kept = .some(key)
        guard !Store.testing else { return }
        guard let key else { Keychain.removeSaved(query as CFDictionary); return }
        Keychain.save(query as CFDictionary, data: Data(key.utf8))
    }

    /// The env every claude runs in, with the key kept, if there is one.
    /// Applied once where Shell.find makes the env, and again on a save or
    /// a removal, to the env it has already made.
    static func apply(_ env: [String: String], claude key: String? = AgentKey.claude()) -> [String: String] {
        var env = env
        env[anthropic] = key
        return env
    }

    // MARK: - more keys, each an account of its own

    /// The keys added from Models › Add Account, each under its account's
    /// id (PlanAccounts, `tail` set): Claude's handed to that account's
    /// runs as ANTHROPIC_API_KEY, Codex's kept by its own login in the
    /// account's folder too. Read once, then kept in memory. A test world
    /// keeps them in memory only.
    nonisolated(unsafe) private static var held: [String: String?] = [:]

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    static func secret(_ id: String) -> String? {
        if let key = held[id] { return key }
        var key: String?
        if !Store.testing {
            var ask = query(id)
            ask[kSecReturnData as String] = true
            ask[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: AnyObject?
            if Keychain.copySaved(ask as CFDictionary, &found) == errSecSuccess, let data = found as? Data {
                key = String(data: data, encoding: .utf8)?.nilIfEmpty
            }
        }
        held[id] = .some(key)
        return key
    }

    /// Passive Models refresh needs presence, never the API-key value.
    /// Keep cache access on the UI actor; only the uncached attribute query
    /// goes to the same bounded worker as Claude's plan login check.
    @MainActor
    static func hasSecret(_ id: String) async -> Bool {
        if let key = held[id] { return key != nil }
        if Store.testing { return false }
        return await PlanAccounts.keychainPresence(service, account: id) { service in
            var ask = query(id)
            ask[kSecAttrService as String] = service
            ask[kSecReturnAttributes as String] = true
            ask[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            let status = Keychain.copySaved(ask as CFDictionary, &found)
            return status == errSecSuccess || status == errSecInteractionNotAllowed
        }
    }

    static func keep(_ id: String, key: String?) {
        let key = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        held[id] = .some(key)
        guard !Store.testing else { return }
        guard let key else { Keychain.removeSaved(query(id) as CFDictionary); return }
        Keychain.save(query(id) as CFDictionary, data: Data(key.utf8))
    }

    /// The last four letters, the way the providers' own key lists show one.
    static func tail(_ key: String) -> String {
        "…" + key.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4)
    }

    /// Where the provider lists your keys, by its name.
    static func console(_ cli: String) -> String { cli == "codex" ? "OpenAI Platform" : "Anthropic Console" }

    /// Codex's own file says it signed in with a key, not a plan: an API
    /// key there and no tokens.
    static func codexKeyed(home: URL = AgentSetup.home.appendingPathComponent(".codex")) -> Bool {
        if AgentFixture.requested { return false }
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        let tokens = auth["tokens"] as? [String: Any] ?? [:]
        let held = ["access_token", "refresh_token", "id_token"].contains { !((tokens[$0] as? String) ?? "").isEmpty }
        return !held && !((auth[openAI] as? String) ?? "").isEmpty
    }

    /// Whether this agent's usual account runs on a key of yours.
    @MainActor static func keyed(_ cli: String) -> Bool {
        cli == "codex" ? codexKeyed() : cli == "claude" && claude() != nil
    }

    // MARK: - checking it once

    enum Check: Equatable { case taken, refused, unreachable }

    /// Its own session, no cookies, no cache, and no redirects followed:
    /// the key goes to the provider and nowhere a reply points to.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: Stay(), delegateQueue: nil)
    }()

    private final class Stay: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// The provider's list of models, asked with the key: free, and it
    /// answers 401 or 403 for a key it doesn't know. A test world answers
    /// from YAB_AGENT_KEY_CHECK (taken, refused, unreachable).
    static func check(_ cli: String, _ key: String, permit: ProviderLaunchPermit? = nil) async -> Check {
        guard let permit, permit.valid else { return .refused }
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_AGENT_KEY_CHECK"] {
            return given == "refused" ? .refused : given == "unreachable" ? .unreachable : .taken
        }
        if Store.testing { return .unreachable }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: cli == "codex" ? "https://api.openai.com/v1/models" : "https://api.anthropic.com/v1/models")!,
                                 timeoutInterval: 15)
        if cli == "codex" {
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        guard let (_, response) = try? await session.data(for: request), let code = (response as? HTTPURLResponse)?.statusCode
        else { return .unreachable }
        guard permit.valid else { return .refused }
        if code == 200 { return .taken }
        return code == 401 || code == 403 ? .refused : .unreachable
    }

    // MARK: - Codex's, through its own login

    /// `codex login --with-api-key`, the key on stdin: Codex writes it to
    /// its auth.json. True once it says so.
    static func codexLogin(binary: String, key: String, env: [String: String], permit: ProviderLaunchPermit? = nil) async -> Bool {
        guard let permit, permit.valid else { return false }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = ProcessLaunch.executableURL(binary)
                process.arguments = ["login", "--with-api-key"]
                process.environment = env
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let into = Pipe()
                defer { try? into.fileHandleForWriting.close() }
                process.standardInput = into
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                guard (try? permit.start(process)) == true else { return done.resume(returning: false) }
                let sent = ProviderLaunchPermit.atomic {
                    guard permit.valid else { return false }
                    do { try into.fileHandleForWriting.write(contentsOf: Data((key + "\n").utf8)); return true }
                    catch { return false }
                }
                guard sent else { if process.isRunning { process.terminate() }; return done.resume(returning: false) }
                try? into.fileHandleForWriting.close()
                if exited.wait(timeout: .now() + 30) == .timedOut {
                    Shell.end(process, grace: 1)
                    return done.resume(returning: false)
                }
                done.resume(returning: permit.valid && process.terminationStatus == 0)
            }
        }
    }

    /// `codex logout`, only when its auth.json holds a key of yours: a
    /// plan's sign-in is never taken from here.
    static func codexLogout(binary: String, env: [String: String], disconnect: ProviderDisconnectPermit? = nil) async {
        guard disconnect?.valid ?? true else { return }
        guard codexKeyed() else { return }
        _ = await Shell.run(binary, ["logout"], env: env, disconnect: disconnect?.bound(to: binary))
    }
}
