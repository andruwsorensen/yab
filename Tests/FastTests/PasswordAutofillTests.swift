import Foundation
import Testing
import WebKit
@testable import Fast

struct PasswordAutofillTests {
    private let older = Login(host: "example.com", user: "first@example.com", password: "older",
                              used: Date(timeIntervalSince1970: 10))
    private let recent = Login(host: "example.com", user: "latest@example.com", password: "recent",
                               used: Date(timeIntervalSince1970: 20))
    private let imported = Login(host: "example.com", user: "imported@example.com", password: "imported", used: nil)

    @Test func takesTheMostRecentUseRatherThanInputOrder() {
        let chosen = PasswordAutofill.login(in: [recent, imported, older], secret: false, empty: true,
                                           account: nil, named: nil)
        #expect(chosen == recent)
        #expect(PasswordAutofill.login(in: [imported], secret: true, empty: true, account: nil, named: nil) == nil)
    }

    @Test func aTypedAccountWinsOverRecencyAndAnEarlierNameStep() {
        #expect(PasswordAutofill.login(in: [recent, older], secret: true, empty: true,
                                      account: " FIRST@example.com ", named: recent.user) == older)
        #expect(PasswordAutofill.login(in: [recent, older], secret: true, empty: true,
                                      account: "someone@example.com", named: older.user) == nil)
        #expect(PasswordAutofill.login(in: [recent, older], secret: true, empty: true,
                                      account: "first", named: nil) == nil)
    }

    @Test func theNameStepStillDecidesOnAPageWithoutAnAccountChip() {
        #expect(PasswordAutofill.login(in: [recent, older], secret: true, empty: true,
                                      account: nil, named: older.user) == older)
        #expect(PasswordAutofill.login(in: [recent, older], secret: true, empty: true,
                                      account: nil, named: "unknown@example.com") == nil)
    }

    @Test func neverChangesABoxThatAlreadyHoldsSomething() {
        for secret in [false, true] {
            #expect(PasswordAutofill.login(in: [recent], secret: secret, empty: false,
                                          account: nil, named: nil) == nil)
        }
        var withoutSecret = recent
        withoutSecret.password = ""
        #expect(PasswordAutofill.login(in: [withoutSecret], secret: true, empty: true,
                                      account: nil, named: nil) == nil)
    }

    @Test func clearingOrRefocusingDoesNotAskAgainButANewDocumentDoes() {
        var attempts = PasswordAutofillAttempts()
        let first = attempts.begin(document: "page-a", field: "password")
        let repeated = attempts.begin(document: "page-a", field: "password")
        let nextStep = attempts.begin(document: "page-a", field: "next-step")
        let nextDocument = attempts.begin(document: "page-b", field: "password")
        #expect(first)
        #expect(!repeated)
        #expect(nextStep)
        #expect(nextDocument)
        attempts.reset()
        let afterReset = attempts.begin(document: "page-b", field: "password")
        let noDocument = attempts.begin(document: nil, field: "password")
        let noField = attempts.begin(document: "page-c", field: "")
        #expect(afterReset)
        #expect(!noDocument)
        #expect(!noField)
    }
}

extension PasswordAutofillTests {
    /// A picked manager account waits for authentication with a one-use
    /// field ticket. These fixtures use dummy values and no password manager.
    @MainActor
    private static func pick(_ web: WKWebView, focus: [String: Any]) async throws -> String {
        let result = try await web.callAsyncJavaScript(
            "return window.__yabForms.pick(documentID, fieldID)",
            arguments: ["documentID": focus["document"] as? String ?? "", "fieldID": focus["field"] as? String ?? ""],
            in: nil, contentWorld: Web.world)
        return try #require(result as? String)
    }

    @MainActor
    private static func fillPicked(_ web: WKWebView, ticket: String) async throws -> Bool {
        await withCheckedContinuation { go in
            web.evaluateInYab(Tab.fillScript(user: "picked@example.com", password: "dummy-secret", pickedField: ticket)) {
                go.resume(returning: $0 as? Bool == true)
            }
        }
    }

    private static let nameStep = """
    <form><input id="name" autocomplete="username"><button>Next</button></form>
    <input id="other" type="search">
    <script>window.changed = 0; window.sent = 0;
    document.getElementById('name').addEventListener('input', () => window.changed++);
    document.querySelector('form').addEventListener('submit', e => { e.preventDefault(); window.sent++; });</script>
    """

