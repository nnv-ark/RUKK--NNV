# RUKK 1.7 — App Store metadata

## What's New (en-US)

• Receipts with mixed VAT rates (11% and 24%) are now split correctly across
  both rates — including table formats without a "VSK" label (BÓNUS and others).
• Receipt date wins over scan date: expenses from Bill To Book always land in
  the correct VAT period.
• Expenses header now shows a clearly labeled "Fetch mail" button and the
  result of the last check ("1 receipt fetched · 18:03"), and newly arrived
  receipts open automatically.
• App passwords pasted from Google with spaces now just work.
• Line items on invoices get a visible minus button for removing rows.

(App Store Connect býður ekki upp á íslenskan búðarstað — What's New er aðeins
á en-US, eins og í 1.6.)

## What's New — íslensk tillaga (tilvísun)

• Kvittanir með blandaðan VSK (11% og 24%) sundurliðast nú rétt á báða þrepa —
  þ.m.t. töflusnið án „VSK“-merkingar (BÓNUS o.fl.).
• Dagsetning á kvittun ræður yfir skannadag: færslur úr Bill To Book lenda
  alltaf á réttu VSK-tímabili.
• Kostnaðarhausur með sýnilegum „Sækja póst“ takka og stöðu síðustu sóknar;
  nýjar kvittanir opnast sjálfkrafa.
• App-lykilorð af Google með bilum virka beint.
• Vörulínur á reikningum fá sýnilegan mínus-hnapp til að fjarlægja línu.

## Útgáfuferlið

1. `CURRENT_PROJECT_VERSION` 10 → 11, `MARKETING_VERSION` 1.6 → 1.7
   (1.6 var lokuð fyrir nýjum builds — build 9 var samþykkt).
2. `xcodebuild -scheme RUKK -configuration Release archive`
3. Upphleðsla með `xcodebuild -exportArchive` og App Store Connect API-lykli
   (`AuthKey_6W88K32FD3.p8`, issuer `fbc256de-2931-4326-b43c-dc75567c948e`).
4. EKKI sent í review — notandinn gerir það handvirkt í App Store Connect.

## Breytingar síðan 1.6 (build 9)

- Parser þekkir VSK-töflulínur án vsk-orðs („D 11 2.829 311 3.140“); hver tala
  lesgreind fyrir sig (bil var túlkað sem þúsundaskil — E-lína BÓNUS týndist).
- Kvittunardagur (OCR) ræður alltaf yfir sendingardag úr pósthausum.
- Póstvakt: app-lykilorð hreinsuð af bilum/línuskilum við lestur og skrif.
- Kostnaður: „Sækja póst“ takki með texta, stöðulína póstvaktar, sjálfvirk
  fókusfæring á nýjar færslur (póstur og bein tenging).
- Reikningslínur: sýnilegur mínus-hnappur (daufur, skárnar við svif).
- 151 einingapróf græn.
