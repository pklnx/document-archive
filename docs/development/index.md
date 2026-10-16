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
- **`MatchMode` and `DocumentSource` are frozen:** never add a case. They are
  stored in synced objects, and an older app version cannot decode a value it
  does not know. A new kind of thing gets a new property instead.
- New fields must be **deployed to the CloudKit Production schema** (CloudKit
  dashboard, Development → Production) before a signed release ships them.
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
  deleting tags through `TagHierarchy.delete` (it moves the children up one
  level), correspondents, document types and saved views through
  `MetadataDeletion`, and
  merges through `MetadataMaintenance.merge(_:into:)` (tombstones with
  `mergedInto`; features that refer to these objects by id hook into its
  `didMerge`). They record the deletion for
  the folder copy; `ModelContext.delete` alone would leave the document in the
  folder, because the copy never infers deletions from missing objects.
- **Replacing `pdfData`** (text layer, cleanup, vault) calls `touch()`, so the
  folder copy writes the new PDF.

### Nested tags (#13)

A tag can be nested in another (`Tag.parent`, `Tag.children`), shown as
"Auto › Golf › Werkstatt". The logic lives in `Services/TagHierarchy.swift`:

- A document keeps only the tags the user chose; a parent is never added
  implicitly. A tag's filter, count and search include the tags nested in it
  (computed when reading; counts in one pass over the list's documents).
- `TagHierarchy.move(_:under:)` refuses moves that would create a cycle.
  Concurrent moves on two devices (or a merge) can still produce one:
  `repairCycles` makes the oldest member a root (`createdAt`, then
  `id.uuidString`, so every device decides the same way). It runs after the
  launch merge and after store changes (`TagCycleRepair`, through
  `StoreChangeObserver` and CloudKit import events) and saves only when it
  changed something. Until then, a tag whose chain never reaches a root is
  shown as a root.
- Duplicates are tags with the same parent and name; `mergeDuplicates` merges
  them top-down in one call.
- Older app versions ignore `parent` and show a flat list; if they delete a
  parent, `nullify` makes its children roots and no document loses a tag.
- Mistral receives the tags' display paths with the rule to pick the most
  specific tag; a returned path is mapped back with the oldest tag winning
  when two share a path.
- **Sidebar (macOS, iPad):** the tags are a tree of plain rows with a chevron
  button (`TagTreeRow`; a `DisclosureGroup` label cannot be selected on iOS).
  Expanded tags are kept per window in `@SceneStorage`. Tags are dragged as
  `TagReference` (own type `de.patrickklein.documentarchive.tag-ref`, declared
  in `Config/Info-*.plist`) onto another tag (nest) or the "Tags" header (top
  level); `TagHierarchy.moveDropped` refuses unknown ids and cycles. The
  context menu offers the same without dragging: "Move To…"
  (`TagParentPicker`), "Move to Top Level" and "New Subtag…".
- **iPhone (compact width):** the sidebar shows only top-level tags. The
  content column has its own `NavigationStack` (`ContentView.tagPath`); a
  tag's list shows its nested tags as subfolder chips, which push the child's
  list, and the back button returns to the parent. In regular width the chips
  select the child in the sidebar.
- Menus that assign tags (inspector, bulk actions) are nested: a tag with
  nested tags is a submenu that starts with the tag itself
  (`NestedTagMenuItems`). Tag chips show the tag's name; the path is the help
  text and the VoiceOver label.
- The tag editor reports a parent that was deleted or moved below the edited
  tag meanwhile (`TagHierarchy.parent(withID:for:among:)`) instead of saving a
  different parent.

### Saved views (#14)

A saved view (`Model/SavedView.swift`) is a name, a symbol, a `sortIndex` and a
`DocumentFilter` (`Services/DocumentFilter.swift`) stored as JSON in
`filterJSON` (maintainer decision), so new filter criteria need no schema
change. Older app versions ignore the model.

- **Tolerant decoding:** every filter field is decoded on its own. A value
  this version does not know (a newer sort or date range) falls back to the
  default and is listed in `fallbackKeys`. Setting a field removes it from
  `fallbackKeys` (the user touched it), even when the new value equals the
  fallback, so "Added" or "Any time" can replace a newer version's value.
  Writing through `SavedView.filter` keeps keys this version does not know,
  keeps the raw value of every key still in `fallbackKeys`, removes the keys of
  cleared fields, and writes only when the JSON string changes (also for the
  sort menu: a sort change is saved into the view). The editor and the sort
  menu show a fallen-back value as its own choice ("Set by a newer app
  version"), so choosing any value is a change.
- **References** are stored as `{id, name, key}`; `key` is the normalized
  merge key (core name for correspondents, parent path and name for tags). A
  missing id is resolved by key, which also covers merges by older versions.
  A reference that still cannot be resolved makes its criterion match nothing
  (an excluded tag is skipped) and sets `FilterContext.hasUnresolvedReferences`
  for the banner; it is never dropped silently.
- `SavedViewMaintenance.replace` runs in the merge hook
  (`MetadataMaintenance.didMerge`) and rewrites references to the keeper.
- A tag criterion includes the tag's subtree when `includeSubTags` is on; the
  same switch makes excluding a parent exclude its children.
- **Days** are always counted in the Gregorian calendar in the device's time
  zone (`DocumentFilter.dayCalendar`), also on a device set to the Japanese or
  Buddhist calendar, so `"2026-01-01"` and `year(2026)` mean the same dates
  everywhere. A document's day is the day its date falls on in the device's
  time zone. Absolute ranges are stored as such days (`"2026-01-01"`).
- **Date ranges**, all bounds inclusive, "today" being the day of `now`:

  | Range | First day | Last day |
  |---|---|---|
  | `absolute(from:to:)` | `from` (open if missing) | `to` (open if missing) |
  | `thisYear` | 1 January of today's year | 31 December of today's year |
  | `lastYear` | 1 January of the previous year | 31 December of the previous year |
  | `year(n)` | 1 January n | 31 December n |
  | `last30Days` | today − 29 days | today |
  | `last12Months` | the day after the same day 12 months ago | today |

  So a document dated in the future is outside `last30Days` and
  `last12Months`, but inside `thisYear` while it is in this year.
- `FilterContext` (references resolved, subtrees, `now`, the date bounds) is
  built once per view and render; it fetches only the kinds (tags,
  correspondents, types) the filter refers to, and the sidebar passes its
  `@Query` arrays instead. `DocumentFilter.apply` filters the list it is given
  (after any central exclusion) and sorts with `DocumentSort.sort(_:ascending:)`,
  the same sort the sidebar lists use. Decoded filters are cached by their JSON
  string.
- Order: `sortIndex`, then `createdAt`, then `id`; reordering renumbers 0…n.
- **Sidebar:** a "Views" section after "Library" (`SidebarItem.savedView`),
  with counts in one pass per view (`SavedViewMaintenance.counts`). The header
  has "+" (new view) and a menu with "Manage Views…"; a row's context menu
  has "Edit…", "Duplicate" (an exact copy of the stored JSON) and "Delete"
  (`MetadataDeletion`). macOS reorders by dragging in the sidebar; iPhone and
  iPad reorder, rename and delete in the "Manage Views" sheet
  (`SavedViewsManager`), because edit mode would turn the sidebar into a
  multi-selection.
- **Editor** (`SavedViewEditor`): a popover on macOS and iPad, a sheet on
  iPhone (`presentationCompactAdaptation(.sheet)`), with a `NavigationStack`
  for the multi-select lists (`ReferencePicker`) and a live count. References
  that resolve by key are shown as the live object; unresolved ones are listed
  as "(deleted)" with a button that removes them.
- **List:** a saved view's list uses the view's sort; the sort menu writes into
  the view (with a direction), the search field narrows it further, and a
  banner with "Edit View" appears while a reference cannot be resolved. Other
  lists offer "Save as View…" (also ⌥⌘S), which fills the editor from the list
  (inbox, favorites, recently added as `createdAt` in the last 30 days, type,
  correspondent, tag with its nested tags), the search text and the sort.

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
(Mail, "Copy to …") are removed after the import. On the Mac nothing is
removed: the build is not sandboxed, so `~/Documents/Inbox` is the user's own
folder. Files opened before a
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
