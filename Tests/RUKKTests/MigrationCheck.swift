//  MigrationCheck.swift — RUKKTests
//  Opnar AFRIT af raunverulegum SwiftData-grunni með nýja skemanu (Invoice og
//  Expense með vskilAudkenni) og gengur úr skugga um að léttflutningurinn
//  haldi öllu til skila áður en ný útgáfa fer í App Store.
//
//  Keyrt handvirkt gegn afriti — aldrei gegn raunverulega grunninum:
//
//      RUKK_MIGRATION_STORE=/slod/ad/afriti/default.store \
//          swift test --filter MigrationCheck
//
//  Án breytunnar sleppir prófið sér, svo venjuleg keyrsla er óbreytt.
//
//  © 2026 NNV ehf.

import XCTest
import SwiftData
@testable import RUKK

final class MigrationCheck: XCTestCase {

    @MainActor
    func testRaunGrunnurFlyturYfir() throws {
        guard let slod = ProcessInfo.processInfo.environment["RUKK_MIGRATION_STORE"] else {
            throw XCTSkip("RUKK_MIGRATION_STORE ekki sett — sleppi flutningsprófi.")
        }
        let url = URL(fileURLWithPath: slod)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Finn ekki grunninn á \(url.path)")

        // Opnun með nýja skemanu er flutningurinn sjálfur. Ef hann klikkar
        // kastar þetta hér — nákvæmlega það sem myndi gerast í ræsingu.
        let config = ModelConfiguration(url: url)
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self,
                 AppSettings.self, CustomStatus.self, Expense.self,
            configurations: config
        )
        let ctx = ModelContext(container)

        let reikningar = try ctx.fetch(FetchDescriptor<Invoice>())
        let kostnadur = try ctx.fetch(FetchDescriptor<Expense>())
        let tengilidir = try ctx.fetch(FetchDescriptor<Contact>())
        print("FLUTNINGUR: \(reikningar.count) reikningar, \(kostnadur.count) kostnaðarfærslur, \(tengilidir.count) tengiliðir")

        XCTAssertFalse(reikningar.isEmpty, "Enginn reikningur skilaði sér — flutningurinn tapaði gögnum.")

        // Gömlu raðirnar eiga að koma tómar inn — ekki allar með sama gildi.
        let fyrirUthlutun = reikningar.filter { !$0.vskilAudkenni.isEmpty }
        XCTAssertTrue(fyrirUthlutun.isEmpty || Set(fyrirUthlutun.map(\.vskilAudkenni)).count == fyrirUthlutun.count,
                      "Tvær eða fleiri raðir deila auðkenni — sjálfgefna gildið hefur afritast.")

        // Innihaldið á að vera ósnert. Tilboð bera númer í estimateNumber og
        // hafa number tómt — það er eðlilegt ástand, ekki tap.
        let tilbod = reikningar.filter(\.isEstimate)
        print("FLUTNINGUR: \(tilbod.count) tilboð, \(reikningar.count - tilbod.count) útgefnir reikningar")
        for r in reikningar {
            print("REIKNINGUR: númer=\"\(r.number)\" tilboð=\(r.isEstimate) tilboðsnúmer=\"\(r.estimateNumber)\" staða=\(r.statusRaw) utgefinn=\(r.isIssued) dags=\(r.issueDate)")
            if r.isEstimate {
                XCTAssertFalse(r.estimateNumber.isEmpty, "Tilboð án númers eftir flutning.")
            } else if r.status != .draft {
                // Uppköst hafa réttilega ekkert númer — það kemur þegar læst er.
                XCTAssertFalse(r.number.isEmpty, "Útgefinn reikningur án númers eftir flutning.")
            }
        }
        for k in kostnadur {
            XCTAssertFalse(k.vendor.isEmpty && k.expenseDescription.isEmpty,
                           "Kostnaðarfærsla tóm eftir flutning.")
        }

        // Úthlutunin sjálf — hvert auðkenni einstakt og ekkert tómt eftir.
        VskSummaryExporter.tryggjaAudkenni(invoices: reikningar, expenses: kostnadur, in: ctx)
        let audkenni = reikningar.map(\.vskilAudkenni) + kostnadur.map(\.vskilAudkenni)
        XCTAssertFalse(audkenni.contains(""), "Röð stóð eftir án auðkennis.")
        XCTAssertEqual(Set(audkenni).count, audkenni.count, "Auðkenni endurtekið milli raða.")

        // Önnur opnun á að lesa sömu auðkenni aftur — þau eru vistuð, ekki
        // endurúthlutuð í hverri ræsingu.
        let aftur = ModelContext(container)
        let sami = try aftur.fetch(FetchDescriptor<Invoice>())
        XCTAssertEqual(Set(sami.map(\.vskilAudkenni)), Set(reikningar.map(\.vskilAudkenni)),
                       "Auðkenni héldust ekki milli opnana.")
    }
}
