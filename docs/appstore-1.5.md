# RUKK 1.5 — App Store metadata

## What's New (English)

Drag work straight from BLIZZ into RUKK.

Grab a verkþáttur in BLIZZ, drop it on RUKK, and you have a draft invoice. Only
unbilled time comes across, and each task arrives under its own heading — drop a
second task and it lands as its own labelled section.

Drag and drop throughout:
• Drag an invoice out of the list into Finder or Mail — the PDF goes with it
• Drag line items to reorder them
• Drop an Excel, CSV or XML customer list anywhere on the customer list to import it
• Drop a logo straight onto the logo well in Settings

Also in this version:
• Dark mode, with an appearance setting of its own (system, light or dark)
• A simpler two-column window, and an invoice preview that always fits the pane
• Section headings on invoices — add them yourself with one click
• Viðskiptanúmer is now shown and editable on the invoice form
• Faster with large invoice archives
• Long invoices no longer lose lines: an invoice too long for one page now keeps
  its total on the front page and continues as a time report, page by page
• Import fixes: Excel files that used to fail now open, "Unicode Text" CSVs no
  longer arrive as gibberish, and time entries under a minute are no longer lost

## Submission checklist

- [ ] Bump MARKETING_VERSION to 1.5 and CURRENT_PROJECT_VERSION in the project
- [ ] Archive, upload, wait for VALID
- [ ] Create store version 1.5, attach the build — via API
- [ ] What's New on the en-US localization — English only for this release
- [ ] Screenshots: consider one showing the drag from BLIZZ landing as an invoice
- [ ] Age rating / privacy unchanged (no new data collection)
- [ ] Submit for review

## Known issues, not fixed in 1.5

Found in review during this cycle and deliberately deferred — decide before submitting.
The one-page PDF defect that stood here is fixed in this release.

1. **Credit notes export invalid e-invoices.** UBL type code 381 is written into
   an `<Invoice>` root with negated quantities; PEPPOL requires a `<CreditNote>`
   root and rejects negative totals.
2. **Rounding happens only at XML-print time**, per value, so the sum of the line
   amounts can disagree with the document total (BR-CO-10).
