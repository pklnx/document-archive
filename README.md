# Document Archive

> [!WARNING]
> **Dieses Projekt ist vollständig vibe-coded.** Code, Konfiguration und
> Dokumentation wurden von einer KI (Claude) unter menschlicher Anleitung
> geschrieben, ohne zeilenweise menschliche Prüfung. Prüfe es selbst, bevor du
> ihm wichtige Dokumente anvertraust, und behalte unabhängige Sicherungen.

Persönliches Dokumentenarchiv im Stil von paperless-ngx für iPhone, iPad und Mac – ohne Server und ohne Benutzerverwaltung.
Alle Daten werden über deine private iCloud (CloudKit) zwischen den Geräten synchronisiert.

## Funktionen

- **Mistral AI** (optional): Mistral OCR für die Texterkennung, Mistral Medium für Titel, Korrespondent, Typ, Tags und Datum
- **Duplikaterkennung**: identische Dateien werden beim Import übersprungen
- **Hinzufügen**: Kamera-Scan (iPhone/iPad, mit automatischer Kantenerkennung), PDFs und Bilder aus Dateien, Fotos aus der Mediathek, Drag & Drop (Mac: auch ⌘O)
- **Texterkennung (OCR)** für Scans und Bild-PDFs (Deutsch und Englisch), danach **Volltextsuche**
- **Korrespondenten, Dokumenttypen, Tags** und **ASN** (Archiv-Seriennummer) wie in paperless
- **Automatische Zuordnung** über Suchbegriffe (eines/alle Wörter, exakt, Regex) sowie **Erkennung des Ausstellungsdatums**
- **Posteingang** für neue Dokumente, Favoriten, Sortierung, Teilen und PDF-Export

## Einrichtung (einmalig)

1. `DocumentArchive.xcodeproj` in Xcode öffnen.
2. Target **DocumentArchive** → *Signing & Capabilities* → bei **Team** deine Apple-ID / dein Entwicklerteam wählen.
3. Bei Bedarf die **Bundle-ID** (`de.patrickklein.DocumentArchive`) anpassen. Unter **iCloud** muss der Container
   `iCloud.de.patrickklein.DocumentArchive` angehakt sein (bei geänderter ID: neuen Container anlegen und in
   `Config/DocumentArchive-iOS.entitlements` und `Config/DocumentArchive-macOS.entitlements` eintragen).
4. Einmal auf **My Mac** und einmal auf dem **iPhone/iPad** ausführen. Auf allen Geräten mit derselben Apple-ID bei iCloud angemeldet sein.

> Für iCloud/CloudKit wird ein Apple-Developer-Account benötigt (99 €/Jahr). Ohne Signierung läuft die App nur lokal ohne Synchronisation.

Hinweis: CloudKit-Schemas starten in der *Development*-Umgebung. Für den dauerhaften Einsatz das Schema im
[CloudKit-Dashboard](https://icloud.developer.apple.com) nach *Production* übertragen und die App per TestFlight oder Archive installieren.

## Aufbau

| Ordner | Inhalt |
| --- | --- |
| `DocumentArchive/Model` | SwiftData-Modelle: `Document`, `Tag`, `Correspondent`, `DocumentType`, Zuordnungsregeln |
| `DocumentArchive/Services` | PDF-Erzeugung, OCR (Vision), automatische Zuordnung, Import, Sync-Status |
| `DocumentArchive/Views` | SwiftUI-Oberfläche (Seitenleiste, Liste, Detailansicht, Editoren, Einstellungen) |
| `DocumentArchive/Platform` | PDF-Anzeige (PDFKit), Dokumentscanner (VisionKit), Teilen/Export |
| `Config` | Entitlements (iCloud, Sandbox) und Info.plist-Ergänzungen |

## Entwicklung

Ablauf (Issue → Plan → Freigabe → Pull Request), Labels und Releases:
[docs/development/process.md](docs/development/process.md).
Setup, Projektaufbau und Regeln für Datenmodell und externe Dienste:
[docs/development/index.md](docs/development/index.md).
Sicherheitsprobleme bitte privat melden: [SECURITY.md](SECURITY.md).
