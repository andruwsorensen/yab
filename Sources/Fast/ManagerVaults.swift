import Foundation

/// The connected managers Yab reads itself (ManagerVault), for one site:
/// what each has, in connection order, unlocked first by Yab where it keeps
/// the unlock password. What the field's list and an agent's sign_in both
/// ask. Names only come back; a password only from `fill`, straight into
/// the page.
@MainActor
enum ManagerVaults {
    /// One manager's answer for a site.
    struct Found: Equatable {
        let provider: String
        var state: ManagerVault.State
        var logins: [ManagerVault.Login]
    }

    /// The connected managers with an adapter that reads a vault, whose
    /// extension being off doesn't matter: Yab doesn't go through it.
    static var readable: [String] {
        PasswordManagers.Connections.shared.list.map(\.provider)
            .filter { ManagerVault.adapter($0)?.depth == .vault }
    }

    /// The connected managers Yab lists in its own rows: read by Yab and
    /// open, or being unlocked by it, with no manager's extension on in
    /// Yab. One that is on has the box to itself (fieldOwner): Yab never
    /// hides an extension's icon or menu to draw its own list instead.
    static var listed: [String] { listed(owner: PasswordManagers.fieldOwner) }

    /// The same on this tab: a private one that no extension reaches lists
    /// them beside nobody's (PasswordManagers.fieldOwner(on:)).
    static func listed(on tab: Tab) -> [String] { listed(owner: PasswordManagers.fieldOwner(on: tab)) }

    private static func listed(owner: Installed?) -> [String] {
        guard owner == nil else { return [] }
        return readable.filter { lastState[$0] == .open || ManagerLists.shared.unlocking[$0] != nil }
    }

    /// A short memory a site, so a field's focus and every keystroke
    /// don't each run the tools again.
    private static var recent: [String: (at: Date, found: [Found])] = [:]
    /// Unlocks tried this launch that didn't take: never tried again until
    /// the password is changed (as `ManagerUnlock.run`).
    private static var refused: Set<String> = []

    static func forget() {
        recent = [:]
    }

    /// Each readable manager's logins for `host`. A locked one Yab unlocks
    /// with its saved password, once; one the person unlocks is answered
    /// as it is, for the list to say so.
    static func look(_ host: String, fresh: Bool = false) async -> [Found] {
        let key = Vault.registrable(host)
        let managers = readable
        if !fresh, let kept = recent[key],
           stillTrue(true, at: kept.at, states: Dictionary(kept.found.map { ($0.provider, $0.state) }, uniquingKeysWith: { a, _ in a }),
                     readable: managers) {
            return kept.found
        }
        var out: [Found] = []
        var complete = true
        for id in managers {
            guard let adapter = ManagerVault.adapter(id) else { continue }
            var state = await adapter.state()
            if state == .locked, let opened = await unlock(id, adapter) { state = opened }
            var logins: [ManagerVault.Login] = []
            if state == .open {
                if let read = try? await adapter.logins(for: host) { logins = read } else { complete = false }
            } else if state == .needsApproval, fresh, let read = try? await adapter.logins(for: host) {
                // 1Password's app asks the person on the first read: only
                // when they asked for the list (`fresh`), never on focus.
                logins = read
                state = .open
            }
            // An agent's sign-in with Apple Passwords not paired yet: the
            // code asked for, as the person's own box does (Browser.onField).
            if id == PasswordManagers.apple, state == .needsApproval { ApplePasswordsPairing.offer(on: host) }
            if !answered(state) { complete = false }
            lastState[id] = state
            out.append(Found(provider: id, state: state, logins: logins))
        }
        // Only a real answer is kept: a list that timed out or a tool that
        // failed is asked again next time, not remembered as nothing here.
        recent[key] = complete ? (Date(), out) : nil
        return out
    }

    /// A state that is an answer: the manager said what it is. A failure
    /// (the tool didn't answer, said something unknown) is not one.
    static func answered(_ state: ManagerVault.State) -> Bool {
        if case .failed = state { return false }
        return true
    }

