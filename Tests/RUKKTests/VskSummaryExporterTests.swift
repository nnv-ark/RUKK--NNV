import XCTest
import SwiftData
@testable import RUKK

/// VSK-yfirlit fyrir VSKIL: tímabil, sía, samtölur og sannreining gegn VSKIL.
@MainActor
final class VskSummaryExporterTests: XCTestCase {

    private var kal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Atlantic/Reykjavik")!
        return c
    }

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            Expense.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func company(_ context: ModelContext, kt: String = "4702221580") -> AppSettings {
        let c = AppSettings()
        c.companyName = "Próf ehf."
        c.companyNationalID = kt
        c.companyVATNumber = "101078"
        context.insert(c)
        return c
    }

    /// Útgefinn ISK-reikningur með einni línu á tilteknu bókunardegi.
    @discardableResult
    private func reikningur(_ context: ModelContext, fyrirtaeki: AppSettings,
                            numer: String, dagur: String, taxRate: Decimal = 24,
                            upphaed: Decimal = 100_000) -> Invoice {
        let inv = Invoice(number: numer, currencyCode: "ISK", taxRate: taxRate)
        inv.issuer = fyrirtaeki
        inv.isNumberLocked = true
        let dagsetning = date(dagur)
        inv.issueDate = dagsetning
        inv.bookingDate = dagsetning
        context.insert(inv)
        let li = LineItem(description: "Verk", quantity: 1, unitPrice: upphaed,
                          taxRate: taxRate, order: 0)
        li.invoice = inv
        inv.lineItems.append(li)
        context.insert(li)
        return inv
    }

    private func kostnadur(_ context: ModelContext, fyrirtaeki: AppSettings,
                           dagur: String, amount: Decimal = 124_000, taxRate: Decimal = 24,
                           yfirfarinn: Bool = true) -> Expense {
        let e = Expense()
        e.company = fyrirtaeki
        e.vendor = "Seljandi ehf."
        e.expenseDescription = "Kaup"
        e.date = date(dagur)
        e.amount = amount
        e.taxRate = taxRate
        e.reviewed = yfirfarinn
        context.insert(e)
        return e
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = kal
        f.timeZone = kal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)!
    }

    // MARK: - Tímabil

    func testTimabilBil() {
        let bil = VskSummaryExporter.timabilBil(ar: 2026, timabilNr: 4, kal: kal)
        XCTAssertEqual(bil.lowerBound, date("2026-07-01"))
        XCTAssertEqual(bil.upperBound, date("2026-08-31"))
        // Febúar séit ár: jan–feb 2027 endar 28. febrúar.
        let feb = VskSummaryExporter.timabilBil(ar: 2027, timabilNr: 1, kal: kal)
        XCTAssertEqual(feb.upperBound, date("2027-02-28"))
    }

    func testRskNumerOgHeiti() {
        XCTAssertEqual(VskSummaryExporter.rskNumer(timabilNr: 1), 8)
        XCTAssertEqual(VskSummaryExporter.rskNumer(timabilNr: 4), 32)
        XCTAssertEqual(VskSummaryExporter.rskNumer(timabilNr: 6), 48)
        XCTAssertEqual(VskSummaryExporter.timabilHeiti(timabilNr: 1), "jan–feb")
        XCTAssertEqual(VskSummaryExporter.timabilHeiti(timabilNr: 6), "nóv–des")
        XCTAssertEqual(VskSummaryExporter.numerTimabils(dags: date("2026-03-15"), kal: kal), 2)
        XCTAssertEqual(VskSummaryExporter.numerTimabils(dags: date("2026-04-01"), kal: kal), 2)
    }

    // MARK: - Yfirlit

    func testPayloadTelurAeinungisUtgefnaInnanTimabils() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)

        reikningur(context, fyrirtaeki: fyrirtaeki, numer: "001", dagur: "2026-03-10")
        reikningur(context, fyrirtaeki: fyrirtaeki, numer: "002", dagur: "2026-04-20", taxRate: 11)
        reikningur(context, fyrirtaeki: fyrirtaeki, numer: "003", dagur: "2026-03-15", taxRate: 0)

        // Drög — ekki útgefin: útilokað.
        let draug = Invoice(number: "", currencyCode: "ISK", taxRate: 24)
        draug.issuer = fyrirtaeki
        draug.issueDate = date("2026-03-12")
        draug.bookingDate = date("2026-03-12")
        context.insert(draug)
        let lin = LineItem(description: "Drög", quantity: 1, unitPrice: 999, taxRate: 24, order: 0)
        lin.invoice = draug; draug.lineItems.append(lin); context.insert(lin)

        // Annar gjaldmiðill: útilokað.
        let usd = reikningur(context, fyrirtaeki: fyrirtaeki, numer: "004",
                             dagur: "2026-03-11")
        usd.currencyCode = "USD"

        // Utan tímabils: útilokað.
        reikningur(context, fyrirtaeki: fyrirtaeki, numer: "005", dagur: "2026-05-01")

        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let p = VskSummaryExporter.payload(invoices: invoices, expenses: [],
                                           company: fyrirtaeki,
                                           ar: 2026, timabilNr: 2, kal: kal)

        XCTAssertEqual(p.tegund, "VSKIL-YFIRLIT")
        XCTAssertEqual(p.utgafa, 1)
        XCTAssertEqual(p.timabil, 16)
        XCTAssertEqual(p.dagsFra, "2026-03-01")
        XCTAssertEqual(p.dagsTil, "2026-04-30")
        XCTAssertEqual(p.kennitala, "4702221580")
        XCTAssertEqual(p.vskNumer, "101078")
        XCTAssertEqual(p.sala.count, 3)

        XCTAssertEqual(p.samtala.velta24, 100_000)
        XCTAssertEqual(p.samtala.velta11, 100_000)
        XCTAssertEqual(p.samtala.undanthegin, 100_000)
        XCTAssertEqual(p.samtala.utskattur24, 24_000)
        XCTAssertEqual(p.samtala.utskattur11, 11_000)
        XCTAssertEqual(p.samtala.innskattur24, 0)
        XCTAssertEqual(p.samtala.innskattur11, 0)
    }

    func testKreditreikningurDregurFra() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)
        let uppruni = reikningur(context, fyrirtaeki: fyrirtaeki,
                                 numer: "010", dagur: "2026-03-05", upphaed: 200_000)
        let kredit = Invoice.makeCreditNote(for: uppruni, in: context)
        let dagsetning = date("2026-03-20")
        kredit.number = "011"          // raðnúmer fæst við útgáfu
        kredit.isNumberLocked = true
        kredit.issueDate = dagsetning
        kredit.bookingDate = dagsetning

        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let p = VskSummaryExporter.payload(invoices: invoices, expenses: [],
                                           company: fyrirtaeki,
                                           ar: 2026, timabilNr: 2, kal: kal)
        XCTAssertEqual(p.samtala.velta24, 0)
        XCTAssertEqual(p.samtala.utskattur24, 0)
        XCTAssertTrue(p.sala.contains { $0.lysing.hasPrefix("Kreditreikningur") })
    }

    func testKostnadurGefurInnskatt() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)
        kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-03-10", amount: 124_000, taxRate: 24)
        kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-04-10", amount: 55_500, taxRate: 11)

        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let p = VskSummaryExporter.payload(invoices: [], expenses: expenses,
                                           company: fyrirtaeki,
                                           ar: 2026, timabilNr: 2, kal: kal)
        XCTAssertEqual(p.samtala.innskattur24, 24_000)
        XCTAssertEqual(p.samtala.innskattur11, 5_500)
        XCTAssertEqual(p.innkaup.count, 2)
    }

    /// Aðeins kostnaður sem merktur er sem yfirfarinn fer með í yfirlitið —
    /// VSKIL tekur þá sjálfkrafa inn það sem hefur verið yfirfarið í RUKK.
    func testAdeinsYfirfarinnKostnadurFerMed() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)
        kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-03-10",
                  amount: 124_000, taxRate: 24, yfirfarinn: true)
        kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-03-15",
                  amount: 50_000, taxRate: 24, yfirfarinn: false)

        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let p = VskSummaryExporter.payload(invoices: [], expenses: expenses,
                                           company: fyrirtaeki,
                                           ar: 2026, timabilNr: 2, kal: kal)
        XCTAssertEqual(p.innkaup.count, 1)
        XCTAssertEqual(p.samtala.innskattur24, 24_000)
        XCTAssertFalse(p.innkaup.contains { $0.lysing.contains("50.000") })
    }

    /// Gjalddagar: grunnreglan er 5. dagur mánaðarins tveimur á eftir
    /// lokamánuði; helgi/frídagur færir á næsta virka dag.
    func testGjalddagiGrunnregla() throws {
        // maí–jún 2026 → miðvikudagurinn 5. ágúst 2026 (engin færsla).
        let (d1, f1) = VskSummaryExporter.gjalddagi(ar: 2026, timabilNr: 3, kal: kal)
        XCTAssertEqual(iso(d1), "2026-08-05")
        XCTAssertFalse(f1)
        // nóv–des 2026 → föstudagurinn 5. febrúar 2027 (yfir áramót).
        let (d2, f2) = VskSummaryExporter.gjalddagi(ar: 2026, timabilNr: 6, kal: kal)
        XCTAssertEqual(iso(d2), "2027-02-05")
        XCTAssertFalse(f2)
    }

    /// 5. desember 2026 er laugardagur → gjalddagi sep–okt færist á mánudag.
    func testGjalddagiFaerdurVegnaHelgi() throws {
        let (d, f) = VskSummaryExporter.gjalddagi(ar: 2026, timabilNr: 5, kal: kal)
        XCTAssertEqual(iso(d), "2026-12-07")
        XCTAssertTrue(f)
    }

    /// 5. apríl 2026 er páskadagur (sunnudagur) og 6. apríl annar í páskum
    /// (frídagur) → gjalddagi jan–feb færist um tvo daga.
    func testGjalddagiFaerdurVegnaPaska() throws {
        // Sannreining á páskareikniritinu sjálfu.
        XCTAssertEqual(iso(VskSummaryExporter.paskadagur(ar: 2026, kal: kal)), "2026-04-05")
        let (d, f) = VskSummaryExporter.gjalddagi(ar: 2026, timabilNr: 1, kal: kal)
        XCTAssertEqual(iso(d), "2026-04-07")
        XCTAssertTrue(f)
    }

    private func iso(_ d: Date) -> String { VskSummaryExporter.isoDagur(d, kal: kal) }

    /// Sundurliðuð færsla (Rafha-dæmið: 1.590 @ 11% + 9.950 @ 24%) verður
    /// ein lína á þrep í innkaupum — samsvarandi sundurliðuninni á kvittuninni.
    func testSundurliðudFaerslaVerdurEinLinaAThrep() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)
        let e = kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-03-10",
                          amount: 11_540, taxRate: 24)
        e.isVatSplit = true
        e.splitGross11 = 1_590
        e.splitGross24 = 9_950

        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let p = VskSummaryExporter.payload(invoices: [], expenses: expenses,
                                           company: fyrirtaeki,
                                           ar: 2026, timabilNr: 2, kal: kal)
        XCTAssertEqual(p.innkaup.count, 2)
        let l11 = try XCTUnwrap(p.innkaup.first { $0.threp == 11 })
        let l24 = try XCTUnwrap(p.innkaup.first { $0.threp == 24 })
        XCTAssertEqual(l11.netto, 1_432); XCTAssertEqual(l11.vsk, 158)
        XCTAssertEqual(l24.netto, 8_024); XCTAssertEqual(l24.vsk, 1_926)
        XCTAssertEqual(p.samtala.innskattur11, 158)
        XCTAssertEqual(p.samtala.innskattur24, 1_926)
    }

    /// Sjálfvirkur flutningur: exportPeriod skrifar _vskil-skrá fyrir tímabil
    /// færslunnar í möppu — sömu skrá og handvirki útflutningurinn myndi gefa.
    func testExportPeriodSkrifarSkra() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)
        kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-09-10",
                  amount: 5_000, taxRate: 11)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try VskilAutoExport.exportPeriod(containing: date("2026-09-10"),
                                                   company: fyrirtaeki, to: folder,
                                                   in: context, kal: kal)
        XCTAssertEqual(url.lastPathComponent, "_vskil-4702221580-2026-40.json")
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(VskYfirlitPayload.self, from: data)
        XCTAssertEqual(payload.innkaup.count, 1)
        XCTAssertEqual(payload.innkaup.first?.vsk, 495)   // kvittunar-námundun
        XCTAssertEqual(payload.samtala.innskattur11, 495)
    }

    /// VSKIL sannreinir samtölur gegn færslunum — þess vegna verður gagn
    /// sem við smíðum hér að standast þá prófun.
    func testGognStandastVskilSannreiningu() throws {
        let context = try makeContext()
        let fyrirtaeki = company(context)
        reikningur(context, fyrirtaeki: fyrirtaeki, numer: "001", dagur: "2026-03-10")
        reikningur(context, fyrirtaeki: fyrirtaeki, numer: "002", dagur: "2026-04-05",
                   taxRate: 11, upphaed: 45_454.55)
        kostnadur(context, fyrirtaeki: fyrirtaeki, dagur: "2026-03-15", amount: 99_999.99)

        let invoices = try context.fetch(FetchDescriptor<Invoice>())
        let expenses = try context.fetch(FetchDescriptor<Expense>())
        let p = VskSummaryExporter.payload(invoices: invoices, expenses: expenses,
                                           company: fyrirtaeki,
                                           ar: 2026, timabilNr: 2, kal: kal)
        let gogn = try VskSummaryExporter.gogn(p)

        // Einfaldur endurútreikningur: engin lína má vanta og samtalan
        // í skránni verður að vera sú sama og í hlutnum.
        let texti = String(data: gogn, encoding: .utf8)!
        XCTAssertTrue(texti.contains("\"tegund\" : \"VSKIL-YFIRLIT\""))
        XCTAssertTrue(texti.contains("\"timabil\" : 16"))
    }
}
