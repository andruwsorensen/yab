import Foundation
import Security
import YabStore
#if canImport(FoundationModels)
import FoundationModels
#endif

// Jev reads the words for Actions in the Field (Experimental), through
// OpenRouter's decisions endpoint: TypeSafe's model never writes text, it
// picks. One pass answers three questions: which kind of request the words
// are, which of your mail's people they name, and which of the sites you go
// to. Times, dates and the rest are read from the words here, and every
// value still comes from the mail, the calendar or the history. Jev is
// asked only on the user's own OpenRouter key, straight from this Mac:
// nothing goes through Yab's servers. Without a key this Mac's own model
// reads, and without that the patterns alone (RequestReader).

/// What reads the field's words, Settings › AI › Models › Reading the
/// Field: this Mac's own model, or TypeSafe's Jev through OpenRouter. Ollama
/// (Jev's desktop models) is the next one to come.
enum FieldReader: String, CaseIterable, Identifiable {
    case system, jev

    static let key = "models.field.reader"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .jev: "TypeSafe Jev"
        }
    }
    var detail: String {
        switch self {
        case .system:
            // Without the model only the plain shapes are read.
            FormModel.why.map { "\($0), so only plain words are read: dark mode, pin Linear, meeting with Taro." }
                ?? "Apple Intelligence on this Mac: free, nothing leaves it."
        case .jev:
            OpenRouterKey.read() == nil
                ? "Needs your OpenRouter key, added with Add Account above; until then this Mac's own model reads."
                : "Through OpenRouter on your key, about half a second."
        }
    }

    /// The one chosen; Jev until a choice is made where a key is kept, the
    /// Mac's own model otherwise.
    @MainActor static var chosen: FieldReader {
        get {
            if let raw = Store.settings.string(forKey: key), let reader = FieldReader(rawValue: raw) { return reader }
            return OpenRouterKey.read() != nil ? .jev : .system
        }
        set { Store.settings.set(newValue.rawValue, forKey: key) }
    }
}

@MainActor
final class RequestModel {
    static let shared = RequestModel()
    static let modelKey = "experimental.requests.model"
    static let defaultModel = "typesafe/jev-1.13"

    /// What Jev picked for some words.
    struct Read {
        let kind: String
        let person: MailDesk.Contact?
        let host: String?
        let confidence: Double
        /// The model that answered, with its date.
        let model: String
        let seconds: Double
        /// Every other pick, by question: a tab, a page, a thread…
        var picks: [String: String] = [:]
        /// What Yab found before asking, which the picks point into.
        var found = Candidates()
    }

    /// Jev's choices for the kind, and what each one is.
    static let kinds: [String: String] = [
        "none": "a search, a question to answer, an address or a site's name: nothing for the browser to do",
        // Finding what was seen
        "find_tab": "find one of the open tabs",
        "find_page": "find a page the person saw before, by what was on it or who showed it",
        "find_mail": "find an email by who sent it or what it was about",
        "find_file": "find a file the person downloaded",
        "find_clip": "find something the person copied",
        "find_answer": "find what an AI agent answered or found before",
        "open_deep": "open a known part of a site the person uses, like its logs, settings or billing",
        // The browser itself
        "theme": "switch the browser to dark or light mode",
        "pin": "pin an open tab",
        "close_tabs": "close the open tabs of a site or about something",
        "move_tabs": "move open tabs, or a folder of yours whole, to another space",
        "split": "show two open tabs side by side",
        "space": "go to another space of the browser",
        "video": "float a video in its own window, picture in picture",
        "mute": "mute a tab that plays sound",
        "setting": "change how the browser looks or behaves, a setting and its value: compact sidebar, sidebar on the right, glass window, bigger default zoom, hide the address bar",
        "zoom": "make the current site's text bigger or smaller",
        "archive_tabs": "put away old tabs not opened for a while",
        "site_perm": "let a site use the camera or the microphone",
        // Mail
        "reply": "reply to an email",
        "forward": "forward an email to someone",
        "send_file": "send a file to a person by email",
        "archive_mail": "archive an email",
        "unsubscribe": "unsubscribe from a mailing list or newsletter",
        "remind": "be reminded if someone does not reply",
        "snooze": "snooze an email until later",
        "mail": "write a new email to a person",
        // Calendar
        "meeting": "set up a meeting or a call with a person",
        "focus": "block time in the calendar for oneself",
        "join": "join the next video call",
        "invite_answer": "accept a calendar invitation",
        "free": "ask when the person is free",
        // Sites
        "issue": "open a new issue in a GitHub repository",
        "linear": "open a new issue in Linear",
        "new_doc": "make a new Google doc, sheet or slides",
        "post": "write a post on X or Twitter",
        // Done by an agent on a site
        "return": "return something that was ordered",
        "cancel": "cancel a subscription or a membership",
        "time_off": "request time off, a vacation or leave",
        "reorder": "order something again",
        "book": "book or reserve something",
        "check_in": "check in for a flight or a stay",
        "pay": "pay an invoice or a bill",
        "track": "where a package or delivery is",
        "compare": "compare prices or options across sites",
        // Answers and memory
        "spend": "how much was spent on something",
        "who": "who a person is",
        "remember": "remember a fact about a person or for later",
    ]

