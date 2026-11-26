# Personal development isolation patch

This fork's `andruw/dev-keychain-isolation` branch adds development namespaces to
seven legacy keychain services that otherwise share names with the installed app:
mail, two-factor codes, clipboard encryption, Chromium Safe Storage, password
manager unlocks, agent API keys and OpenRouter keys. Production service names
stay unchanged. No production item is read, copied, migrated or deleted by this
patch; development starts with its own identities. This is a private development
setup change, not an upstream-reviewed release.

The development build also removes FinderInfo/ResourceFork metadata only from
its generated app before signing. This fixes the signing failure observed in
this synced Documents folder, following Apple's QA1940. It never clears metadata
on `/Applications/yab.app` or source assets.

`Sources/YabStore/DevelopmentKeychain.swift` follows the existing Store.name and
Store.development pattern. Its callers keep their existing test-world naming.
The unchanged Store.swift separately owns bundle IDs, settings and file paths.

From the enclosing `projects/yab` workspace:

```sh
python3 scripts/test-dev-isolation.py
cd dev
YAB_SIGN_IDENTITY=- YAB_APP_CACHE=0 YAB_JOBS=4 ./build.sh
open "build/yab Dev.app"
```

The check compiles the actual Store and namespace source into disposable app
bundles with production and development IDs. It proves the runtime-selected
profile, separate development service identities and compatibility of production
service names, without touching a keychain or browser data. It does not test real
credential read/write behavior. Wrapper maintenance and dependency documentation
live one directory above this source checkout, in README.md and docs/.

Keep working on this patched branch or branch from it while using real Dev
profiles. After fetching upstream, update local main with a fast-forward and
merge upstream/main into this branch, resolve changes, rerun the isolation check
and rebuild before launching. Opening a build from unpatched main would restore
the upstream legacy service naming. The pristine upstream archive remains in
`../archive/yab.git`. Keep a patch/branch backup with the preservation workspace.

Practice: create `andruw/practice` from this branch, add a sentence to this guide
and inspect `git diff`. This shows how a small personal change stays separate
from upstream main; no push or pull request is needed for the exercise.
