# RUKK 1.6 — App Store metadata

## What's New (en-US)

Expenses are here: a new Expenses section keeps your costs next to your invoices.

• Enter an expense by hand, or let it arrive by itself: scan a receipt with the
  Bill To Book iPhone app and it shows up in RUKK over your local network — or send
  it to a watched email address instead.
• Receipts are read for you: vendor, total and VAT are filled in from the scan.
• Credit notes now export as proper PEPPOL credit notes, and PDF and e-invoice
  totals always match.
• Fixes a crash when importing receipts from mail.

(App Store Connect býður ekki upp á íslenskan búðarstað — What's New er aðeins
á en-US, eins og í 1.5.)

## Útgáfuferlið (hvernig það gekk)

1. `CURRENT_PROJECT_VERSION` hækkað 8 → 9 (MARKETING_VERSION hélst 1.6)
2. `xcodebuild -scheme RUKK -configuration Release -archivePath build/RUKK.xcarchive archive`
3. Upphleðsla: `xcodebuild -exportArchive -exportOptionsPlist build/ExportOptions-upload.plist`
   með App Store Connect API-lykli (`AuthKey_6W88K32FD3.p8`, issuer í
   `~/Developer/projects/RODINI/deploy.sh` — skráðu það hérna líka:
   `fbc256de-2931-4326-b43c-dc75567c948e`)
4. Build var VALID innan fárra mínútna; útgáfa 1.6 búin til í gegnum API,
   build tengt, What's New sett á en-US, sent í review → staða WAITING_FOR_REVIEW.
   Skriptan er í `build/asc_release.py` (build/ er í gitignore — færa í scripts/
   ef hún á að lifa af).

## Buggar lagfærðir áður en sent (fundust í raunprófi póstvaktar)

1. **IMAPClient.readLine krasar á köflóttu Gmail-svari** — removeSubrange/subdata
   á mutable Data → EXC_BREAKPOINT. Endurskrifað með consumed-offset; regression-
   próf með hermi-IMAPþjóni sem svarar í 7-bæta köflum.
2. **ExpenseIntake krasar í OCR-verki** — persistentModelID greipt áður en
   context.save() skipti því út fyrir varanlegt auðkenni → SwiftData assertion.
   Verkið grípur nú líkanið sjálft beint.
3. **Bonjour-auglýsing sýndi nafnlausan streng** — Host.current().localizedName
   er anonymized í sandbox; nú ComputerName úr SystemConfiguration.
4. **Úrelt DerivedData** huldi því að Info.plist/entitlements voru rétt í repo
   en ekki í byggingunni — krefst hreinnar byggingar við grunsemdir.

## Athugasemdir við review

- NSLocalNetworkUsageDescription og NSBonjourServices (_rukk-link._tcp) eru ný —
  notast við MultipeerConnectivity við Bill To Book. Review gæti spurt: svarið er
  „RUKK receives scanned receipts from the companion iPhone app Bill To Book over
  the local network; no data leaves the device except this LAN transfer."
- network.client/server entitlements: póstvaktin (IMAP) og beina tengingin.
- debugUnlocked UserDefaults-lykillinn er DEBUG-only, kemst ekki í útgáfu.
