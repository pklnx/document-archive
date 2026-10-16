# Contributing

## Setup

You need a Mac with Xcode (the version CI uses is in `.xcode-version`, which
`xcodes` and similar tools read too; the project needs at least Xcode 16 for
its folder-synchronized groups). There are no third-party Swift packages.

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

### Test plans

The `DocumentArchive` scheme has two test plans in `TestPlans/`:

- **`Default.xctestplan`** is the scheme's default: ⌘U, `xcodebuild test`
  without `-testPlan` and the required CI jobs run it. It has one
  configuration, "Default", and runs `DocumentArchiveTests` **in parallel**:
  Swift Testing runs suites and tests concurrently. Until #43 part 2 the
  scheme had `parallelizable = "NO"`, which also serialized Swift Testing,
  so the whole suite ran one test at a time. Tests therefore must not share
  global state (see the rules below); a suite that has to use something
  global, like `KeychainStoreTests` with the real Keychain, is `.serialized`.
  In-memory stores all report `/dev/null` as their URL, so a test that
  follows store change notifications (`StoreChangeObserver`) uses
  `TestSupport.makeContainerOnDisk()`; otherwise the saves of other tests
  count as its changes.
- **`Nightly.xctestplan`** is attached to the scheme but not the default. Its
  configurations run in the nightly workflow (`nightly-tests.yml`) on macOS:
  - **"German"**: the app and the tests in German (`de`, region `DE`). A test
    that compares against an English UI string fails here; compare against
    `String(localized:)` or an identifier instead.
  - **"Thread Sanitizer"**: reports data races, every one of a run
    (`TSAN_OPTIONS=halt_on_error=0`). A race does not fail a test, and
    `xcodebuild` does not show the reports: the sanitizer writes them to
    `/tmp/DocumentArchive-TSan.<pid>` (`log_path` in the plan), and the
    nightly job fails when it finds one, with the reports in its log, summary
    and artifact. Locally, look there after a run. The configuration sets
    `DA_TEST_TIMEOUT_SCALE=5`, because the sanitizer slows text recognition
    down several times; the OCR suites still run, since their detached
    processing is what it should see.

```sh
xcodebuild test -project DocumentArchive.xcodeproj -scheme DocumentArchive \
  -testPlan Nightly -only-test-configuration German \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
# the same with -only-test-configuration "Thread Sanitizer"
```

Every wait for something asynchronous in a test scales its timeout with
`TestSupport.scaled(_:)` (`DA_TEST_TIMEOUT_SCALE`, default 1);
`TestSupport.waitUntilProcessed` does this already. A Thread Sanitizer report
in app code becomes an issue labeled `bug`; a race in test code is fixed in
the test.

### CI and the pinned Xcode

- **Pinned Xcode:** every macOS job runs on `macos-26` with the Xcode in
  `.xcode-version` (the local action `.github/actions/select-xcode` selects it
  and fails when the runner image does not have it).
- **Warnings are errors in CI only.** The build and test jobs pass
  `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`; the project settings are unchanged, so
  local builds only warn. CI checks the pinned Xcode's diagnostics, which can
  differ from a newer local Xcode (the maintainer and the reviewer use 27.1).
  To reproduce a CI warning locally, build with the pinned Xcode, if
  installed:

  ```sh
  DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer \
    xcodebuild build -project DocumentArchive.xcodeproj -scheme DocumentArchive \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
  ```

  A newer Xcode with the same flag finds most of them too. If a warning
  cannot be fixed (it comes from the SDK or a macro), keep just that
  diagnostic group a warning with `-Wwarning <group>` in `OTHER_SWIFT_FLAGS`
  in the project (SE-0443), with a comment and a linked issue, or wait for
  the fix. Turning the flag off for one target from the command line is not
  possible.
- **Output:** `xcodebuild` output goes through `xcbeautify --renderer
  github-actions`, which shows compiler errors, warnings and failed tests as
  annotations on the pull request's diff.
