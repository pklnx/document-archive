# Security Policy

## Reporting a vulnerability

Please report security problems **privately** through
[GitHub's private vulnerability reporting](https://github.com/pklnx/document-archive/security/advisories/new).
Do not open a public issue.

Include what you found, how to reproduce it and what an attacker could do with it.

## Supported versions

Only the latest state of the `main` branch is supported. There are no
maintained older versions.

## What to expect

This is a hobby project maintained in spare time. Reports are handled on a
best-effort basis, without fixed response times. You will be credited in the
advisory unless you prefer otherwise.

This project is entirely AI-written (see the [README](README.md)).
Independent review is welcome.

## Scope

In scope, for example:

- Documents or metadata leaving the device other than through iCloud (CloudKit
  private database) or, when turned on, the Mistral API
- Exposing the Mistral API key outside the Keychain (files, logs, defaults)
- Other apps or users on the same device reading the archive through the app
- Crafted PDFs or images that make the app run code or write outside its data

Out of scope:

- Unsigned development builds, which run without the macOS App Sandbox
- Data that Apple or Mistral process as part of their documented services
- Unencrypted archive data on a device without FileVault or a passcode
- Vulnerabilities in Apple frameworks without a demonstrated impact on this project
