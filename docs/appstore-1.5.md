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
• Import fixes: Excel files that used to fail now open, "Unicode Text" CSVs no
  longer arrive as gibberish, and time entries under a minute are no longer lost

## Nýtt í þessari útgáfu (Íslenska)

Dragðu vinnu beint úr BLIZZ yfir í RUKK.

Taktu verkþátt í BLIZZ, slepptu honum á RUKK og reikningsdrögin eru tilbúin.
Aðeins órukkuð vinna fylgir með og hver verkþáttur fær sína fyrirsögn — slepptu
öðrum verkþætti og hann verður að sínum eigin kafla.

Dráttur og sleppa um allt forritið:
• Dragðu reikning úr listanum í Finder eða Mail — PDF-ið fylgir með
• Dragðu línur til að endurraða þeim
• Slepptu Excel-, CSV- eða XML-skrá á viðskiptavinalistann til að flytja hann inn
• Slepptu mynd beint á merkisreitinn í stillingum

Einnig í þessari útgáfu:
• Dökkt útlit, með eigin stillingu (kerfið, ljóst eða dökkt)
• Einfaldara viðmót í tveimur dálkum og forskoðun sem passar alltaf í dálkinn
• Fyrirsagnir á reikningum — settu þær inn með einum smelli
• Viðskiptanúmer sést nú og er breytanlegt á reikningsforminu
• Hraðvirkara með stórum reikningasöfnum
• Lagfæringar í innflutningi: Excel-skrár sem áður brugðust opnast nú, „Unicode
  Text" CSV-skrár koma ekki lengur inn sem stafarugl og tímafærslur undir mínútu
  týnast ekki

## Submission checklist

- [ ] Bump MARKETING_VERSION to 1.5 and CURRENT_PROJECT_VERSION in the project
- [ ] Archive, upload, wait for VALID
- [ ] Create store version 1.5, attach the build — via API
- [ ] What's New on the en-US localization, English first then Icelandic
      (the App Store has no Icelandic storefront locale)
- [ ] Screenshots: consider one showing the drag from BLIZZ landing as an invoice
- [ ] Age rating / privacy unchanged (no new data collection)
- [ ] Submit for review

## Known issues, not fixed in 1.5

Found in review during this cycle and deliberately deferred — decide before submitting:

1. **PDFs are one page.** The renderer opens a single page and the templates are
   framed to one page height, so an invoice of roughly 30+ lines silently loses
   everything past the bottom edge. The most serious of the three.
2. **Credit notes export invalid e-invoices.** UBL type code 381 is written into
   an `<Invoice>` root with negated quantities; PEPPOL requires a `<CreditNote>`
   root and rejects negative totals.
3. **Rounding happens only at XML-print time**, per value, so the sum of the line
   amounts can disagree with the document total (BR-CO-10).