    @Test @MainActor func aPickedUsernameSurvivesAuthenticationBlurAndFillsOnlyOnce() async throws {
        let (web, messages) = try await Self.page(Self.nameStep)
        let focus = try await Self.focus("name", in: web, messages: messages)
        let ticket = try await Self.pick(web, focus: focus)
        _ = try await web.evaluateJavaScript("document.getElementById('name').blur(); true")
        #expect(try await Self.fillPicked(web, ticket: ticket))
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "picked@example.com")
        #expect(try await web.evaluateJavaScript("window.changed") as? Int == 1)
        #expect(try await web.evaluateJavaScript("window.sent") as? Int == 0)
        #expect(try await Self.fillPicked(web, ticket: ticket) == false)
    }

    @Test(arguments: [
        "document.getElementById('name').value = 'my edit'",
        "document.getElementById('name').outerHTML = '<input id=name autocomplete=username>'",
        "document.getElementById('name').remove()",
        "document.getElementById('name').disabled = true",
        "document.getElementById('name').readOnly = true",
        "document.getElementById('name').style.display = 'none'",
        "document.getElementById('name').value = 'edit'; document.getElementById('name').dispatchEvent(new Event('input', {bubbles:true})); document.getElementById('name').value = ''",
        "document.getElementById('other').focus(); document.getElementById('other').blur()",
        "history.pushState({}, '', '/different-step')"
    ])
    @MainActor func aPickedUsernameRejectsChangesDuringAuthentication(change: String) async throws {
        let (web, messages) = try await Self.page(Self.nameStep)
        let focus = try await Self.focus("name", in: web, messages: messages)
        let ticket = try await Self.pick(web, focus: focus)
        _ = try await web.evaluateJavaScript(change + "; document.activeElement.blur(); true")
        let eventsBeforeFill = try await web.evaluateJavaScript("window.changed") as? Int
        #expect(try await Self.fillPicked(web, ticket: ticket) == false)
        #expect(try await web.evaluateJavaScript("!document.getElementById('name') || document.getElementById('name').value !== 'picked@example.com'") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.getElementById('other').value") as? String == "")
        #expect(try await web.evaluateJavaScript("window.changed") as? Int == eventsBeforeFill)
        #expect(try await web.evaluateJavaScript("window.sent") as? Int == 0)
    }

    @Test @MainActor func aNewDocumentCannotReceiveAPickedUsernameFromTheSameURL() async throws {
        let (web, messages) = try await Self.page(Self.nameStep)
        let focus = try await Self.focus("name", in: web, messages: messages)
        let ticket = try await Self.pick(web, focus: focus)
        let (replacement, replacementMessages) = try await Self.page(Self.nameStep)
        _ = try await Self.focus("name", in: replacement, messages: replacementMessages)
        #expect(try await Self.fillPicked(replacement, ticket: ticket) == false)
        #expect(try await replacement.evaluateJavaScript("document.getElementById('name').value") as? String == "")
    }

    @Test @MainActor func pickedPairsAndPasswordOnlyStepsStillFillAfterBlur() async throws {
        let hiddenName = "<form><input id=name autocomplete=username value=picked@example.com style='display:none' readonly><input id=pass type=password autocomplete=current-password></form>"
        for html in [Self.signIn, "<form><input id=pass type=password autocomplete=current-password></form>", hiddenName] {
            let (web, messages) = try await Self.page(html)
            let focus = try await Self.focus("pass", in: web, messages: messages)
            let ticket = try await Self.pick(web, focus: focus)
            _ = try await web.evaluateJavaScript("document.getElementById('pass').blur(); true")
            #expect(try await Self.fillPicked(web, ticket: ticket))
            #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "dummy-secret")
        }
    }

    @Test @MainActor func anOlderManagerResponseCannotConsumeANewerSelection() async throws {
        let (web, messages) = try await Self.page(Self.nameStep)
        let focus = try await Self.focus("name", in: web, messages: messages)
        let older = try await Self.pick(web, focus: focus)
        let newer = try await Self.pick(web, focus: focus)
        #expect(try await Self.fillPicked(web, ticket: older) == false)
        #expect(try await Self.fillPicked(web, ticket: newer))
    }

    @Test(arguments: [
        "document.getElementById('pass').value = 'typed while waiting'",
        "document.getElementById('name').outerHTML = '<input id=name autocomplete=username>'"
    ])
    @MainActor func aPickedPairRejectsEditsAndReplacedFields(change: String) async throws {
        let (web, messages) = try await Self.page(Self.signIn)
        let focus = try await Self.focus("pass", in: web, messages: messages)
        let ticket = try await Self.pick(web, focus: focus)
        _ = try await web.evaluateJavaScript(change + "; document.activeElement.blur(); true")
        #expect(try await Self.fillPicked(web, ticket: ticket) == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "")
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value !== 'dummy-secret'") as? Bool == true)
        #expect(try await web.evaluateJavaScript("window.changed") as? Int == 0)
    }

    @Test @MainActor func aPickCanCaptureTheReportedFieldAfterTheNativeListBlurredIt() async throws {
        let (web, messages) = try await Self.page(Self.nameStep)
        let focus = try await Self.focus("name", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("document.getElementById('name').blur(); true")
        let ticket = try await Self.pick(web, focus: focus)
        #expect(try await Self.fillPicked(web, ticket: ticket))
    }

    @Test @MainActor func aPickedUsernameKeepsItsOwnFormAfterBlur() async throws {
        let otherSignIn = "<form><input id=other-name autocomplete=username><input id=other-pass type=password></form>"
        let (web, messages) = try await Self.page(Self.nameStep + otherSignIn)
        let focus = try await Self.focus("name", in: web, messages: messages)
        let ticket = try await Self.pick(web, focus: focus)
        _ = try await web.evaluateJavaScript("document.getElementById('name').blur(); true")
        #expect(try await Self.fillPicked(web, ticket: ticket))
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "picked@example.com")
        #expect(try await web.evaluateJavaScript("document.getElementById('other-name').value") as? String == "")
        #expect(try await web.evaluateJavaScript("document.getElementById('other-pass').value") as? String == "")
        #expect(try await web.evaluateJavaScript("window.sent") as? Int == 0)
    }

    private final class Messages: NSObject, WKScriptMessageHandler {
        var focus: [String: Any]?
        var focusedFrame: WKFrameInfo?
        var submit: [String: Any]?
        var settled = 0
        var loads = 0
        var loadFrame: (@MainActor (WKFrameInfo) -> Void)?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            switch body["kind"] as? String {
            case "load":
                loads += 1
                MainActor.assumeIsolated { loadFrame?(message.frameInfo) }
            case "focus": focus = body; focusedFrame = message.frameInfo
            case "submit": submit = body
            case "settled": settled += 1
            default: break
            }
        }
    }

    @MainActor
    private static func page(_ html: String, path: String = "/login",
                             first: String? = nil) async throws -> (WKWebView, Messages) {
        let messages = Messages(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(messages, contentWorld: Web.world, name: FormRelay.name)
        if let first {
            configuration.userContentController.addUserScript(WKUserScript(source: first,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: FormRelay.script,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        web.loadHTMLString(html, baseURL: URL(string: "https://example.test" + path))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true,
               messages.focus != nil { return (web, messages) }
            try await Task.sleep(for: .milliseconds(25))
        }
        let state = (try? await web.evaluateJavaScript("document.readyState")) as? String ?? "unknown"
        throw Unready(what: "the page at \(path) never loaded with forms.js saying where the caret is (readyState \(state))")
    }

    /// What a page never got to, in words: a cocoa file error here once
    /// read as a fixture file missing.
    private struct Unready: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    @MainActor
    private static func focus(_ id: String, in web: WKWebView, messages: Messages) async throws -> [String: Any] {
        messages.focus = nil
        _ = try await web.evaluateJavaScript("document.getElementById('\(id)').focus(); true")
        for _ in 0..<100 {
            if let focus = messages.focus, focus["rect"] is [String: Any] { return focus }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Unready(what: "#\(id) took the caret but forms.js never said where its box is")
    }

    @MainActor
    private static func fill(_ web: WKWebView, focus: [String: Any], user: String = "first@example.com",
                             password: String = "päss ' \" ${unexecuted}") async -> Bool {
        await withCheckedContinuation { go in
            web.evaluateInYab(Tab.fillScript(user: user, password: password,
                automaticDocument: focus["document"] as? String, automaticField: focus["field"] as? String)) {
                go.resume(returning: $0 as? Bool == true)
            }
        }
    }

    private static let signIn = """
    <form><input id="name" autocomplete="username"><input id="pass" type="password" autocomplete="current-password">
    <button>Sign in</button></form><script>
    window.changed = 0; window.sent = 0;
    document.getElementById('pass').addEventListener('input', function () { window.changed++; });
    document.querySelector('form').addEventListener('submit', function (e) { e.preventDefault(); window.sent++; });
    </script>
    """

    @Test @MainActor func fillsTheEmptyPairAndFiresFrameworkEventsWithoutSubmitting() async throws {
        let (web, messages) = try await Self.page(Self.signIn)
        let focus = try await Self.focus("name", in: web, messages: messages)
        #expect(focus["automatic"] as? Bool == true)
        #expect(await Self.fill(web, focus: focus))
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "first@example.com")
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "päss ' \" ${unexecuted}")
        #expect(try await web.evaluateJavaScript("window.changed") as? Int == 1)
        #expect(try await web.evaluateJavaScript("window.sent") as? Int == 0)
    }

    /// A canvas that can't give a pixel, as when the GPU process is busy or
    /// coming back (getImageData threw InvalidStateError after 15 s in the
    /// 0.0.30-again gate's N-Z shard): the box the caret went into is still
    /// told, with the page's ground read from its colors. Before 630e718f
    /// the focus relay threw on it and said nothing, and every test here
    /// waiting for the caret failed.
    @Test @MainActor func theCaretIsToldWhenNoPixelCanBeRead() async throws {
        let (web, messages) = try await Self.page("<body style='background:#101418;color:#eee'>" + Self.signIn + "</body>",
            first: "CanvasRenderingContext2D.prototype.getImageData = function () { throw new DOMException('busy', 'InvalidStateError') };")
        let focus = try await Self.focus("pass", in: web, messages: messages)
        #expect(focus["secret"] as? Bool == true)
        #expect(focus["dark"] as? Bool == true)
        #expect(await Self.fill(web, focus: focus))
    }

    @Test @MainActor func rechecksTheTypedIdentityAndPasswordAfterTheNativePrompt() async throws {
        let (web, messages) = try await Self.page(Self.signIn)
        _ = try await web.evaluateJavaScript("document.getElementById('name').value = 'FIRST@example.com'")
        let focus = try await Self.focus("pass", in: web, messages: messages)
        #expect(await Self.fill(web, focus: focus, user: "latest@example.com") == false)
        _ = try await web.evaluateJavaScript("document.getElementById('pass').value = 'my typed password'")
        #expect(await Self.fill(web, focus: focus) == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "my typed password")
        _ = try await web.evaluateJavaScript("document.getElementById('pass').value = ''")
        #expect(await Self.fill(web, focus: focus))
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "FIRST@example.com")
    }

    @Test @MainActor func secondaryAndHiddenSignupActionsLeaveTheLoginAvailable() async throws {
        let alternative = """
        <button type="button">Create an account</button><a href="/signup">Sign up</a>
        <h2 hidden>Create an account</h2>
        """
        let html = Self.signIn.replacingOccurrences(of: "</form>", with: alternative + "</form>")
        let (web, messages) = try await Self.page(html)
        let focus = try await Self.focus("pass", in: web, messages: messages)
        #expect(focus["automatic"] as? Bool == true)
        #expect(await Self.fill(web, focus: focus))
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "first@example.com")
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "päss ' \" ${unexecuted}")
        #expect(try await web.evaluateJavaScript("window.sent") as? Int == 0)
    }

    @Test @MainActor func aSoleSignupButtonCannotTakeAnAutomaticSecret() async throws {
        let html = """
        <form><input id="name" autocomplete="username"><input id="pass" type="password">
        <button type="button">Create an account</button></form>
        """
        let (web, messages) = try await Self.page(html, path: "/welcome")
        let focus = try await Self.focus("pass", in: web, messages: messages)
        #expect(focus["automatic"] as? Bool == false)
        #expect(await Self.fill(web, focus: focus) == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "")
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "")
    }

    @Test @MainActor func aSecondarySigninButtonCannotAuthorizeSignupAutofill() async throws {
        let html = """
        <form><input id="name" autocomplete="username"><input id="pass" type="password">
        <button type="button">Create an account</button><button type="button">Sign in</button></form>
        """
        let (web, messages) = try await Self.page(html, path: "/welcome")
        let focus = try await Self.focus("pass", in: web, messages: messages)
        #expect(focus["automatic"] as? Bool == false)
        #expect(await Self.fill(web, focus: focus) == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "")
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "")
    }

    @Test @MainActor func aSignupOrNewPasswordCannotTakeAnAutomaticSecret() async throws {
        let (web, messages) = try await Self.page(Self.signIn)
        let focus = try await Self.focus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("document.getElementById('pass').setAttribute('autocomplete', 'section-register new-password')")
        #expect(await Self.fill(web, focus: focus) == false)
        let signup = Self.signIn.replacingOccurrences(of: "Sign in", with: "Create an account")
        let (registration, registrationMessages) = try await Self.page(signup)
        let signupFocus = try await Self.focus("pass", in: registration, messages: registrationMessages)
        #expect(signupFocus["automatic"] as? Bool == false)
        #expect(await Self.fill(registration, focus: signupFocus) == false)
    }

    @Test @MainActor func aNewDocumentOrReplacedPairCannotTakeAnOlderFill() async throws {
        let (web, messages) = try await Self.page(Self.signIn)
        let focus = try await Self.focus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("document.getElementById('pass').outerHTML = '<input id=pass type=password>'; document.getElementById('pass').focus(); true")
        #expect(await Self.fill(web, focus: focus) == false)
        let (newDocument, newMessages) = try await Self.page(Self.signIn)
        _ = try await Self.focus("pass", in: newDocument, messages: newMessages)
        #expect(await Self.fill(newDocument, focus: focus) == false)
        #expect(try await newDocument.evaluateJavaScript("document.getElementById('pass').value") as? String == "")
    }

    @Test @MainActor func movingTheCaretAwayCancelsAnEarlierAutomaticFill() async throws {
        let (web, messages) = try await Self.page(Self.signIn + "<input id='other' type='search'>")
        let focus = try await Self.focus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("document.getElementById('other').focus(); true")
        #expect(await Self.fill(web, focus: focus) == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('pass').value") as? String == "")
    }

    @Test @MainActor func anEmailSubscriptionIsNotAnAutomaticNameStep() async throws {
        let (web, messages) = try await Self.page("<form><input id='name' type='email'><button>Subscribe</button></form>",
                                                  path: "/newsletter")
        let focus = try await Self.focus("name", in: web, messages: messages)
        #expect(focus["automatic"] as? Bool == false)
        #expect(await Self.fill(web, focus: focus) == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('name').value") as? String == "")
    }

    @Test @MainActor func changingAPasswordOffersTheNewOneNotTheCurrent() async throws {
        let (web, messages) = try await Self.page("""
        <form><input id="name" autocomplete="username" value="first@example.com">
        <input id="old" type="password" autocomplete="current-password">
        <input id="new" type="password" autocomplete="new-password">
        <input id="again" type="password">
        <button id="go">Change Password</button></form><script>
        document.querySelector('form').addEventListener('submit', function (e) { e.preventDefault(); });
        </script>
        """, path: "/settings/password")
        _ = try await web.evaluateJavaScript("""
        document.getElementById('old').value = 'older';
        document.getElementById('new').value = 'brand new';
        document.getElementById('again').value = 'brand new';
        document.getElementById('go').click(); true
        """)
        for _ in 0..<100 where messages.submit == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.submit?["password"] as? String == "brand new")
        #expect(messages.submit?["user"] as? String == "first@example.com")
    }

    @Test @MainActor func aPlainSignInStillOffersItsOnePassword() async throws {
        let (web, messages) = try await Self.page(Self.signIn)
        _ = try await web.evaluateJavaScript("""
        document.getElementById('name').value = 'first@example.com';
        document.getElementById('pass').value = 'typed';
        document.querySelector('button').click(); true
        """)
        for _ in 0..<100 where messages.submit == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.submit?["password"] as? String == "typed")
    }
}

