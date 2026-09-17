# RUKK 1.8 — App Store metadata

## What's New (en-US) — tillaga

• VAT summaries now never lose amounts: any unallocated rounding remainder on
  split-VAT receipts is carried into the exempt tier, so the exported total
  always matches the receipt total.
• Fresh new app icon.
• The main window can be moved by dragging anywhere in the background —
  buttons and text fields work as before.

(App Store Connect býður ekki upp á íslenskan búðarstað — What's New er aðeins
á en-US, eins og í 1.7.)

## What's New — íslensk tillaga (tilvísun)

• VSK-yfirlit glata ekki lengur upphæðum: óúthlutaður afrúnningsmunur á
  sundurliðuðum kvittunum fer sem undanþeginn hluti (þrep 0) svo heildarupphæð
  sé alltaf sú sama og á kvittuninni.
• Nýtt forritsmerki.
• Aðalgluggann má færa með því að draga hvar sem er í bakgrunninum — hnappar
  og textareitir virka óbreytt.

## Útgáfuferlið

1. FyrirtaekiKit-slóð lögð eftir möppuendurskipulagningu:
   - `Package.swift`: `/Developer/FELAG/…` → `/Developer/projects/FELAG/…`
   - `project.pbxproj`: `../../FELAG/FyrirtaekiKit` → `../FELAG/FyrirtaekiKit`
2. `MARKETING_VERSION` 1.7 → 1.8 (1.7 var lokuð fyrir nýjum builds —
   build 11 var samþykkt), `CURRENT_PROJECT_VERSION` 11 → 12.
3. 152 einingapróf græn (1 skipped), þ.m.t. ný afrúnningspróf
   VskSummaryExporter.
4. `xcodebuild -scheme RUKK -configuration Release archive`
5. Upphleðsla með `xcodebuild -exportArchive` og App Store Connect API-lykli
   (`AuthKey_6W88K32FD3.p8`, issuer `fbc256de-2931-4326-b43c-dc75567c948e`).
6. EKKI sent í review — notandinn gerir það handvirkt í App Store Connect.

## Breytingar síðan 1.7 (build 11)

- VskSummaryExporter: óúthlutaður munur (upphæð sem ratar á ekkert VSK-þrep)
  fer sem þrep 0 — heild innkaupanna í VSKIL er alltaf jöfn `amount`.
- Nýtt forritsmerki (RUKK-NYTT.icon → App/RUKK.icon).
- Aðalgluggi færanlegur með því að draga í bakgrunn
  (`isMovableByWindowBackground`).
- 152 einingapróf græn.
