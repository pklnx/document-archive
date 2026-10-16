# iPhone and iPad

The app is one target for macOS, iOS and iPadOS. Every change must work on all
three; this page covers running and checking the iPhone and iPad versions.

## Simulators

Xcode installs the iOS runtime of its version. `scripts/pick-simulator.py`
picks a simulator by screen size (newest runtime only), the same way CI does:

```sh
python3 scripts/pick-simulator.py iphone smallest   # e.g. iPhone 17e
python3 scripts/pick-simulator.py ipad largest      # e.g. iPad Pro 13-inch
```

Run the unit tests on the iPhone simulator (this is the required CI check
`test (iOS)`):

```sh
xcodebuild test -project DocumentArchive.xcodeproj -scheme DocumentArchive \
  -destination "platform=iOS Simulator,id=$(python3 scripts/pick-simulator.py iphone smallest)" \
  CODE_SIGN_IDENTITY=-
```

Run the UI smoke tests (any iPhone or iPad simulator):

```sh
xcodebuild test -project DocumentArchive.xcodeproj -scheme DocumentArchiveUITests \
  -destination "platform=iOS Simulator,id=$(python3 scripts/pick-simulator.py ipad smallest)" \
  CODE_SIGN_IDENTITY=-
```

To look at the app with the same sample data, start it with the launch argument
`-UITestSeed` (Xcode: Product → Scheme → Edit Scheme → Run → Arguments). Nothing
is saved in that mode.

`CODE_SIGN_IDENTITY=-` signs ad hoc ("Sign to Run Locally"); it needs no team.
The Keychain tests fail without a signature on the simulator.

The simulator has no camera, so the "Add" button falls back to the file
importer there. The scan import itself is covered by `ScanImportTests` through
the `ScannedPages` protocol, without a camera.

### iPad multitasking

- **iPadOS 26 and later:** check windows resized to their narrowest width and
  the menu bar.
- **Split View (½, ⅓) and Slide Over** only exist up to iPadOS 18. Install an
  iPadOS 18 runtime in Xcode → Settings → Components → Other Installed
  Platforms (+), then create an iPad simulator with it. CI only has the
  image's default runtime, so these checks are manual.

## On a real device

### Now: free Apple ID ("Personal Team")

1. Xcode → Settings → Accounts → add your Apple ID.
2. Create `Config/Local.xcconfig` (it is in `.gitignore`):

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   DA_CLOUDKIT_ENABLED = NO
   ```

   The team ID is shown in Xcode → Settings → Accounts.
3. Connect the device, select it as the run destination and run.

Limits of a Personal Team build: it expires after **7 days** and must be
installed again; no iCloud/CloudKit and no App Groups (so no sync and no share
extension). Keep `DA_CLOUDKIT_ENABLED = NO`.

### Later: paid Apple Developer Program

- Set `DA_CLOUDKIT_ENABLED = YES` in `Config/Local.xcconfig` for the signed
  build. The app only opens a CloudKit store when this flag is on (and, on
  macOS, the build has the CloudKit entitlement); being signed in to iCloud is
  not enough. Unsigned, ad-hoc and CI builds keep the repository default `NO`.
- Enable the iCloud container and, for #12, the App Group in *Signing &
  Capabilities*.
- Distribute through TestFlight instead of installing from Xcode.

## Known gaps

Need a real device:

- scan quality with the real camera (edge detection, lighting);
- Photos with originals stored in iCloud Photos;
- performance with many documents and memory use with large PDFs.

Need the paid account:

- iCloud sync between devices;
- the share extension (#12).

## Manual check before a release

On the smallest and largest iPhone and on iPad mini and iPad Pro, in portrait
and landscape:

| Area | Check |
|---|---|
| Navigation | sidebar → list → document and back; a new import opens the document |
| List | swipe actions, context menu, sort, search, empty states |
| Selection | "Select", Select All, checkmarks without opening a document; bottom toolbar on iPhone and narrow iPad windows, bulk actions column on wide iPads; select 3, narrow the search to 1 and check that only 1 is changed; Done ends the selection; in a narrow iPad window ⌘-click with a pointer selects several documents without edit mode, the list then covers `BulkActionsView` and there is no bottom toolbar, so the context menu (secondary click) is the way to act on them |
| Document | PDF view, inspector (sheet on iPhone, column on iPad), share, export |
| Sheets and dialogs | settings, rule editor, alerts and delete confirmations can be dismissed |
| Import | Files (several files), Photos (HEIC), camera scan on a device, drag and drop on iPad; "Open in…" from Files (file stays where it is) and "Copy to Document Archive" from Mail (the copy in `Documents/Inbox` is removed), with the app running and not running: the document opens, a second time it is reported as a duplicate; with "Clean up photos" set to Automatic, a photo of a letter on a desk is straightened and a receipt lying on a letter is not cut out |
| iPad | keyboard shortcuts (⌘O, ⌘,) and menu bar, narrow windows, Split View on iPadOS 18; an opened document is not covered by the list, also after rotating with it open; after deleting the open document the list is back |
| Sidebar footer | sync status matches the build (local only on unsigned builds) |
| Saved views | "+" in the Views header opens the editor (popover on iPad, sheet on iPhone) and the pickers push inside it; "Save as View…" from a tag list and from a search; the view's sort menu; "Manage Views…": rename, drag to reorder, delete; a view whose tag was deleted shows the banner and "(deleted)" in the editor |
| Storage Location | "Choose Folder…" opens the folder picker (iCloud Drive, On My iPhone); the copy appears in `Document Archive/`; "Show in Files" opens it or shows the path with a share button; "Back to Default" keeps the files |