extension PasswordAutofillTests {
    @Test @MainActor func aPickedFieldTicketCannotFillAnotherFrame() async throws {
        let (web, messages) = try await Self.page(Self.nameStep)
        let focus = try await Self.focus("name", in: web, messages: messages)
        let ticket = try await Self.pick(web, focus: focus)
        let (framed, frameMessages) = try await Self.framePage()
        _ = try await framed.evaluateJavaScript("""
        const child = document.getElementById('child').contentWindow;
        child.document.body.innerHTML = '<form><input id=u autocomplete=username><input id=p type=password></form>';
        child.document.getElementById('u').focus(); true
        """)
        for _ in 0..<100 where frameMessages.focus?["signin"] as? Bool != true { try await Task.sleep(for: .milliseconds(25)) }
        let frame = try #require(frameMessages.focusedFrame)
        #expect(!frame.isMainFrame)
        let result = try await framed.callAsyncJavaScript(
            "return window.__yabForms.fillPicked('dummy-user', 'dummy-password', ticket)",
            arguments: ["ticket": ticket], in: frame, contentWorld: Web.world)
        #expect(result as? Bool == false)
        #expect(try await framed.evaluateJavaScript("child.document.getElementById('u').value") as? String == "")
        #expect(try await framed.evaluateJavaScript("child.document.getElementById('p').value") as? String == "")
    }

