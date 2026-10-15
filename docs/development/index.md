# Contributing

## Setup

You need a Mac with Xcode (the version CI uses is in
`.github/workflows/ci.yml`; the project needs at least Xcode 16 for its
folder-synchronized groups). There are no third-party Swift packages.

```sh
# macOS app (unsigned, data stays local)
xcodebuild -project DocumentArchive.xcodeproj -scheme DocumentArchive \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# iOS app for the simulator
xcodebuild -project DocumentArchive.xcodeproj -scheme DocumentArchive \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

If `xcodebuild` reports a command line tools instance, point it at Xcode
for the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Unsigned builds have no iCloud entitlement: the app then stores everything
locally and shows "Nur lokal gespeichert" in the sidebar. iCloud sync needs a
build signed with a paid Apple Developer Program team (see the README).

## Tests

**Tests are mandatory.** Every change to behavior comes with tests, and every
bug fix starts with a test that fails without the fix (a regression test). A
pull request without tests for the behavior it changes is not ready for
review.

```sh
xcodebuild test -project DocumentArchive.xcodeproj -scheme DocumentArchive \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

or **⌘U** in Xcode. CI runs the same command as the required check
`test (macOS)`.

The tests use [Swift Testing](https://developer.apple.com/documentation/testing)
and live in `DocumentArchiveTests/`, one file per component. They are hosted
by the app, which notices the test run (`TestEnvironment.isRunningTests`) and
then opens an in-memory store and skips migrations, so the real archive is
never touched. Rules for tests:

- **No network.** Mistral is stubbed with `MistralStub` (a `URLProtocol`);
  `MistralStub.install(config:handler:)` sets the configuration and the
  responses, `MistralStub.reset()` removes them.
- **No real data.** Use `TestSupport.makeContainer()` for an in-memory archive,
  `TestSupport.makeDefaults()` for settings, `TestSupport.makeTemporaryDirectory()`
  for files and the test service name for the Keychain. Generate documents in
  the test (`TestSupport.renderPage`, `TestSupport.samplePDF`); never commit real
  documents.
- **Global state** (the Mistral stub, `AutoClassifier.defaults`) is only changed
  inside `GlobalStateTests`, whose nested suites run one after another.
- The model type `Tag` clashes with Swift Testing's `Tag`; use `ArchiveTag` in tests.

## Project layout

| Folder | Content |
|---|---|
| `DocumentArchive/App` | App entry point, data store setup, one-time migrations |
| `DocumentArchive/Model` | SwiftData models (synced through CloudKit) |
| `DocumentArchive/Services` | Import, PDF building, OCR, Mistral client, auto-assignment, maintenance |
| `DocumentArchive/Views` | SwiftUI views shared by macOS and iOS |
| `DocumentArchive/Platform` | Platform wrappers: PDFKit view, VisionKit scanner, sharing |
| `Config` | Entitlements and Info.plist additions |
| `DocumentArchiveTests` | Unit tests (Swift Testing) and their helpers in `Support/` |

One target builds both platforms. Platform-specific code is wrapped in
`#if os(iOS)` / `#if os(macOS)`; keep it small and in `Platform/` where
possible.

## Localization

Code, comments and UI source strings are English. German is provided through
String Catalogs: `DocumentArchive/Localizable.xcstrings` for the UI and
`DocumentArchive/InfoPlist.xcstrings` for Info.plist texts (camera permission,
display name). The app shows German on a German system and English otherwise.

- SwiftUI literals (`Text("…")`, `Button("…")`, `Section("…")`, …) are
  localized automatically. Strings that are passed around as `String` (enum
  labels, error messages, status texts, titles built in code) must use
  `String(localized: "…")`, otherwise they stay English.
- A missing German translation is a bug. Xcode adds new strings to the catalog
  when you build in the IDE; fill in the German text there. On the command
  line, `xcodebuild` does not update the catalog, so run
  `python3 scripts/check-localization.py build` after a build with
  `-derivedDataPath build` – CI does the same for macOS and iOS.
- `LocalizationTests` checks that every catalog entry has a finished German
  translation with the same placeholders.
- Words that match document **content** (matching rules, sender and date
  detection, default document type keywords) stay German and English,
  independent of the UI language.
- The Mistral prompt is English and asks for titles in the app's language.

## Data model and iCloud sync

The models in `DocumentArchive/Model` are synced through CloudKit, which
restricts what a change may do:

- Every property has a default value or is optional; relationships are
  optional. No `@Attribute(.unique)`.
- Only add things: new properties and new models. Never rename or remove a
  property or model, and never change a property's type. Once the schema is in
  the CloudKit *Production* environment it cannot be undone, and older app
  versions on other devices still read and write the old fields.
- Data that must be converted goes into a one-time migration in
  `DocumentArchive/App` (see `LegacyMigration.swift`), guarded by a flag so it
  runs once per device.

Pull requests that touch `DocumentArchive/Model` get the `schema-change`
label automatically. The plan must say why the change is compatible with
devices still running the previous version.

## External services

Documents leave the device only through features the user turns on:

- **iCloud** (CloudKit private database) for sync.
- **Mistral AI** for OCR and auto-assignment, only with an API key in the
  settings and the corresponding switch on. Without a key or on errors, the
  app falls back to Apple Vision and the local rules.

New features that send data anywhere else need this stated in the plan and a
setting to turn them off. API keys are stored in the Keychain, never in
`UserDefaults`, files or logs.

## Secrets

The repository is public, so credentials must never be committed. Three
layers check for them:

- **Pre-commit hook** (local, opt-in): runs [gitleaks](https://github.com/gitleaks/gitleaks)
  on the staged changes and refuses the commit on a finding. Enable it once
  per clone:

  ```sh
  brew install gitleaks
  git config core.hooksPath .githooks
  ```

- **CI job `gitleaks`** (required): scans the full history of every pull
  request and of `main`. The gitleaks version and the SHA-256 of its release
  archive are pinned in `.github/workflows/ci.yml`; to update, change both
  (`shasum -a 256` of the new `gitleaks_<version>_linux_x64.tar.gz`, compared
  with the release's `checksums.txt`).
- **GitHub secret scanning with push protection** for known provider formats.

`.gitleaks.toml` adds a rule for Mistral API keys to the default rules.
Findings are printed redacted. For a false positive, prefer changing the code
over an allow list; if an exception is needed, add it to `.gitleaks.toml` with
a comment saying why.

**After a leak, revoke the credential first** (for Mistral: delete the key in
the Mistral console and create a new one). Once something was pushed to a
public repository, it must be treated as known, even if the history is
rewritten afterwards.

## Pull requests and labels

Changes start as an issue with an approved plan; see
[Issues, plans and releases](./process).

`main` is protected: changes go through pull requests, which can only be
squash-merged when all CI checks pass. To accept a pull request, review it and
enable **auto-merge**; GitHub merges it once CI is green.

| Label | Meaning |
|---|---|
| `feature`, `bug`, `chore`, `docs` | Kind of change (set by hand). |
| `dependencies` | Dependency update (set by Dependabot). |
| `schema-change` | Changes the synced data model (set automatically). |
| `breaking` | Needs manual steps when updating (set by hand). |
| `plan`, `review`, `ready` | Planning state of an issue; see [Issues, plans and releases](./process). |

Labels are defined in `.github/labels.json` and synced to GitHub when that
file changes on `main`.

## Dependency security

- The app uses only Apple frameworks; adding a Swift package needs a reason
  in the plan.
- CI builds the macOS and the iOS app, runs the tests and scans for
  credentials with gitleaks on every pull request (see [Tests](#tests) and
  [Secrets](#secrets)).
- Dependabot opens weekly update pull requests for GitHub Actions.
- GitHub Actions are pinned to commit SHAs; workflows run with read-only
  permissions unless a job needs more.
