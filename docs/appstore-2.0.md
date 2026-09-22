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