    @MainActor
    private static func framePage() async throws -> (WKWebView, Messages) {
        let messages = Messages(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(messages, contentWorld: Web.world, name: FormRelay.name)
        configuration.userContentController.addUserScript(WKUserScript(source: FormRelay.frameScript,
            injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 480), configuration: configuration)
        messages.loadFrame = { [weak web] frame in
            web?.evaluateJavaScript(FormRelay.framePayload, in: frame, in: Web.world) { _ in }
        }
        web.loadHTMLString("<iframe id='child' srcdoc='<main id=slot></main>'></iframe>",
                           baseURL: URL(string: "https://example.test/login"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.getElementById('child').contentDocument.readyState === 'complete'")) as? Bool == true {
                return (web, messages)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Unready(what: "the frame bootstrap fixture did not load")
    }

    @Test @MainActor func editorFrameStaysSmallUntilALoginIsFocused() async throws {
        let (web, messages) = try await Self.framePage()
        _ = try await web.evaluateJavaScript("""
        const w = document.getElementById('child').contentWindow;
        w.document.body.innerHTML = '<form id=todos><input id=todo><main id=items></main></form>';
        w.todos.addEventListener('submit', e => e.preventDefault());
        w.items.innerHTML = '<input type=checkbox><input>'.repeat(100);
        w.todo.focus();
        for (let i=0;i<30;i++) w.todo.dispatchEvent(new w.KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
        true
        """)
        try await Task.sleep(for: .milliseconds(100))
        #expect(messages.loads == 0)
        _ = try await web.evaluateJavaScript("""
        w.document.body.innerHTML = '<form><input id=u autocomplete=username><input id=p type=password></form>';
        w.p.focus(); true
        """)
        for _ in 0..<80 where messages.focus?["signin"] as? Bool != true { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.loads == 1)
        #expect(messages.focus?["signin"] as? Bool == true)
        #expect(await Self.inYab("document.getElementById('child').contentWindow.__yabForms.fill('frame-owner','frame-secret')", web: web))
        #expect(try await web.evaluateJavaScript("w.u.value") as? String == "frame-owner")
        #expect(try await web.evaluateJavaScript("w.p.value") as? String == "frame-secret")
    }

    @Test @MainActor func aFrameSubmitBeforeInjectionStillSavesItsSnapshot() async throws {
        let (web, messages) = try await Self.framePage()
        _ = try await web.evaluateJavaScript("""
        const w = document.getElementById('child').contentWindow;
        w.document.body.innerHTML = '<div id=login><input id=u autocomplete=username><input id=p type=password><div id=go role=button>Continue</div></div>';
        w.u.value='frame-owner'; w.p.value='frame-secret';
        w.go.addEventListener('click', () => w.login.remove()); w.go.click(); true
        """)
        for _ in 0..<100 where messages.settled == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.loads == 1)
        #expect(messages.submit?["user"] as? String == "frame-owner")
        #expect(messages.submit?["password"] as? String == "frame-secret")
        #expect(messages.settled == 1)
    }
}

extension PasswordAutofillTests {
    @MainActor
    private static func inYab(_ expression: String, web: WKWebView) async -> Bool {
        await withCheckedContinuation { go in
            web.evaluateInYab(expression) { go.resume(returning: $0 as? Bool == true) }
        }
    }

    @Test @MainActor func unrelatedDOMChangesDoNotScanTheDocument() async throws {
        let (web, _) = try await Self.page("<main id='feed'></main>", first: """
        window.formScans = 0;
        for (const proto of [Document.prototype, Element.prototype, DocumentFragment.prototype]) {
          const query = proto.querySelectorAll;
          proto.querySelectorAll = function (selector) {
            if (this === document || selector === '*') window.formScans++;
            return query.call(this, selector);
          };
        }
        """)
        _ = try await web.evaluateJavaScript("""
        window.formScans = 0;
        for (let i = 0; i < 100; i++) {
          const node = document.createElement('div'); node.textContent = 'Feed ' + i;
          document.getElementById('feed').appendChild(node);
        }
        true
        """, in: nil, in: Web.world)
        try await Task.sleep(for: .milliseconds(2600))
        #expect(await Self.inYab("window.formScans === 0", web: web))
    }

    @Test @MainActor func onlyTheSubmittedFormDeterminesAnInPlaceSignIn() async throws {
        let (web, messages) = try await Self.page("""
        <form id='login'><input id='name' autocomplete='username'><input id='pass' type='password'><button>Sign in</button></form>
        <form><input type='password'></form>
        <script>document.getElementById('login').addEventListener('submit', e => {
          e.preventDefault(); document.getElementById('login').remove();
        });</script>
        """)
        _ = try await Self.focus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("""
        document.getElementById('name').value = 'fixture@example.com';
        document.getElementById('pass').value = 'synthetic';
        document.getElementById('login').requestSubmit(); true
        """)
        for _ in 0..<80 where messages.settled == 0 { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.submit?["user"] as? String == "fixture@example.com")
        #expect(messages.settled == 1)
        #expect(await Self.inYab("window.__yabForms.hasPassword() === false", web: web))
        _ = try await web.evaluateJavaScript("""
        const restored = document.createElement('form'); restored.id = 'login';
        restored.innerHTML = '<input type=password>'; document.body.prepend(restored); true
        """)
        #expect(await Self.inYab("window.__yabForms.hasPassword() === true", web: web))
    }
}


extension PasswordAutofillTests {
    // Reddit has no native form association: username and password live
    // in sibling faceplate-text-input roots, with another root outside.
    private static let shadowSignIn = """
    <login-panel id="panel"></login-panel><script>
    const panel = document.getElementById('panel').attachShadow({mode:'open'});
    panel.innerHTML = '<section><login-box id="name"></login-box><login-box id="pass"></login-box><login-button></login-button></section>';
    panel.getElementById('name').attachShadow({mode:'open'}).innerHTML = '<input name="username" autocomplete="username webauthn">';
    panel.getElementById('pass').attachShadow({mode:'open'}).innerHTML = '<input name="password" type="password" autocomplete="current-password">';
    panel.querySelector('login-button').attachShadow({mode:'open'}).innerHTML = '<button type="button"><span>Log In</span></button>';
    window.testBox = function (id) { return panel.getElementById(id).shadowRoot.querySelector('input'); };
    window.changed = 0; window.sent = 0;
    document.addEventListener('input', function () { window.changed++; });
    document.addEventListener('submit', function (e) { e.preventDefault(); window.sent++; });
    </script>
    """

    @MainActor
    private static func shadowFocus(_ id: String, in web: WKWebView, messages: Messages) async throws -> [String: Any] {
        messages.focus = nil
        _ = try await web.evaluateJavaScript("window.testBox('\(id)').focus(); true")
        for _ in 0..<100 {
            if let focus = messages.focus, focus["rect"] is [String: Any] { return focus }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Unready(what: "the shadow #\(id) took the caret but forms.js never reported its sign-in box")
    }

    @Test @MainActor func shadowSiblingBoxesOfferAndFillTheWholeLogin() async throws {
        let (web, messages) = try await Self.page(Self.shadowSignIn)
        let name = try await Self.shadowFocus("name", in: web, messages: messages)
        #expect(name["signin"] as? Bool == true)
        #expect(name["secret"] as? Bool == false)
        #expect(name["automatic"] as? Bool == true)
        let pass = try await Self.shadowFocus("pass", in: web, messages: messages)
        #expect(pass["secret"] as? Bool == true)
        #expect(pass["field"] as? String == name["field"] as? String)
        #expect(await Self.fill(web, focus: pass))
        #expect(try await web.evaluateJavaScript("testBox('name').value") as? String == "first@example.com")
        #expect(try await web.evaluateJavaScript("testBox('pass').value") as? String == "päss ' \" ${unexecuted}")
        #expect(try await web.evaluateJavaScript("window.changed") as? Int == 2)
        #expect(try await web.evaluateJavaScript("window.sent") as? Int == 0)
    }

    @Test @MainActor func shadowFillRechecksTheAccountAndNeverReplacesTypedSecrets() async throws {
        let (web, messages) = try await Self.page(Self.shadowSignIn)
        let focus = try await Self.shadowFocus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("testBox('name').value = 'another@example.com'; true")
        #expect(await Self.fill(web, focus: focus) == false)
        _ = try await web.evaluateJavaScript("testBox('name').value = ''; testBox('pass').value = 'typed'; true")
        #expect(await Self.fill(web, focus: focus) == false)
        #expect(try await web.evaluateJavaScript("testBox('pass').value") as? String == "typed")
        _ = try await web.evaluateJavaScript("testBox('pass').value = ''; true")
        let picked = await withCheckedContinuation { go in
            web.evaluateInYab(Tab.fillScript(user: "picked@example.com", password: "synthetic")) {
                go.resume(returning: $0 as? Bool == true)
            }
        }
        #expect(picked)
        #expect(try await web.evaluateJavaScript("testBox('name').value") as? String == "picked@example.com")
    }

    @Test @MainActor func aComposedAncestorFormKeepsOtherLoginsOut() async throws {
        let html = """
        <form><input id="other-name" autocomplete="username"><input id="other-pass" type="password"></form>
        <form id="chosen"><login-box id="name-host"></login-box><login-box id="pass-host"></login-box><button>Log In</button></form>
        <script>
        document.getElementById('name-host').attachShadow({mode:'open'}).innerHTML = '<input autocomplete="username">';
        document.getElementById('pass-host').attachShadow({mode:'open'}).innerHTML = '<input type="password">';
        window.testBox = function (id) { return document.getElementById(id + '-host').shadowRoot.querySelector('input'); };
        </script>
        """
        let (web, messages) = try await Self.page(html)
        let focus = try await Self.shadowFocus("name", in: web, messages: messages)
        #expect(focus["automatic"] as? Bool == true)
        #expect(await Self.fill(web, focus: focus))
        #expect(try await web.evaluateJavaScript("testBox('pass').value") as? String == "päss ' \" ${unexecuted}")
        #expect(try await web.evaluateJavaScript("document.getElementById('other-name').value") as? String == "")
        #expect(try await web.evaluateJavaScript("document.getElementById('other-pass').value") as? String == "")
    }

    @Test @MainActor func aShadowUsernameStepAndNewPasswordRetainTheirRules() async throws {
        let (web, messages) = try await Self.page(Self.shadowSignIn)
        _ = try await web.evaluateJavaScript("testBox('pass').remove(); true")
        let name = try await Self.shadowFocus("name", in: web, messages: messages)
        #expect(name["automatic"] as? Bool == true)
        #expect(await Self.fill(web, focus: name))
        #expect(try await web.evaluateJavaScript("testBox('name').value") as? String == "first@example.com")

        let (signup, signupMessages) = try await Self.page(Self.shadowSignIn)
        _ = try await signup.evaluateJavaScript("testBox('pass').autocomplete = 'new-password'; true")
        let pass = try await Self.shadowFocus("pass", in: signup, messages: signupMessages)
        #expect(pass["fresh"] as? Bool == true)
        #expect(pass["automatic"] as? Bool == false)
        #expect(await Self.fill(signup, focus: pass) == false)
        let generated = await withCheckedContinuation { go in
            signup.evaluateInYab("window.__yabForms.generated('synthetic-generated')") {
                go.resume(returning: $0 as? Bool == true)
            }
        }
        #expect(generated)
        #expect(try await signup.evaluateJavaScript("testBox('pass').value") as? String == "synthetic-generated")
    }

    @Test @MainActor func aShadowButtonReportsTheLoginBeforeThePageClearsItsBoxes() async throws {
        let (web, messages) = try await Self.page(Self.shadowSignIn)
        _ = try await Self.shadowFocus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("""
        testBox('name').value = 'fixture@example.com'; testBox('pass').value = 'synthetic';
        const button = document.getElementById('panel').shadowRoot.querySelector('login-button').shadowRoot.querySelector('button');
        button.addEventListener('click', function () { testBox('pass').value = ''; });
        button.querySelector('span').click(); true
        """)
        for _ in 0..<100 where messages.submit == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.submit?["user"] as? String == "fixture@example.com")
        #expect(messages.submit?["password"] as? String == "synthetic")
    }
}


extension PasswordAutofillTests {
    @Test @MainActor func aNonComposedSubmitInsideAShadowFormStillOffersSaving() async throws {
        let html = """
        <login-panel id="panel"></login-panel><script>
        const panel = document.getElementById('panel').attachShadow({mode:'open'});
        panel.innerHTML = '<form><input id="name" autocomplete="username"><input id="pass" type="password"><button>Log In</button></form>';
        window.testBox = function (id) { return panel.getElementById(id); };
        </script>
        """
        let (web, messages) = try await Self.page(html)
        _ = try await Self.shadowFocus("pass", in: web, messages: messages)
        _ = try await web.evaluateJavaScript("""
        testBox('name').value = 'fixture@example.com'; testBox('pass').value = 'synthetic';
        testBox('pass').form.dispatchEvent(new Event('submit', {bubbles:true, cancelable:true, composed:false})); true
        """)
        for _ in 0..<100 where messages.submit == nil { try await Task.sleep(for: .milliseconds(25)) }
        #expect(messages.submit?["user"] as? String == "fixture@example.com")
        #expect(messages.submit?["password"] as? String == "synthetic")
    }
}
