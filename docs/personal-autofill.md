# Personal autofill fix and review workflow

This change addresses the username-first Apple Passwords report in
[upstream issue #1156](https://github.com/yetanotherbrowser/yab/issues/1156).
The personal development branch retains the existing credential-isolation
and build-setup commits.

## One change per branch and pull request

The feature branch is `andruw/apple-passwords-focus`, based on
`andruw/dev-keychain-isolation`. Its pull request belongs in
`andruwsorensen/yab`, with that existing development branch as the base.
This makes the review show only the autofill work. Keep the resource fixes
in separate branches and pull requests after autofill has been tested.

A branch is a name for an independent line of commits. A pull request
compares that line with its base and records the discussion and checks.
Opening a PR does not merge it or change either installed browser.

From this source directory:

```sh
git status --short --branch
git diff andruw/dev-keychain-isolation...HEAD
swift test --jobs 4 --no-parallel --filter 'PasswordAutofillTests|ManagerVaultTests|ApplePasswordsTests'
git diff --check
./design-check --head
```

`PasswordAutofillTests` executes the real form script in temporary,
nonpersistent WebKit pages with dummy credentials. Manager and Apple
Password tests cover adapters and helper messages with test stand-ins.
These checks do not approve Touch ID or sign into a real account.
Wait for a check to finish before editing Swift signatures, so an
incremental build cannot combine old and new interfaces.

## The selected field across authentication

The manager path must capture the selected field before requesting a
secret. A one-use ticket identifies the original field in Yab's isolated
script world. After authentication, the fill must recheck the document,
URL, field identity, current values and focus before using that ticket.
Losing focus to the page body is allowed; moving into another editable
field cancels the selection. A changed or replaced field must be rejected.
Username-only validation stays inside the selected field's form, including
after blur when another sign-in form shares the page.

Important files:

- `Resources/PageScripts/forms.js`: capture and revalidation in the page.
- `Sources/Fast/ManagerVaults.swift`: capture before the manager asks for approval.
- `Sources/Fast/Tab.swift`: safely encode the ticket and dummy/real fill arguments.
- `Tests/FastTests/PasswordAutofillTests.swift`: focus-loss and stale-selection cases.

## Build and manual verification

Run the isolated development-profile check from the enclosing workspace,
then build only Yab Dev:

```sh
cd ..
python3 scripts/test-dev-isolation.py
cd dev
YAB_SIGN_IDENTITY=- YAB_APP_CACHE=0 YAB_JOBS=4 ./build.sh
open "build/yab Dev.app"
```

The ad hoc Dev build above cannot use the real Apple Passwords helper.
`ApplePasswords.mayRun` requires the browser entitlement checked by
`Preferences.entitledToPasskeys`, except for explicit test stand-ins.
The running Dev app is ad hoc signed with no team identity and lacks
`com.apple.developer.web-browser.public-key-credential`. Consequently,
Apple Passwords cannot be selected or offer saved accounts in this build.
Connecting a manager or focusing the username again does not remove this
signing restriction. The earlier instruction to test Touch ID here was incorrect.

Apple grants this capability through its managed-entitlement process:
[Apple's browser entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential).
Real verification requires a build with valid Apple-approved signing and
provisioning for its own bundle ID, or maintainer testing in an eligible
build containing this patch. Preserve the separate development profile.

In that eligible build, choose the saved account on the reported Church
Account username step, approve Touch ID, and verify that the username
fills without typing it and Next becomes enabled. Submitting the login
is unnecessary for checking this step.

Also verify cancellation: dismiss authentication and confirm no value is
filled. Record the app build, engine, and result in the PR. Automated
WebKit results do not establish real Touch ID behavior or Chromium
compatibility; leave the PR in draft until the intended scenario is checked.

## Verification on November 26, 2026

- The unchanged development script filled a focused username, then returned
  false with the field blank after blur to BODY. A password-only control filled.
- All 82 tests in the three focused suites above passed. New cases cover blur,
  field edits/replacement/removal, disabled/read-only/hidden fields, navigation,
  frame isolation, one-use tickets, overlapping requests, hidden account names,
  and an unrelated sign-in form sharing the page.
- The existing development-isolation check passed for both bundle identities,
  profiles, and all seven service namespaces, without real keychain access.
- The ad hoc Dev build passed. Its ID is `dev.serafim.fast.dev`, version
  `0.47.19`, build `202611261509`. Signature verification passed, and the
  packaged `forms.js` matches the tested source byte for byte.
- JavaScript syntax, design checks and `git diff --check` passed.
- Live follow-up found the username field present and focused, but no
  Apple Passwords suggestions. The entitlement gate above blocks native
  Apple Passwords in the ad hoc build before the patched fill path runs.
- Real Apple Passwords/Touch ID verification is blocked pending an eligible
  signed build. Chromium verification also remains pending.
  No merge or production installation was performed.

Practice on a separate branch: add a case to the username rejection test's
argument array that changes the field's `autocomplete` attribute to `off`.
Run `swift test --jobs 4 --no-parallel --filter PasswordAutofillTests`; the
stale selection should be rejected. Keep this exercise out of the fix's PR.
