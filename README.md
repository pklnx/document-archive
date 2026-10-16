# Document Archive

> [!WARNING]
> **This project is entirely vibe-coded.** All code, configuration and
> documentation were written by an AI (Claude) under human direction, without
> line-by-line human review. Review it yourself before trusting it with
> important documents, and keep independent backups.

A personal document archive in the style of paperless-ngx for iPhone, iPad and Mac – without a server and without user accounts.
All data is synced between your devices through your private iCloud (CloudKit).

The app is available in English and German.

## Features

- **Add documents:** camera scan (iPhone/iPad, with automatic edge detection), PDFs and images from Files, photos from the library, drag and drop (Mac: also ⌘O), "Open with" in Finder or a drop on the Dock icon (Mac), "Open in…" / "Copy to Document Archive" from Files, Mail and other apps (iPhone/iPad)
- **Text recognition (OCR)** for scans and image-only PDFs (German and English), then **full-text search**
- **Mistral AI** (optional): Mistral OCR for text recognition, Mistral Medium for title, correspondent, type, tags and date
- **Correspondents, document types, tags** and **ASN** (archive serial number), as in paperless; tags can be nested ("Auto › Golf"), and a tag shows the documents of the tags inside it
- **Automatic assignment** with matching rules (any/all words, exact phrase, regex), sender detection and **issue date detection**
- **Duplicate detection:** identical files are skipped on import
- **Inbox** for new documents, favorites, sorting, sharing and PDF export
- **Several documents at once:** select them (Mac: ⌘/⇧-click, ⌘A; iPhone/iPad: "Select") and set tags, correspondent, type, inbox and favorite, analyze them again or delete them together
- **Copy in a folder** (optional, Settings → Storage Location): the app keeps a copy of the archive as plain files in a folder you choose, e.g. in iCloud Drive – one PDF and one JSON file with the details and the recognized text per document. Deleted documents stay in its `Deleted` folder for 30 days. The archive itself stays on the device; reading the folder back (restore, sync between devices) follows in a later version.

## Setup (once)

1. Open `DocumentArchive.xcodeproj` in Xcode.
2. Target **DocumentArchive** → *Signing & Capabilities* → choose your Apple ID / developer team under **Team**.
3. Change the **bundle ID** (`de.patrickklein.DocumentArchive`) if needed. Under **iCloud**, the container
   `iCloud.de.patrickklein.DocumentArchive` must be checked (with another ID: create a new container and enter it in
   `Config/DocumentArchive-iOS.entitlements` and `Config/DocumentArchive-macOS.entitlements`).
4. Run once on **My Mac** and once on the **iPhone/iPad**. Sign in to iCloud with the same Apple ID on all devices.

> iCloud/CloudKit needs a paid Apple Developer Program membership. Without signing, the app runs with local storage only, without sync.

Note: CloudKit schemas start in the *Development* environment. For lasting use, deploy the schema to *Production* in the
[CloudKit Dashboard](https://icloud.developer.apple.com) and install the app through TestFlight or an archive.

## Structure

| Folder | Content |
| --- | --- |
| `DocumentArchive/Model` | SwiftData models: `Document`, `Tag`, `Correspondent`, `DocumentType`, matching rules |
| `DocumentArchive/Services` | PDF building, OCR (Vision, Mistral), auto-assignment, import, sync status |
| `DocumentArchive/Views` | SwiftUI interface (sidebar, list, detail view, editors, settings) |
| `DocumentArchive/Platform` | PDF viewer (PDFKit), document scanner (VisionKit), sharing/export |
| `DocumentArchive/*.xcstrings` | String Catalogs: English source strings with German translations |
| `DocumentArchiveTests` | Unit tests (Swift Testing) |
| `Config` | Entitlements (iCloud, sandbox) and Info.plist additions |

## Development

Workflow (issue → plan → approval → pull request), labels and releases:
[docs/development/process.md](docs/development/process.md).
Setup, project structure, tests and the rules for the data model, localization and external services:
[docs/development/index.md](docs/development/index.md).
Please report security problems privately: [SECURITY.md](SECURITY.md).