    /// Whether what was read for a site at `at` still holds: every manager
    /// gave a real answer, less than 30 seconds ago, the same managers are
    /// read now and none has been seen in another state since.
    static func stillTrue(_ complete: Bool, at: Date, states: [String: ManagerVault.State], readable: [String],
                          now: Date = Date(), seen: [String: ManagerVault.State]? = nil) -> Bool {
        guard complete, now.timeIntervalSince(at) < 30, Set(states.keys) == Set(readable) else { return false }
        let seen = seen ?? lastState
        return states.allSatisfy { id, state in seen[id].map { $0 == state } ?? true }
    }

    /// Each manager's state as last seen, for the list to know whom to ask.
    static var lastState: [String: ManagerVault.State] = [:]

    /// Unlocked with the password Yab keeps for it, once a launch; true
    /// when it is open now.
    static func unlockIfKept(_ id: String, _ adapter: any ManagerAdapter) async -> Bool {
        await unlock(id, adapter) == .open
    }

    private static func unlock(_ id: String, _ adapter: any ManagerAdapter) async -> ManagerVault.State? {
        let connections = PasswordManagers.Connections.shared
        guard connections.connection(id)?.mode == .yab, !refused.contains(id), case .found(let secret) = ManagerUnlock.fetch(id)
        else { return nil }
        let ok = await adapter.unlock(secret)
        if !ok { refused.insert(id) }
        connections.unlocked(id, ok: ok)
        return ok ? .open : nil
    }

    /// The saved unlock password changed: try it again.
    static func passwordChanged(_ id: String) {
        refused.remove(PasswordManagers.canonical(id))
        recent = [:]
    }

    private static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased() && a.port == b.port
    }

    /// One login read from its manager and put into the page: Touch ID
    /// first when Settings asks for it (Tab.fill), unless the manager just
    /// asked the person for it itself (Secret.proven), only into the site it
    /// was listed for. `caret`: into the box the caret is in, another
    /// site's frame too, for a row of the field's list, which was read for
    /// that frame's site; the login must be that frame's site's, and
    /// Tab.fill fills only while the caret is still in a frame of that
    /// origin. The secret lives for this call.
    static func fill(_ login: ManagerVault.Login, into tab: Tab, agent: Bool = false, caret: Bool = false,
                     done: @escaping @MainActor (Tab.Filled) -> Void) {
        let target = caret ? tab.fieldAddress : tab.address
        let frame = caret ? tab.fieldFrame : nil
        let page = tab.builtPage, document = tab.fieldDocument, field = tab.fieldIdentity
        guard let adapter = ManagerVault.adapter(login.provider),
              let host = target?.host()?.lowercased(),
              ManagerVault.matches(login.urls, host: host) || login.urls.isEmpty
        else { done(.gone); return }
        Task { @MainActor in
            // Capture the chosen field before the manager can blur it with
            // Touch ID. The manager's secret is not part of the ticket.
            var pickedField: String?
            if caret {
                guard let page, let document, let field,
                      let value = try? await page.call(
                        "return window.__yabForms ? window.__yabForms.pick(documentID, fieldID) : null",
                        arguments: ["documentID": document, "fieldID": field], in: .yab, frame: frame),
                      let ticket = value as? String
                else { done(.gone); return }
                pickedField = ticket
                guard !tab.gone, !tab.asleep, tab.builtPage === page,
                      sameOrigin(tab.fieldAddress, target), tab.fieldFrame?.token === frame?.token
                else { done(.gone); return }
            }
            guard let secret = try? await adapter.secret(login) else { done(.gone); return }
            // The manager may take a while (Touch ID, an app's approval):
            // the caret has to be where the login was matched still, the
            // same frame, or the page at the same origin, never wherever
            // it has gone since.
            let now = caret ? tab.fieldAddress : tab.address
            guard sameOrigin(now, target), !caret || (tab.builtPage === page && tab.fieldFrame?.token === frame?.token)
            else { done(.gone); return }
            if login.provider == PasswordManagers.apple {
                PasswordSaveDecision.remember(host: host, user: secret.user.isEmpty ? login.user : secret.user, password: secret.password)
            }
            tab.fill(user: secret.user.isEmpty ? login.user : secret.user, password: secret.password, agent: agent,
                     caret: caret, proven: secret.proven, pickedField: pickedField) { done($0) }
        }
    }
}

