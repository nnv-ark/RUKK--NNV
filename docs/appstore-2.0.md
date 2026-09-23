# RUKK 2.0 — App Store

## Af hverju 2.0

1.9 (build 13) er komið í verslun (útgáfufærslan þar heitir „1,9" — komma,
innsláttarvilla sem ekki verður breytt eftir á; hún hverfur af forsíðunni
þegar 2.0 tekur við). Bæði 1.9 og build 13 eru því upptekin. Þetta er auk
þess stærsta breytingin síðan 1.0: síminn kemur inn sem fullgildur sendandi
og fyrirtækjaskráin fer á milli tækja.

## Í þessari útgáfu

- **Pörun við síma.** Óþekktur sími bíður samþykkis í RUKK og auðkennið er
  munað. Áður var hverju boði á staðarnetinu svarað já.
- **Staðfesting.** Hver móttekin kvittun fær ack til baka
  (stored/duplicate/rejected) svo síminn viti hvort hún komst — og geti
  fallið í póstinn ella.
- **Engin tvískráning.** `Expense.receiptNumber` og vika af glugga: sama
  kvittun sem berst tvisvar (t.d. beint og svo í pósti) verður ein færsla.
- **FELAG-skráin til símans.** Snið 3 auglýsir hlutverk (`felag,receipts`)
  og svarar `felag.pull` með skránni úr sameigninni. RUKK ritstýrir henni
  ekki — FELAG gerir það — svo FELAG þarf ekki að vera í gangi.
- **Kennitala ræður.** Kvittunarhaus ber kennitölu; pörun fyrirtækja fer
  eftir henni fyrst, svo nafni, loks virku fyrirtæki. `Kt:` lína er líka
  lesin úr pósti.
- **Mánuðir í kostnaðarlistanum**, sem leggja má saman, hver með samtölu.
- Pörunarglugginn ber nafn símans og segir berum orðum þegar nafnið kemur
  af staðarnetinu en ekki frá símanum sjálfum (eldri Bill To Book) — það
  gæti þá verið annað tæki, t.d. hermir á sömu vél.

## Útgáfuferlið (22. sept. 2026)

1. 161 einingapróf græn (2 sleppt — MigrationCheck krefst
   `RUKK_MIGRATION_STORE`).
2. `MARKETING_VERSION` 1.9 → 2.0, `CURRENT_PROJECT_VERSION` 13 → 14.
3. `xcodebuild archive` og `-exportArchive` (method `app-store-connect`,
   destination `export`), svo `xcrun altool --upload-app -t macos` með
   API-lyklinum. UPLOAD SUCCEEDED, Delivery UUID
   8d6a5636-71d5-4937-aa09-e045cc6f38c6.
4. Útgáfa 2.0 stofnuð, What's New sett (íslenska, eins og lýsingin).
5. Byggingin sett í `/Applications` til prófunar á móti síma; eldri
   App Store útgáfa lögð til hliðar sem `RUKK-1.9-appstore.app`.

## Ekki prófað

Beina tengingin við síma hefur ekki verið keyrð enda-í-enda: Bill To Book
1.2 (3) er nýkomið í verslun en ber hvorki nafnreitinn né neitt sem reynir
á FELAG-skrána. Prófa þarf pörun, staðfestingu og skrána með síma áður en
hægt er að treysta þeim í raunnotkun.

## Bygging 15 (23. sept. 2026)

Byrjunarskjárinn var daufur og bar gamla merkið. Þessi bygging lagar það:

- **Lifandi forritsmerki.** Kaupskjárinn sækir `NSApplication.shared
  .applicationIconImage` í stað gamallar `Logo`-myndar, 112 pt, óklippt —
  svo merkið á skjánum er alltaf það sama og í Dock og Finder.
- **Nýtt yfirbragð.** Heitið í ávalri feitletrun, kostirnir á spjaldi úr
  `.regularMaterial`, bakgrunnur með halla úr `rukkBlushTop` í `rukkWindow`.
- **Daufbleikir gluggar.** `rukkWindowTint()` setur `NSWindow.backgroundColor`
  á `NSColor.rukkWindow` — #FDF5F8 í ljósu, #231B1F í dökku — svo liturinn
  fylgir útliti kerfisins og nær líka undir hliðarstikuna.

Útgáfuferlið eins og fyrir byggingu 14: 161 einingapróf græn (2 sleppt),
`CURRENT_PROJECT_VERSION` 14 -> 15, `xcodebuild archive` og
`-exportArchive`, svo `xcrun altool --upload-app -t macos`. UPLOAD
SUCCEEDED, Delivery UUID 14593ae4-7684-488b-9032-84bf237d8441. Byggingin
sett í `/Applications` og kaupskjárinn skoðaður: merkið rétt, glugginn
bleikur, fótur segir "Útgáfa 2.0 (15)".

## Sent í yfirferð (23. sept. 2026)

Útgáfa 2.0 með byggingu 15 var send í yfirferð kl. 02:46 UTC
(`reviewSubmissions` a3fb1998-3623-473d-aa0c-22180f54aa6d). Staða:
WAITING_FOR_REVIEW, útgáfa eftir samþykki (`AFTER_APPROVAL`) — þ.e. hún
fer ekki sjálfkrafa í verslun fyrr en ýtt er á hnappinn.

## Athugasemd frá App Review (23. sept. 2026)

Apple hafnaði 2.0 (15) undir **2.4.5(i)** — ekki vegna galla heldur vegna
spurningar: hvar notar forritið réttindin `com.apple.security.network.server`?
Apple tók fram að ekki þyrfti nýja byggingu, bara svar í Resolution Center.

Svarið (sent kl. 08:23): réttindin eru fyrir beinu tenginguna við Bill To
Book. RUKK er móttökuendinn — `MCNearbyServiceAdvertiser` auglýsir
`_rukk-link._tcp` á staðarnetinu og tekur við tengingu frá símanum. Þar sem
RUKK hlustar en hringir ekki, dugar `network.client` ekki eitt og sér.
`NSBonjourServices` og `NSLocalNetworkUsageDescription` eru þegar í
Info.plist fyrir sömu virkni.

Lærdómur fyrir næstu útgáfur: ný réttindi kalla á skýringu, helst í
"Notes" reit yfirferðarinnar strax við innsendingu.