    private var answers: [String: Read] = [:]
    private var asking: Set<String> = []
    private var waiting: Task<Void, Never>?
    private var warmed = false

    var model: String {
        let named = Store.settings.string(forKey: Self.modelKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return named.isEmpty ? Self.defaultModel : named
    }

    func answer(_ words: String) -> Read? { answers[words] }

    /// What was read of some words, for the bench: the kind, how sure, the
    /// person, the site and the other picks, or why nothing was asked.
    func said(_ words: String) -> [String: Any] {
        guard let read = answers[words] else {
            return ["asked": asking.contains(words), "reader": FieldReader.chosen.rawValue, "key": OpenRouterKey.read() != nil]
        }
        return ["kind": read.kind, "confidence": read.confidence, "person": read.person?.said ?? "", "host": read.host ?? "",
                "picks": read.picks, "model": read.model, "seconds": read.seconds,
                "found": ["tabs": read.found.tabs.count, "pages": read.found.pages.count, "threads": read.found.threads.count,
                          "files": read.found.files.count, "settings": read.found.settings.count]]
    }

    /// Once the words rest for 300 ms, Jev is asked; the Mac's own model at
    /// once, on every letter, each new letter stopping the reading before
    /// it (it costs nothing but the Mac's time, and only one runs). The
    /// field reads them again when it answers, if they are still what is
    /// typed.
    func ask(_ words: String, browser: Browser) {
        guard answers[words] == nil, !asking.contains(words), words.count >= 3 else { return }
        let key = OpenRouterKey.read()
        // Jev without a key: this Mac's own model reads instead.
        let reader = FieldReader.chosen == .jev && key == nil ? .system : FieldReader.chosen
        if reader == .system, !FormModel.ready { return }
        if reader == .system, !warmed { warmed = true; SystemReader.warm() }
        waiting?.cancel()
        let model = model
        waiting = Task { @MainActor [weak browser] in
            if reader == .jev { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled, let browser, Self.same(browser.typed, words) else { return }
            asking.insert(words)
            defer { asking.remove(words) }
            // A role the words say ("my lawyer"): its people lead the ones
            // Jev may pick, the words naming nobody.
            let typed = Candidates.content(words)
            let role = await FieldRoles.find(typed + FieldRoles.mended(typed).values)
            guard !Task.isCancelled else { return }
            let people = Self.people(for: words, first: role?.people ?? [])
            let hosts = Self.sites(for: words)
            let start = Date()
            let found = await Candidates.gather(words, browser: browser, people: people, hosts: hosts, role: role)
            guard !Task.isCancelled else { return }
            let picked: (kind: String, person: String?, host: String?, confidence: Double, model: String?, picks: [String: String])?
            if reader == .jev, let key {
                let reply = await Self.call(Self.body(words, model: model, people: people, hosts: hosts, found: found), key: key)
                // Jev answers with numbers: back to what they stand for.
                let asked = found.questions()
                func at<T>(_ list: [T], _ number: String?) -> T? { number.flatMap(Int.init).flatMap { list.indices.contains($0) ? list[$0] : nil } }
                picked = reply.flatMap(Self.picked).map { said in
                    var picks: [String: String] = [:]
                    for (name, number) in said.picks { if let option = at(asked[name] ?? [], number) { picks[name] = option.id } }
                    return (kind: said.kind, person: at(people, said.person)?.address, host: at(hosts, said.host),
                            confidence: said.confidence, model: said.model, picks: picks)
                }
            } else {
                // The Mac's own model picks the kind, the person and the
                // site; for the rest, what Yab ranked first.
                let read = await SystemReader.read(words, people: people.map(\.said), hosts: hosts)
                var picks: [String: String] = [:]
                if read?.kind == "setting", let options = found.questions()["setting"],
                   let number = await SystemReader.pick(words, options: options.map(\.label)) {
                    picks["setting"] = options[number].id
                }
                picked = read.map {
                    (kind: $0.kind, person: $0.person.map { people[$0].address }, host: $0.host.map { hosts[$0] },
                     confidence: 0, model: "Apple Intelligence", picks: picks)
                }
            }
            // A reading stopped by the next letter says nothing.
            guard !Task.isCancelled, let picked else { return }
            answers[words] = Read(kind: picked.kind, person: people.first { $0.address == picked.person },
                                  host: hosts.contains(picked.host ?? "") ? picked.host : nil, confidence: picked.confidence,
                                  model: picked.model ?? model, seconds: Date().timeIntervalSince(start),
                                  picks: picked.picks, found: found)
            if Self.same(browser.typed, words) { browser.typed = browser.typed }
        }
    }

    private static func same(_ typed: String, _ words: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == words
    }

    /// Whom Jev may pick: the people of a role the words say, then people
    /// the words' own letters find in your mail, then the ones you write to
    /// most, a dozen in all.
    private static func people(for words: String, first: [MailDesk.Contact] = []) -> [MailDesk.Contact] {
        let desk = MailDesk.shared
        var found = first
        for word in RequestModel.tokens(words) {
            for person in desk.people(matching: word, limit: 3) where !found.contains(person) { found.append(person) }
        }
        for person in desk.topContacts(12) where found.count < 12 && !found.contains(person) { found.append(person) }
        return found
    }

    /// The sites Jev may pick: the ones the words' own letters name, then
    /// the ones you go to most, a dozen in all.
    private static func sites(for words: String) -> [String] {
        var found: [String] = []
        for word in tokens(words) where word.count >= 4 {
            if let host = History.current.host(named: word), !found.contains(host) { found.append(host) }
        }
        for host in History.current.hosts(12) where found.count < 12 && !found.contains(host) { found.append(host) }
        return found
    }

    /// The words to look people and sites up by: each one of three
    /// letters or more, once.
    nonisolated static func tokens(_ words: String) -> [String] {
        var out: [String] = []
        for word in words.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) where word.count >= 3 {
            if !out.contains(word) { out.append(word) }
        }
        return out
    }

    // MARK: OpenRouter's decisions

    /// The question set, as the decisions endpoint takes it.
    static func body(_ words: String, model: String, people: [MailDesk.Contact], hosts: [String], found: Candidates = Candidates()) -> [String: Any] {
        var questions: [String: Any] = [
            "kind": ["type": "choice", "criteria": kinds,
                     "instructions": "Words typed in a web browser's address bar. Which one thing do they ask the browser to do?"],
        ]
        // Every choice by its number: people's addresses, pages' addresses
        // and the rest stay on this Mac, only the labels go.
        if !people.isEmpty {
            var criteria = ["nobody": "the words name no person, or someone not listed here"]
            for (index, person) in people.enumerated() {
                // Who they are to you, where the mail says it: "Luca Amato,
                // 4 mail threads, the person's lawyer".
                let role = found.role.flatMap { $0.people.contains(person) ? ", the person's \($0.role.name)" : nil } ?? ""
                criteria["\(index)"] = "\(person.name.isEmpty ? person.said : person.name), \(person.threads) mail threads" + role
            }
            questions["person"] = ["type": "choice", "criteria": criteria,
                                   "instructions": "Which of these people do the words name, in any language or form of the name?"]
        }
        if !hosts.isEmpty {
            var criteria = ["none": "the words name no site, or one not listed here"]
            for (index, host) in hosts.enumerated() { criteria["\(index)"] = Address.siteName(host) + " (" + host + ")" }
            questions["site"] = ["type": "choice", "criteria": criteria,
                                 "instructions": "Which of these sites or services do the words name, if any?"]
        }
        for (name, options) in found.questions() {
            var criteria = ["none": "none of these"]
            for (index, option) in options.enumerated() { criteria["\(index)"] = option.label }
            questions[name] = ["type": "choice", "criteria": criteria, "instructions": Candidates.asking[name] ?? name]
        }
        return ["model": model, "state": words, "questions": questions]
    }

    /// Jev's picks from its reply.
    nonisolated static func picked(_ reply: [String: Any]) -> (kind: String, person: String?, host: String?, confidence: Double, model: String?, picks: [String: String])? {
        guard let answers = reply["answers"] as? [String: Any], let kind = answers["kind"] as? [String: Any],
              let choice = kind["choice"] as? String else { return nil }
        func pick(_ name: String, unless none: String) -> String? {
            guard let answer = answers[name] as? [String: Any], let choice = answer["choice"] as? String, choice != none else { return nil }
            return choice
        }
        var picks: [String: String] = [:]
        for name in answers.keys where !["kind", "person", "site"].contains(name) {
            if let one = pick(name, unless: "none") { picks[name] = one }
        }
        return (choice, pick("person", unless: "nobody"), pick("site", unless: "none"),
                kind["confidence"] as? Double ?? 0, reply["model"] as? String, picks)
    }

    /// Jev on the user's own key, from this Mac to OpenRouter.
    nonisolated static func call(_ body: [String: Any], key: String) async -> [String: Any]? {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/alpha/decisions")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Yab", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await OpenRouterKey.session.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if code == 429 || code == 402 { OpenRouterKey.turnedAway(key) }
        guard code == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Your OpenRouter keys, in this Mac's keychain only: added in Settings ›
/// AI › Models › Add Account, never written to a file or synced. Jev runs
/// on the first in their order that OpenRouter hasn't just turned away
/// (rate limited, out of credit), and on the next while it sits out.
enum OpenRouterKey {
    private static let service = DevelopmentKeychain.service("dev.serafim.fast.openrouter")
    /// The first key's keychain account, from when there was one key.
    static let first = "field-requests"
    private static let idsKey = "models.keys.openrouter.ids"

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    /// Its own session, no cookies, no cache, and no redirects followed:
    /// the key goes to openrouter.ai and nowhere a reply points to.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: Stay(), delegateQueue: nil)
    }()

    private final class Stay: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Read from the keychain once, then kept in memory: the field asks on
    /// every letter.
    nonisolated(unsafe) private static var kept: [String: String?] = [:]
    /// Keys OpenRouter turned away, until when. Touched on the main thread.
    nonisolated(unsafe) private static var away: [String: Date] = [:]

    /// Off, the keys stay kept and nothing runs on them (Reading the Field
    /// picks this Mac's model).
    static let onKey = "models.keys.openrouter.on"
    static var on: Bool { Store.settings.object(forKey: onKey) as? Bool ?? true }

    /// Every key's id, in the order they are tried.
    static var ids: [String] {
        if let ids = Store.settings.stringArray(forKey: idsKey) { return ids }
        return key(first) == nil ? [] : [first]
    }

    /// The key to run on: switched on, the first not sitting out, else the
    /// first.
    static func read(now: Date = Date()) -> String? {
        guard on else { return nil }
        let keys = ids.compactMap { id in key(id).map { (id, $0) } }
        return (keys.first { (away[$0.0] ?? .distantPast) <= now } ?? keys.first)?.1
    }

    /// Whether any key is kept, on or off.
    static var any: Bool { !ids.isEmpty }

    static func key(_ id: String) -> String? {
        if let key = kept[id] { return key }
        let key = load(id)
        kept[id] = .some(key)
        return key
    }

    /// Until when OpenRouter turned this key away.
    static func out(_ id: String, now: Date = Date()) -> Date? {
        away[id].flatMap { $0 > now ? $0 : nil }
    }

    private static func load(_ id: String) -> String? {
        if AgentFixture.requested { return nil }
        // A test world reads its one key from a file its probe names, never
        // a keychain item of its own (evals/field-requests).
        if Store.testing {
            guard id == first else { return nil }
            return ProcessInfo.processInfo.environment["YAB_OPENROUTER_KEY_FILE"]
                .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }
        var ask = query(id)
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard Keychain.copySaved(ask as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    private static func store(_ id: String, _ key: String?) {
        kept[id] = .some(key)
        away[id] = nil
        guard !Store.testing else { return }
        guard let key else { Keychain.removeSaved(query(id) as CFDictionary); return }
        Keychain.save(query(id) as CFDictionary, data: Data(key.utf8))
    }

    /// A key added last in the order; its id.
    @discardableResult
    static func add(_ key: String) -> String {
        let id = ids.isEmpty ? first : "key." + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)).lowercased()
        store(id, key.trimmingCharacters(in: .whitespacesAndNewlines))
        Store.settings.set(ids.filter { $0 != id } + [id], forKey: idsKey)
        return id
    }

    static func replace(_ id: String, with key: String) {
        store(id, key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func remove(_ id: String) {
        let rest = ids.filter { $0 != id }
        store(id, nil)
        Store.settings.set(rest, forKey: idsKey)
    }

    static func move(_ id: String, by step: Int) {
        var all = ids
        guard let at = all.firstIndex(of: id), all.indices.contains(at + step) else { return }
        all.swapAt(at, at + step)
        Store.settings.set(all, forKey: idsKey)
    }

    /// Whether a key is here already.
    static func has(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return ids.contains { self.key($0) == key }
    }

    /// OpenRouter said 429 (rate limited) or 402 (out of credit): the next
    /// key runs Jev for a minute.
    nonisolated static func turnedAway(_ key: String) {
        DispatchQueue.main.async {
            guard let id = ids.first(where: { self.key($0) == key }) else { return }
            away[id] = Date().addingTimeInterval(PlanAccounts.keyWait)
        }
    }

    /// Whether OpenRouter takes the key: its own key page answers 200 for
    /// one it knows.
    static func verify(_ key: String) async -> Bool {
        // A test world answers as Use an API Key's check does (AgentKey.check).
        if Store.testing, let given = ProcessInfo.processInfo.environment["YAB_AGENT_KEY_CHECK"] { return given == "taken" }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 10)
        request.setValue("Bearer " + key.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}

/// This Mac's own model reading the words, in two short steps it can't
/// answer outside of: first the family (find, the browser, mail…), then the
/// kind within it with the person and the site by number. Each answer is held
/// to its list by generation (`@Generable` enums), greedily, so the same
/// words read the same. A long free list of 46 kinds read 2 of 12 right on
/// the user's history (2026-10-13). Nothing leaves the Mac.
enum SystemReader {
    struct Read: Sendable {
        let kind: String
        let person: Int?
        let host: Int?
    }

    /// Each family's kinds, with words people type for them, for the
    /// second step.
    static let families: [String: [(kind: String, examples: String)]] = [
        "find": [("find_tab", "where is the figma tab"),
                 ("find_page", "the page about pricing I read last week"),
                 ("find_mail", "elizabeth's mail about the round"),
                 ("find_file", "the deck I downloaded yesterday"),
                 ("find_clip", "the slack link I copied"),
                 ("find_answer", "what claude found about pricing"),
                 ("open_deep", "supabase logs for acme · vercel billing")],
        "browser": [("theme", "dark mode · light theme"),
                    ("pin", "pin linear"),
                    ("close_tabs", "close all youtube tabs"),
                    ("move_tabs", "move figma tabs to design"),
                    ("split", "linear next to figma"),
                    ("space", "go to personal"),
                    ("video", "float the video"),
                    ("mute", "mute the music"),
                    ("setting", "compact sidebar · sidebar on the right · glass window"),
                    ("zoom", "make this site bigger"),
                    ("archive_tabs", "clean up old tabs"),
                    ("site_perm", "let meet use the camera")],
        "mail": [("reply", "reply to taro that thursday works"),
                 ("forward", "forward the invoice to accounting"),
                 ("send_file", "send elizabeth the deck"),
                 ("archive_mail", "archive the newsletter"),
                 ("unsubscribe", "unsubscribe from substack"),
                 ("remind", "remind me if hugo doesn't reply"),
                 ("snooze", "snooze the deel mail till monday"),
                 ("mail", "email elizabeth about the update")],
        "calendar": [("meeting", "meeting with taro thursday at 3"),
                     ("focus", "block two hours tomorrow morning"),
                     ("join", "join my next call"),
                     ("invite_answer", "accept the plain invite"),
                     ("free", "when am I free with taro")],
        "site": [("issue", "issue in fast: tab crashes · github issue"),
                 ("linear", "linear issue: returns row"),
                 ("new_doc", "new doc for the launch"),
                 ("post", "tweet that we shipped")],
        "agent": [("return", "return the airpods on amazon"),
                  ("cancel", "cancel my plan on clerk"),
                  ("time_off", "time off nov 2 to 15 in workday"),
                  ("reorder", "order the coffee again"),
                  ("book", "book a table at nopa"),
                  ("check_in", "check in for my flight"),
                  ("pay", "pay the vercel invoice"),
                  ("compare", "cheapest flight to lisbon")],
        "answer": [("who", "who is taro"),
                   ("track", "where is my keyboard"),
                   ("spend", "how much on uber in september")],
        "memory": [("remember", "remember that elizabeth prefers mornings")],
    ]

    static let first = """
    You read words typed in a web browser's address bar and say which family of thing \
    they ask the browser to do. find: find something already seen (an open tab, a page \
    from the history, a mail, a file, a copied link, an agent's answer). browser: change \
    the browser itself (theme, a setting, tabs, spaces, sound, zoom). mail: act on email. \
    calendar: meetings and time. site: a new issue, doc or post on a site. agent: a task \
    done on a website (return, cancel, book, pay, time off, compare). answer: who someone \
    is, where a package is, how much was spent. memory: remember a fact. none: a web \
    search, a question to answer, an address or a site's name.
    """

    /// Words people type for each family, for the first step: where a
    /// thing already seen is ("where is the tab", "mail about") reads as
    /// find, even when it names a tab or a mail.
    static let familyExamples = """
    Examples:
    where is the figma tab → find
    the linear tab → find
    elizabeth's mail about the round → find
    the deck I downloaded → find
    supabase logs for acme → find
    dark mode → browser
    compact sidebar → browser
    close all youtube tabs → browser
    reply to taro that thursday works → mail
    snooze the deel mail till monday → mail
    email elizabeth about the update → mail
    meeting with taro thursday at 3 → calendar
    block two hours tomorrow morning → calendar
    issue in fast: tab crashes → site
    linear issue: returns row → site
    return the airpods on amazon → agent
    pay the vercel invoice → agent
    who is taro → answer
    remember that elizabeth prefers mornings → memory
    weather in lisbon → none
    how to center a div → none
    github.com → none
    """

    static let second = """
    Say which kind the words are, from the listed kinds and their examples, and which \
    listed person and listed site the words name, by number, in any language or form \
    of the name; -1 when none is named.
    """

    /// Loads the model before the first words, so they aren't kept waiting.
    @MainActor
    static func warm() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), FormModel.ready else { return }
        LanguageModelSession(instructions: first).prewarm()
        #endif
    }

    /// Which of the numbered options the words ask for, for a setting.
    static let third = """
    Say which of the numbered settings and values the words ask for, by number; -1 when none.
    """

    /// Whether the words say this name or site: a word of theirs, in any
    /// case, starts one of the name's words. The
    /// Mac's model otherwise picks someone for words that name nobody.
    nonisolated static func named(_ name: String, in words: String) -> Bool {
        matches(name, in: words) > 0
    }

    /// How many of the words say a word of this name. A word heard rather
    /// than spelled counts by its consonants: "yutub" is youtube's "tb".
    nonisolated static func matches(_ name: String, in words: String) -> Int {
        let parts = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !["www", "com", "app", "mail", "the"].contains($0) }
        func bones(_ word: String) -> String { word.filter { !"aeiouy".contains($0) } }
        return RequestModel.tokens(words).filter { token in
            parts.contains { part in
                part.hasPrefix(token) || (token.count >= 4 && part.count >= 3 && token.hasPrefix(part))
                    || (token.count >= 4 && bones(token).count >= 2 && bones(part).hasPrefix(bones(token)))
            }
        }.count
    }

    /// Work off the main actor that stops when the asking task is
    /// cancelled: the model stops generating for words already gone.
    static func stoppable<T: Sendable>(_ work: @escaping @Sendable () async -> T?) async -> T? {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// The setting the words ask for among `options`, by the Mac's model.
    @MainActor
    static func pick(_ words: String, options: [String]) async -> Int? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), !options.isEmpty else { return nil }
        // Only the settings saying the most of the words, when some do: a
        // list of 69 lost "compact sidebar" among file downloads, and
        // "sidebar on the right" is the sidebar's Right, not DevTools'.
        let said = options.map { matches($0, in: words) }
        let most = said.max() ?? 0
        let asked = most == 0 ? Array(options.indices) : options.indices.filter { said[$0] == most }
        let prompt = "Words: \(words)\n\nSettings:\n" + asked.enumerated().map { "\($0.offset): \(options[$0.element])" }.joined(separator: "\n")
        let number: Int? = await stoppable {
            guard FormModel.ready else { return nil }
            return try? await LanguageModelSession(instructions: third)
                .respond(to: prompt, generating: PickGuess.self, options: GenerationOptions(sampling: .greedy)).content.number
        }
        return number.flatMap { asked.indices.contains($0) ? asked[$0] : nil }
        #else
        return nil
        #endif
    }

    @MainActor
    static func read(_ words: String, people: [String], hosts: [String]) async -> Read? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return nil }
        let families = families
        let read: Read? = await stoppable {
            guard FormModel.ready else { return nil }
            let options = GenerationOptions(sampling: .greedy)
            let family = try? await LanguageModelSession(instructions: first)
                .respond(to: "\(familyExamples)\n\nWords: \(words)", generating: FamilyGuess.self, options: options).content.family
            guard !Task.isCancelled, FormModel.ready else { return nil }
            guard let family, family != .none, let kinds = families[family.rawValue] else { return Read(kind: "none", person: nil, host: nil) }
            let prompt = """
            Words: \(words)

            Kinds:
            \(kinds.map { "\($0.kind): \($0.examples)" }.joined(separator: "\n"))

            People:
            \(people.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))

            Sites:
            \(hosts.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n"))
            """
            guard let answer = try? await LanguageModelSession(instructions: second)
                .respond(to: prompt, generating: KindGuess.self, options: options).content else { return nil }
            // Held to the whole list by generation; a kind outside the family
            // the first step chose falls back to that family's first kind.
            let kind = kinds.contains { $0.kind == answer.kind.rawValue } ? answer.kind.rawValue : kinds[0].kind
            return Read(kind: kind,
                        person: people.indices.contains(answer.person) && named(people[answer.person], in: words) ? answer.person : nil,
                        host: hosts.indices.contains(answer.site) && named(hosts[answer.site], in: words) ? answer.site : nil)
        }
        return read
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
enum FieldFamily: String {
    case none, find, browser, mail, calendar, site, agent, answer, memory
}

@available(macOS 26, *)
@Generable
struct FamilyGuess {
    @Guide(description: "The family of thing the words ask for")
    var family: FieldFamily
}

@available(macOS 26, *)
@Generable
struct PickGuess {
    @Guide(description: "The listed setting's number, or -1")
    var number: Int
}

@available(macOS 26, *)
@Generable
enum FieldKind: String {
    case find_tab, find_page, find_mail, find_file, find_clip, find_answer, open_deep
    case theme, pin, close_tabs, move_tabs, split, space, video, mute, setting, zoom, archive_tabs, site_perm
    case reply, forward, send_file, archive_mail, unsubscribe, remind, snooze, mail
    case meeting, focus, join, invite_answer, free
    case issue, linear, new_doc, post
    case `return`, cancel, time_off, reorder, book, check_in, pay, compare
    case who, track, spend, remember
}

@available(macOS 26, *)
@Generable
struct KindGuess {
    @Guide(description: "The kind from the listed kinds")
    var kind: FieldKind
    @Guide(description: "The listed person's number, or -1")
    var person: Int
    @Guide(description: "The listed site's number, or -1")
    var site: Int
}
#endif
