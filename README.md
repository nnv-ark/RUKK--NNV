<h1 align="center">RUKK</h1>

<p align="center">
  A native macOS billing &amp; invoicing app for Icelandic businesses.<br>
  Built entirely in Swift with SwiftUI &amp; SwiftData.
</p>

<p align="center">
  <a href="https://github.com/nnv-ark/kula-invoicing/actions/workflows/ci.yml"><img src="https://github.com/nnv-ark/kula-invoicing/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6.0-orange.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/license-MIT-green.svg" alt="MIT">
</p>

---

RUKK is a focused, offline-first invoicing app. Your financial data stays on your Mac
(SwiftData / local store) — no accounts, no cloud, no tracking. The invoice layout follows
the standard Icelandic format, and invoices can be exported as **PDF** or as a
**TS-136 / PEPPOL BIS Billing 3.0** electronic invoice (UBL 2.1 XML).

![RUKK dashboard](docs/dashboard.png)

## Features

- **Multiple companies** — keep several businesses in one app and switch between them.
  Invoices and customers are fully separated per company, each with its own invoice numbering.
- **Icelandic invoice template** — correct header order, VAT (VSK) per line item,
  amounts with/without VAT, kennitala, bank claim number, legal footer (reglugerð nr. 505/2013).
- **Dashboard** — Payday-style overview per company: 12-month sales, collected vs. outstanding,
  collection rate, average payment speed, overdue invoices, and a monthly sales chart.
- **Customers** — per-customer dashboard (invoices, totals, payment speed, year-over-year),
  notes, and import from the macOS **Contacts** app.
- **Export** — PDF, electronic invoice (UBL/TS-136 XML), or batch-export *all* invoices
  (PDF + XML) to a folder at once.
- **Drag and drop** — drag a verkþáttur out of [BLIZZ](https://github.com/nnv-ark/BLIZZ) and
  drop it on RUKK: only unbilled time comes across, each task arrives under its own heading,
  and you get a draft invoice (or the lines are added to the invoice already open). Drag an
  invoice out to Finder or Mail as a PDF, drag line items to reorder them, drop a customer
  list or a logo where it belongs.
- **Native macOS** — proper menu commands (⌘N, ⌘P, ⌘E …), Page Setup, print, "Open in Preview",
  email via Mail with the PDF attached, Settings scene, light/dark mode.
- **Customisable** — logo, font family &amp; sizes, text colour, paper size (A4 / US Letter),
  custom invoice statuses, per-company defaults.
- **Localised** — user interface in Icelandic.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (Swift 6)

## Building &amp; running

Open the Xcode project and run:

```sh
open RUKK.xcodeproj
```

Then select the **RUKK** scheme and press **⌘R**.

The same sources also build as a Swift package (used for the test suite):

```sh
swift build      # compile the RUKK library
swift test       # run the unit tests
```

> The app entry point (`RUKKApp.swift`) is excluded from the SwiftPM library target so the
> tests can link cleanly; the Xcode app target includes it.

## Project structure

```
Sources/RUKK/
  RUKKApp.swift          App entry point + menu commands
  FocusedActions.swift   Menu-command plumbing (⌘N, ⌘P, export …)
  Models/                Invoice, LineItem, Contact, AppSettings (company), CustomStatus, Money
  Views/                 ContentView, Dashboard, invoice list/detail, customers, settings
  Templates/             IcelandicTemplate (SwiftUI → PDF)
  PDF/                   PDF rendering, printing, Page Setup, Preview, email
  Export/                UBL/TS-136 XML exporter, batch exporter
  Import/                Contacts.app importer
Tests/RUKKTests/         Invoice math, settings, and UBL export tests
App/                     Assets, entitlements
```

## Notes on correctness

- All monetary amounts use `Decimal` (never `Double`).
- Totals are **derived**, not stored — change a line item, discount or VAT and totals update.
- VAT is calculated **per line item**, so an invoice can mix rates (0 % / 11 % / 24 %).
- Each invoice records its issuing company, so historical invoices never change when you
  edit a company or switch the active one.

## Electronic invoicing (TS-136 / PEPPOL)

RUKK generates a UBL 2.1 invoice compliant with **PEPPOL BIS Billing 3.0** (the basis of the
Icelandic TS-136 CIUS), with the Icelandic kennitala on EAS scheme `0196`. The XML document is
produced locally; to *transmit* it over the PEPPOL network you still need a PEPPOL access point
(e.g. a service provider) and a participant certificate.

## Tests

```sh
swift test
```

Covers invoice/VAT math, per-company settings resolution, and UBL XML generation.

## License

[MIT](LICENSE) © 2026 Ólafur H. Jónsson

Invoice layout inspired by [Manta](https://github.com/hql287/Manta); RUKK shares no source code with it.
