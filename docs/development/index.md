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

The app only uses iCloud sync when the build setting `DA_CLOUDKIT_ENABLED`
is `YES` (default `NO` in `Config/Project.xcconfig`; override it in the
git-ignored `Config/Local.xcconfig` for a build signed with the paid Apple
Developer team). Otherwise it stores everything locally and shows "Stored
locally only" in the sidebar.

Running on iPhone and iPad simulators and devices, the iOS tests, iPad
multitasking checks and the manual release check list:
[iPhone and iPad](./ios).

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
`test (macOS)`, and runs the tests on the iPhone simulator as `test (iOS)`
(see [iPhone and iPad](./ios) for the command).

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

### UI tests

`DocumentArchiveUITests/` holds a few XCUITest smoke tests for iPhone and iPad,
run by their own scheme `DocumentArchiveUITests` (see [iPhone and iPad](./ios)).
The app is started with the launch argument `-UITestSeed` (DEBUG builds only):
it then opens an in-memory store filled by `App/UITestSeed.swift`, so the tests
never see the real archive and never call Mistral. Rules:

- Find elements by accessibility identifier only, never by their (German) text.
  Every identifier lives in `Views/AccessibilityID.swift`; a view a UI test
  touches gets one from there.
- Keep the suite small (a handful of tests); behaviour belongs in unit tests.
- Extra sample data goes into `UITestSeed`, not into a new launch argument.
- Alerts and dialogs use real bindings (`Binding(presenting:)`), never
  `.constant(…)`: the system dismisses them by setting the binding to `false`.
- `SmokeTests.launchApp()` launches once more when the first launch fails or
  shows neither the list nor the sidebar (slow CI runners); wait for an
  element before using it instead of adding sleeps.

Pull requests do not run them on GitHub. The reviewer runs them locally on the
smallest iPhone and iPad and posts the results as a test report in the review;
a pull request is merged on that report plus the required checks. The workflow
`UI tests` (`.github/workflows/ui-tests.yml`) runs them every night on `main`
and on demand (Actions → UI tests → Run workflow) on the hosted runners, which
have an older iOS (26.x); a failure there is handled like a bug report.

## Project layout

| Folder | Content |
|---|---|
| `DocumentArchive/App` | App entry point, menu commands (`AppCommands`), data store setup, one-time migrations, UI test data |
| `DocumentArchive/Model` | SwiftData models (synced through CloudKit) |
| `DocumentArchive/Services` | Import, PDF building, OCR, Mistral client, auto-assignment, maintenance |
| `DocumentArchive/Views` | SwiftUI views shared by macOS and iOS |
| `DocumentArchive/Platform` | Platform wrappers: PDFKit view, VisionKit scanner, sharing |
| `Config` | Entitlements and Info.plist additions |
| `DocumentArchiveTests` | Unit tests (Swift Testing) and their helpers in `Support/` |
| `DocumentArchiveUITests` | UI smoke tests (XCUITest, iOS only) |

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

## Accessibility

The app must work with VoiceOver, large text and Increase Contrast on every
platform. Check every new or changed screen against this list:

- **Labels:** every icon-only button or control has a label (`Label` with a
  title, or `.accessibilityLabel`). Labels are UI strings and go through the
  String Catalog.
- **One element per row:** a list row reads as one sentence
  (`DocumentAccessibility.label(for:)`); decorative parts (thumbnails, dots,
  stars) are hidden from VoiceOver.
- **No gesture-only actions:** swipe, drag and similar gestures have an
  alternative: a button, a context menu item or a named
  `.accessibilityAction` (macOS has no swipe actions).
- **Selection is spoken:** pickers built from tap gestures (colors, symbols)
  name each choice (`Tag.colorName(for:)`, `DocumentType.symbolName(for:)`)
  and mark the chosen one with `.isSelected`.
- **Text sizes:** use text styles (`.body`, `.caption`, …), no fixed font
  sizes; avoid fixed frames around text.
- **Contrast:** text 4.5:1, borders and other non-text parts 3:1, in light and
  dark mode. Colors chosen by the user (tags) go through `ColorContrast`
  before they are used for text. Never use color alone to carry meaning.
  Text on a list row must also be readable when the row is selected (accent
  color on iPad and in a focused macOS list, grey in iPhone edit mode and an
  unfocused macOS list); `backgroundProminence` does not tell these apart
  reliably, so tag chips use an opaque fill.