extension Bench {
    /// sign_in where Yab keeps nothing for the site, before the managers'
    /// in-page menus: a manager Yab reads itself fills the sign-in from its
    /// vault, and the agent sees names only. `otherwise` when none has a
    /// login here, so the menus are tried next (managerMenus).
    static func vaultSignIn(_ c: AgentCall, tab: Tab, host: String, session: String,
                            otherwise: @escaping @MainActor () -> Void) {
        guard !ManagerVaults.readable.isEmpty else { otherwise(); return }
        Task { @MainActor in
            let logins = await ManagerVaults.look(host).flatMap(\.logins)
            guard !logins.isEmpty else { otherwise(); return }
            let names = Array(Set(logins.map(\.user))).sorted()
            let wanted = (c.request["user"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let login: ManagerVault.Login
            if !wanted.isEmpty {
                guard let match = logins.first(where: { $0.user.lowercased() == wanted })
                    ?? logins.first(where: { $0.user.lowercased().contains(wanted) }) else {
                    // Not in a manager Yab reads: perhaps in one's own menu.
                    otherwise()
                    return
                }
                login = match
            } else if names.count > 1 {
                c.answer(["error": "The connected password managers have \(names.count) logins for \(Vault.registrable(host)): \(names.joined(separator: ", ")). Call sign_in again with user set to the one this task is for; if the task doesn't say, ask the user"])
                return
            } else {
                login = logins[0]
            }
            let name = PasswordManagers.name(login.provider)
            // Ask asks first, as Yab's own logins do.
            let permit = AgentPermit(kind: .signIn(host: Vault.registrable(host), users: [login.user]), session: session,
                                     detail: "as \(login.user), from \(name)")
            if c.browser.prefs.asking(session) == .ask {
                if let yes = tab.approved, yes.session == session, yes.ref == permit.key, Date().timeIntervalSince(yes.at) < 120 {
                    tab.approved = nil
                } else if tab.declined.remove(session) != nil {
                    c.answer(["error": "the person said not now to signing in: call handoff if they should do it themselves, or stop"])
                    return
                } else {
                    c.agents.ask(tab, permit)
                    c.answer(["error": "signing in waits for the person's yes; asking them now", "asking": true])
                    return
                }
            }
            c.agents.touch(session, "sign in · \(host)")
            AgentFeed.shared.did(tab, .type)
            AgentPage.run(tab, AgentFiles.submit, ["phase": "focus"]) { _ in
                // Said under the box while it fills: who, from where, never
                // the password.
                let agent = c.agents.session(session)?.name ?? "The agent"
                if let spot = tab.fieldSpot {
                    c.browser.agentFilling = AgentFilling(tab: tab.id, spot: spot, title: "\(agent) is signing in",
                                                          detail: "\(login.user), from \(name). Password hidden.", dark: tab.fieldDark)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if c.browser.agentFilling?.tab == tab.id { c.browser.agentFilling = nil }
                }
                ManagerVaults.fill(login, into: tab, agent: true) { filled in
                    if filled == .filled { c.browser.markFilled(tab, from: name) }
                    if filled == .refused { c.answer(["error": "the person didn't confirm with \(Vault.proof): call handoff, or stop"]); return }
                    if filled == .unasked { c.answer(["error": "the Mac couldn't ask for \(Vault.proof), so nothing was filled: call handoff so the person signs in"]); return }
                    guard filled == .filled else {
                        c.answer(["error": "\(name) didn't hand over the login, or the sign-in fields are gone: call handoff"])
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        AgentPage.run(tab, AgentFiles.submit, ["phase": "submit"]) { result in
                            let out = (try? result.get()) as? [String: Any] ?? [:]
                            let step = out["password"] as? Bool == true ? "the password" : "the name"
                            c.answer(["ok": true, "manager": login.provider,
                                      "said": "Filled \(step) for \(login.user) from \(name) and sent it. Take a snapshot: if a password page follows, call sign_in again; a code or captcha is a handoff."])
                        }
                    }
                }
            }
        }
    }
}