- **Coverage:** `test (macOS)` and `test (iOS)` collect code coverage; the
  job summary shows the app's line coverage and its ten least covered files
  with at least 50 executable lines (`scripts/coverage-summary.py`). There is
  no coverage gate.
- **Result bundles** (`TestResults-*`, the `.xcresult` of every test job) are
  uploaded for every run that is not cancelled and kept for 7 days.
- **Next Xcode:** `build (macOS, next Xcode)` builds both platforms and runs
  the macOS unit tests with the default Xcode of the `xcode-27` preview image,
  without warnings as errors. It is not a required check: a red run means
  "look at it", the pull request may still be merged. Apple Vision's models
  (text recognition, perspective correction) do not run on that preview
  image, so the job skips the tests that need them (listed in `ci.yml`); a
  new Vision test that fails only there goes into that list.
- **Moving the pin** (when a newer runner image is generally available) is a
  small pull request: the version in `.xcode-version` and `runs-on` of the
  macOS jobs in `ci.yml` and `ui-tests.yml`.

The tests use [Swift Testing](https://developer.apple.com/documentation/testing)
and live in `DocumentArchiveTests/`, one file per component. They are hosted
by the app, which notices the test run (`TestEnvironment.isRunningTests`) and
then opens an in-memory store and skips migrations, so the real archive is
never touched. Rules for tests:

- **No network.** Mistral is stubbed with `MistralStub` (a `URLProtocol`).
  `MistralStub.install(config:handler:)` returns a stub session with its own
  fake API key, `URLSession`, handler and recorded `requests`; requests are
  routed by their `Authorization` header, so parallel tests never see each
  other's requests. Run the test body in
  `ProcessingEnvironment.$current.withValue(stub.environment) { … }`, or pass
  `stub.environment` to `MistralClient` / `DocumentProcessor.analyze`.
- **No real data.** Use `TestSupport.makeContainer()` for an in-memory archive,
  `TestSupport.makeDefaults()` for settings, `TestSupport.makeTemporaryDirectory()`
  for files and the test service name for the Keychain. Generate documents in
  the test (`TestSupport.renderPage`, `TestSupport.samplePDF`); never commit real
  documents.
- **No global state.** Everything the import pipeline reads from outside (the
  Mistral configuration and session, settings, test hooks) comes from
  `ProcessingEnvironment.current`, a task-local: a test changes a copy and runs
  its body in `ProcessingEnvironment.$current.withValue(…)`, so suites can run
  in parallel. `Task {}` inherits it, `Task.detached` does not: code that
  detaches captures the environment first and passes it on (as
  `DocumentImporter.processAndWait` does). `MistralClient` and
  `DocumentProcessor.analyze` take the environment without a default for that
  reason. Values that `@Sendable` closures (stub handlers, hooks) collect go
  into a `Recorder` or a `Mutex`.
- The model type `Tag` clashes with Swift Testing's `Tag`; use `ArchiveTag` in tests.

### UI tests

`DocumentArchiveUITests/` holds a few XCUITest smoke tests, run by their own
scheme `DocumentArchiveUITests`: `SmokeTests` on iPhone and iPad (see
[iPhone and iPad](./ios)) and `MacSmokeTests` on the Mac. The target is
multi-platform like the app; iOS-only steps (swipes, rotation, edit mode) stay
in `#if os(iOS)`, the Mac suite in `#if os(macOS)`.
The app is started with the launch argument `-UITestSeed` (DEBUG builds only):
it then opens an in-memory store filled by `App/UITestSeed.swift`, uses its own
Keychain service name and never calls Mistral (`TestEnvironment.isUITestSeed`),
so the tests never see the real archive or the stored Mistral key. Rules:

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
- Attach screenshots of the screens a test visits (`XCTAttachment`, kept
  always), so a review can look at them; on the Mac, screenshot a window, not
  the app (`app.screenshot()` is the whole screen there).

Run the Mac tests with:

```sh
xcodebuild test -project DocumentArchive.xcodeproj -scheme DocumentArchiveUITests \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS=
```

`CODE_SIGN_IDENTITY=-` signs ad hoc, which the test runner needs;
`CODE_SIGN_ENTITLEMENTS=` leaves out the app's iCloud and sandbox entitlements,
which an ad-hoc signature cannot carry (the sample data run needs neither). The
tests need automation mode (`automationmodetool` shows its state; Xcode enables
it, asking for a password unless it was set up with
`sudo automationmodetool enable-automationmode-without-authentication`).
**They take over the pointer and keyboard of the Mac** while they run, and quit
any running copy of the app (same bundle identifier); run them when you are not
using the Mac, and as rarely as needed. Export the screenshots with
`xcrun xcresulttool export attachments --path <result>.xcresult --output-path <folder>`.

### Test strategy

Who runs what, so every test runs where it is cheapest and nothing twice:

| When | Who | What |
|---|---|---|
| While working | implementer | Differential: only the suites touched (`-only-testing:DocumentArchiveTests/<Suite>`). |
| Before opening a pull request | implementer | All macOS unit tests, the localization check (`scripts/check-localization.py`), a build with slow type-check warnings (`OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -warn-long-expression-type-checking=300'`; CI's older Xcode times out on long SwiftUI expressions), and the UI tests of the screens the change touches (iPhone, iPad, Mac) when it changes UI or navigation. |
| Review | reviewer | No second run of the unit tests (CI runs them). The UI tests of the changed screens, with their screenshots, as the test report in the review. |
| Every pull request that changes the app | CI (`ci.yml`) | Builds for macOS and iOS and all unit tests on macOS and the iPhone simulator with the pinned Xcode and warnings as errors (required checks), gitleaks. The same build and the macOS unit tests with the next Xcode (`build (macOS, next Xcode)`, not required). Doc-only pull requests (`docs/`, Markdown, issue templates, labels, …; see `scripts/app-changes.py`) skip the build and test jobs; skipped jobs count as passed. gitleaks always runs. Pushes to `main` run everything. |
| Every night | CI (`ui-tests.yml`) | The full UI suite on the hosted runners: iPhone, iPad (older iOS, 26.x) and the Mac. A failure is handled like a bug report. |
| Every night | CI (`nightly-tests.yml`) | The macOS unit tests in German and with Thread Sanitizer (`TestPlans/Nightly.xctestplan`). Also runs on pull requests that change the workflow or the nightly plan. A failure is handled like a bug report. |
| Before a release | maintainer | A full local run: all unit tests on macOS and iOS; all UI tests on the smallest and the largest iPhone, iPad mini, iPad Pro and the Mac. A manual run of the nightly workflow (Actions → UI tests → Run workflow) for iOS 26. Then the [manual check list](./ios#manual-check-before-a-release). |

Pull requests do not run the UI tests on GitHub; a pull request is merged on
the reviewer's test report plus the required checks.

The maintainer watches the nightly runs (GitHub mails failed scheduled runs).
Before starting or merging a pull request that depends on a nightly run, the
implementer checks its latest run and reports a red one.

## Project layout

| Folder | Content |
|---|---|
| `DocumentArchive/App` | App entry point, menu commands (`AppCommands`), data store setup, one-time migrations, UI test data |
| `DocumentArchive/Model` | SwiftData models (synced through CloudKit) |
| `DocumentArchive/Services` | Import, PDF building, OCR, Mistral client, auto-assignment, maintenance |
| `DocumentArchive/Views` | SwiftUI views shared by macOS and iOS |
| `DocumentArchive/Platform` | Platform wrappers: PDFKit view, VisionKit scanner, sharing |
| `Config` | Shared build settings (`Project.xcconfig`: version, build flags), entitlements and Info.plist additions |
| `DocumentArchiveTests` | Unit tests (Swift Testing) and their helpers in `Support/` |
| `DocumentArchiveUITests` | UI smoke tests (XCUITest, iOS only) |
| `TestPlans` | Test plans of the `DocumentArchive` scheme: `Default` (⌘U, required checks), `Nightly` (German, Thread Sanitizer) |

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

## Text layer in scanned PDFs (#9)

`Services/TextLayer.swift` makes scans and image-only PDFs searchable outside the
app: processing writes the words Apple Vision recognizes into the PDF as invisible
text (each word at its own box, Helvetica subset with a `ToUnicode` map, so copied
umlauts paste correctly). The setting "Add a text layer to scans" (Settings →
General → Text recognition, `UserDefaults` `addTextLayer`, per device) is on by
default.

- **Which PDFs:** scans and photos (the app built them) always; PDFs imported from
  elsewhere only when every page is image-only and none of the skip rules applies
  (encrypted or locked, `/AcroForm`, `/Perms`, `/Outlines`, `/StructTreeRoot`,
  `/OCProperties`, `/PageLabels`, embedded files, XMP conformance such as PDF/A or
  PDF/X, annotations, and images filtered with
  CCITT, JBIG2 or JPEG 2000, also inside nested Form XObjects). Anything that cannot
  be read counts as "skip". Mixed PDFs are skipped. A page needs a layer when it
  has fewer than 15 characters of text, so a second run does nothing. Pages beyond
  the OCR limit (40) stay image-only.
- **Geometry:** every page is rewritten in its displayed geometry (crop box,
  rotation baked into the content), and Vision reads the same upright rendering.
- **Check before replacing:** `TextLayer.check` (same page count, every page
  renders within a pixel tolerance of the original, as a whole and in every tile of
  a 16 × 16 grid so a lost stamp is caught, at most 10 % + 20 KB larger); otherwise
  the old PDF stays and the processing note says why.
- **Words** are written as one glyph run each at the font's own advance widths,
  stretched only through the text matrix. Core Text's line drawing added character
  spacing and per-glyph adjustments, which PDFKit on macOS/iOS 26 extracted as
  spaces inside words.
- **Writing back:** `DocumentImporter.replacePDF` replaces `pdfData` only when the
  stored bytes are still the analyzed ones (a sync or edit during the analysis
  wins), then calls `touch()` for the folder copy. `contentHash` stays the hash of
  the original import; `existingDocument(for:)` also compares the stored PDFs of
  documents with the same size, so an exported layered PDF is still a duplicate.
- **Mistral:** the layer always comes from Vision on the device; nothing more is
  sent to Mistral. With Mistral OCR on, `extractedText` still comes from Mistral.

## Files from other apps (#12)

Every file that arrives from outside goes through `ExternalImport` and then
`DocumentImporter.importFile(data:name:origin:cleanup:into:)`, the same pipeline as the file
dialog and drag and drop (duplicate check on the original bytes, photo cleanup,
insert, processing). Each `ExternalImport.Origin` maps to an `ImportOrigin`:
"Open with" is `.interactive` (the user's cleanup setting); the watch folder and
the share queue are to be `.unattended` (automatic cleanup unless the setting is
Off). Imports are `async`; `ExternalImport` runs them one after another. `App/OpenURLHandler.swift` is the app's **only** URL entry point:
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

## Photo cleanup (#20)

Photos imported as image files, from Photos or by drag and drop can be straightened
and cleaned up before they become a PDF (Settings → General → Import, per device in
`UserDefaults`: "Clean up photos" Off / Automatic, default **Off** for now, and
"Default filter", default Color). PDFs and VisionKit camera scans are never changed.

- **Pipeline** (`Services/ImageCleanup.swift`, pure Vision + Core Image, no UI):
  `detectPage` finds the page with `DetectDocumentSegmentationRequest` and falls back
  to `DetectRectanglesRequest` when that finds nothing **or throws**; it returns `nil`
  for (almost) the whole image. The iOS simulator uses rectangle detection only: its
  segmentation model returns arbitrary quads with high confidence. `apply` does the perspective correction
  (`CIPerspectiveCorrection`), quarter turns and the filter: Original, Color
  (`CIDocumentEnhancer`, fallback `CIColorControls`), Grayscale, Black & White (Otsu
  threshold from a `CIAreaHistogram`, shifted by `bwOffset` −0.2 … +0.2, then
  `CIColorThreshold`).
- **Coordinates:** `PageQuad` is normalized with the origin **lower-left** (Vision and
  Core Image). `QuadGeometry` is the only place that converts to upper-left view
  coordinates.
- **Core Image context:** one shared context (`ImageCleanup.sharedContext`); tests and
  devices without Metal render in software, and pixel tests use tolerances.
- **Unattended crops:** a page nobody looked at (Automatic, and #12's watch folder and
  share queue) is cropped only when the detection's confidence is at least 0.8 **and**
  the page covers at least half of the photo (`ImageCleanup.unattendedSettings`);
  otherwise the whole photo gets only the filter. The original photo is not kept.
- **Memory:** `PendingImport` keeps the original bytes (for the hash), previews of at
  most 1200 px (detection runs on them; the quad is normalized) and the detected
  settings. `DocumentImporter.makeDocumentData` decodes each page at 3000 px from the
  original bytes, cleans it up and hands it to `PDFBuilder.makePDF(pageCount:page:)`,
  which draws and releases it before the next one. `importCleaned` inserts the result;
  #22's vault import builds on `makeDocumentData`.
- **Import contract:** `importFiles(_:origin:cleanup:into:)`,
  `importFile(data:name:origin:cleanup:into:)` and `importImageData(_:cleanup:into:)`
  are `async` and do the heavy work off the main actor. A `nil` mode means
  `CleanupMode.mode(for: origin, setting:)`. The duplicate check runs on the
  **original** bytes before any cleanup (and once more before the insert, for a
  concurrent import of the same file); `contentHash` is the original's hash. The text
  layer (#9) runs on the cleaned PDF as for any import.
- Images are loaded through `ImageCoding.orientedImage(from:maxPixelSize:)` (EXIF
  orientation applied) everywhere: importer, cleanup and `PDFBuilder`.
- Tests use `TestSupport.photographedPage(lines:corners:)`, a rendered page with a known
  perspective on a generated desk.
- **Part 2** adds "Review before saving" with the editor sheet (corners, filters,
  rotation, "Save all") and makes it the default.

## Print, copy and share (#19)

- **Print…** (⌘P) is a `DocumentCommands` group in `App/AppCommands.swift`, also active on
  iPadOS (menu bar and ⌘-hold overlay). It reads the `documentActions` FocusedValue, which
  `ContentView` sets from the selection: only the one open document, never a multi-selection.
  The same item is in the detail view's "More" menu and the list's single-document context
  menu (`DocumentActionItems`). `PrintJob` holds the PDF and the job name (the title);
  `Platform/DocumentPrinter.swift` shows the system panel (macOS: scaled to the page, for the
  key window; iOS: the AirPrint sheet, a form sheet on iPad).
- **Copy PDF / Copy Text** are menu items only; ⌘C is not overridden (maintainer decision).
  `ClipboardContent` decides what is copied (testable without a pasteboard), `Platform/Clipboard.swift`
  writes it: on macOS the PDF data plus the URL of a copy named like the export (paste into
  Finder creates the file, into Mail attaches it), on iOS an item provider with the name.
  "Copy Text" copies plain text: Mistral's Markdown is converted by `MarkdownNotes.plainText`
  (table rows become tab-separated cells), text from the PDF or Apple Vision is copied as is.
- **File names** come from `Services/FileNaming.swift` (owner of the rules, also used by #10):
  invalid and control characters become "-", whitespace is collapsed, spaces and dots trimmed,
  exactly one ".pdf", at most 240 UTF-8 bytes cut between characters; `unique` adds " (2)", " (3)".
- **`PDFTransfer`** lists a file representation (writes `<name>.pdf` into `ExportFolder`) before
  the data representation, so receivers that ignore a suggested name still get the chosen one.
  The PDF is read only when a receiver asks for it. `ExportFolder` (the app's `Exports` folder in
  the temporary directory) is emptied at launch on every platform and when the Mac app quits.
- **Share as…** (detail "More" menu, `ShareOptionsSheet`) edits the name before sharing or
  exporting; the toolbar's Share button keeps the default name.
- **Markdown notes**: `notes` stays a plain `String` (no model change; older versions show the
  source). `NotesView` in the inspector shows the note rendered from `MarkdownNotes.blocks`
  (headings `#`–`###`, bullet, numbered and read-only task items, quotes, rules, paragraphs, code
  fences verbatim) with "Edit Notes" to change the source; empty notes start in the editor. Inline
  formatting comes from `AttributedString(markdown:)` (inline only), with the text as it is when
  parsing fails. Bare URLs and e-mail addresses are linked with `NSDataDetector`; only `http`,
  `https`, `mailto` and `tel` links are kept, everything else stays text. On macOS a block's link
  addresses are its tooltip. Search uses the raw text. Lines inside a code fence are never parsed,
  also in "Copy Text", which is only enabled when the converted text is not empty.

## External services

Documents leave the device only through features the user turns on:

- **iCloud** (CloudKit private database) for sync.
- **The folder copy** (off by default): the provider of the chosen folder
  (iCloud Drive, Dropbox, …) receives the PDFs, the recognized text and the
  metadata in readable form. The settings section says so.
- **Mistral AI** for OCR and auto-assignment, only with an API key in the
  settings and the corresponding switch on. Without a key or on errors, the
  app falls back to Apple Vision and the local rules.
- **The pasteboard and the printer**, only by the user's action: copied PDFs
  and text reach the user's other Apple devices through Universal Clipboard
  for a short time (the system's normal behavior); printing goes to the
  printer the user picks.

New features that send data anywhere else need this stated in the plan and a
setting to turn them off. API keys are stored in the Keychain, never in
`UserDefaults`, files or logs.

### Privacy manifest and export compliance

`DocumentArchive/PrivacyInfo.xcprivacy` is copied into the app on every
platform. It declares:

- **No tracking** and no tracking domains.
- **Collected data:** "Other User Content", linked, no tracking, for app
  functionality: Mistral receives documents under the user's own API key
  and may keep them for a while. iCloud and the folder copy go to the user's
  own storage and are not "collected". The App Store Connect privacy label
  must say the same (see [Releases](./process#releases)).
- **Required-reason APIs:** `UserDefaults` with `CA92.1` (the app's own
  settings) and file timestamps with `3B52.1` (the folder copy reads
  modification dates in the folder the user chose). Nothing reads timestamps
  of files inside the app container (`C617.1`), the boot time, the disk space
  or the active keyboards. An App Group (#12's share extension) adds `1C8F.1`.

`scripts/check-privacy-manifest.py` (in `build (macOS)`; its `--self-test` in
the `changes` job) searches the app's Swift files for the symbols of each
required-reason category and fails when a category is used but not declared,
or declared but no longer used. Comment lines and `setAttributes(` (writing a
date is not a read) do not count. When it fails, declare the category with
the right reason from Apple's list, or remove the declaration, and add a new
symbol to the script's list when it misses one. `PrivacyManifestTests` check
the bundled file.

**Export compliance:** `ITSAppUsesNonExemptEncryption` is `NO` (build setting
`INFOPLIST_KEY_ITSAppUsesNonExemptEncryption`): the app only uses HTTPS and
CryptoKit hashing, which are exempt. A feature that adds encryption (#22's
vault) checks this again.

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
  iPhone simulator on every pull request that changes the app, and scans for
  credentials with gitleaks on every pull request (see [Test strategy](#test-strategy)
  and [Secrets](#secrets)).
- Dependabot opens weekly update pull requests for GitHub Actions.
- GitHub Actions are pinned to commit SHAs; workflows run with read-only
  permissions unless a job needs more.