- **Changes the user does not trigger** (processing finished) are announced
  with `AccessibilityNotification.Announcement` when they matter on the screen
  in front of the user.
- **New screens** get an accessibility audit test in the UI tests (from #21
  part 3 on).

Check with Accessibility Inspector (macOS) and with VoiceOver and the largest
text size on the iPhone and iPad simulators.

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
- **Folder format:** every pull request that changes `DocumentArchive/Model`
  also extends `ArchiveFolderFormat` (`Services/ArchiveFolderFormat.swift`):
  the new fields go into the matching record, `currentVersion.minor` goes up
  by one, and the round trip in `ArchiveFolderFormatTests` covers them.
  Children of a document (deadlines, facts, …) are fields of the document's
  sidecar, not separate files. Only a change older app versions cannot read
  at all raises the major version, which makes them stop using the folder.
- **Deleting documents** only goes through `DocumentDeletion.delete(_:in:)`,
  and deleting tags, correspondents and document types through
  `MetadataDeletion` (merges with `mergedInto`). They record the deletion for
  the folder copy; `ModelContext.delete` alone would leave the document in the
  folder, because the copy never infers deletions from missing objects.
- **Replacing `pdfData`** (text layer, cleanup, vault) calls `touch()`, so the
  folder copy writes the new PDF.

### Copy in a folder (#8)

The live store never moves. With a folder chosen in Settings → Storage
Location, `ArchiveMirror` writes the archive into `<folder>/Document Archive/`
(layout in `ArchiveFolderFormat`): at launch, when the app becomes active, on
"Sync Now" and when `StoreChangeObserver` reports a change (debounced 5 s).
Its bookkeeping (`ArchiveMirror.json` next to the store) belongs to one store
(`NSStoreUUIDKey`); for another store it starts over and never writes
tombstones. A pass that would delete more than 20 documents, or more than 10 %
of the folder's documents once the folder holds at least 50, waits for
confirmation in the settings and the sidebar footer (deleted tags,
correspondents and types never count). "Confirm" applies exactly the deletions
shown; later ones are checked again. A folder that already holds an archive is
only accepted when all its documents were written by this device (chosen
again after "Back to Default"); reading other archives comes with #8 part 2. Files are written atomically and coordinated; evicted
iCloud files are detected through `UbiquityStatus` and retried later. Tests and
the UI test sample data never start the folder copy; tests use temporary
folders only.

Pull requests that touch `DocumentArchive/Model` get the `schema-change`
label automatically. The plan must say why the change is compatible with
devices still running the previous version.

## Files from other apps (#12)

Every file that arrives from outside goes through `ExternalImport` and then
`DocumentImporter.importFile(data:name:into:)`, the same pipeline as the file
dialog and drag and drop (duplicate check on the original bytes, insert,
processing). `App/OpenURLHandler.swift` is the app's **only** URL entry point:
`ContentView` has the single `.onOpenURL` and `.handlesExternalEvents`, so an
opened file goes to the existing window. File URLs go to `ExternalImport`;
other URL kinds (#15) are added as branches there, never as a second
`.onOpenURL`. The app declares PDFs and images as document types
(`CFBundleDocumentTypes` in `Config/Info-macOS.plist` and
`Config/Info-iOS.plist`, role `Viewer`, rank `Alternate`, so it never becomes
the default viewer). On iOS, `LSSupportsOpeningDocumentsInPlace` makes Files
hand over the file itself; copies the system puts into `Documents/Inbox`
(Mail, "Copy to …") are removed after the import. Files opened before a
window exists wait in `ExternalImport` until `ContentView` hands over the
`ModelContext`.

## External services

Documents leave the device only through features the user turns on:

- **iCloud** (CloudKit private database) for sync.
- **The folder copy** (off by default): the provider of the chosen folder
  (iCloud Drive, Dropbox, …) receives the PDFs, the recognized text and the
  metadata in readable form. The settings section says so.
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
- CI builds the macOS and the iOS app, runs the tests on macOS and on the
  iPhone simulator, and scans for credentials with gitleaks on every pull request (see [Tests](#tests) and
  [Secrets](#secrets)).
- Dependabot opens weekly update pull requests for GitHub Actions.
- GitHub Actions are pinned to commit SHAs; workflows run with read-only
  permissions unless a job needs more.
