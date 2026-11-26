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

In Yab Dev, connect Apple Passwords using Dev's own settings if needed.
Do not import the production browser profile. On the reported Church
Account sign-in, choose the saved account on the username step, approve
Touch ID, and verify the username fills without typing it manually.
Confirm that Next becomes enabled. A normal login is optional; verifying
the username step does not require submitting credentials.

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
- Real Apple Passwords/Touch ID and Chromium verification remain pending.
  No merge or production installation was performed.

Practice on a separate branch: add a case to the username rejection test's
argument array that changes the field's `autocomplete` attribute to `off`.
Run `swift test --jobs 4 --no-parallel --filter PasswordAutofillTests`; the
stale selection should be rejected. Keep this exercise out of the fix's PR.
