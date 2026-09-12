import XCTest
import SwiftData
@testable import RUKK

@MainActor
final class ExpenseTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self, Expense.self,
            configurations: config
        )
        return ModelContext(container)
    }

    func testVatAmountIsIncludedInGross() throws {
        let expense = Expense(amount: 12_400)
        expense.taxRate = 24
        // 12400 með 24 % VSK → VSK-innihald = 12400 × 24/124 = 2400
        XCTAssertEqual(expense.vatAmount, 2_400)
        XCTAssertEqual(expense.netAmount, 10_000)
    }

    func testZeroRateHasNoVat() throws {
        let expense = Expense(amount: 5_000)
        expense.taxRate = 0
        XCTAssertEqual(expense.vatAmount, 0)
        XCTAssertEqual(expense.netAmount, 5_000)
    }

    func testReducedRate() throws {
        let expense = Expense(amount: 11_100)
        expense.taxRate = 11
        // 11100 × 11/111 = 1100
        XCTAssertEqual(expense.vatAmount, 1_100)
        XCTAssertEqual(expense.netAmount, 10_000)
    }

    /// N1-kvittun: 5.000 kr. með 11 % VSK — kvittunin segir nettó 4.505, VSK 495.
    /// Beinn útreikningur 5000 × 11/111 = 495,495… má EKKI námundast í 496.
    func testVatMatchesReceiptRoundingN1() throws {
        let expense = Expense(amount: 5_000)
        expense.taxRate = 11
        XCTAssertEqual(expense.vatAmount, 495)
        XCTAssertEqual(expense.netAmount, 4_505)
    }

    /// 12.500 kr. @ 24 % → nettó 10.081, VSK 2.419 (sama og áður).
    func testVatMatchesReceiptRounding24() throws {
        let expense = Expense(amount: 12_500)
        expense.taxRate = 24
        XCTAssertEqual(expense.vatAmount, 2_419)
        XCTAssertEqual(expense.netAmount, 10_081)
    }

    /// 1.737 kr. @ 24 % → nettó 1.401, VSK 336.
    func testVatMatchesReceiptRoundingOddAmount() throws {
        let expense = Expense(amount: 1_737)
        expense.taxRate = 24
        XCTAssertEqual(expense.vatAmount, 336)
        XCTAssertEqual(expense.netAmount, 1_401)
    }

    /// Erindi í öðrum gjaldmiðli námundast í sent, ekki heilar krónur.
    func testVatForeignCurrencyRoundsToCents() throws {
        let expense = Expense(amount: Decimal(string: "100.00")!)
        expense.taxRate = 24
        expense.currencyCode = "EUR"
        // nettó = 100 / 1,24 = 80,645… → 80,65 → VSK 19,35
        XCTAssertEqual(expense.vatAmount, Decimal(string: "19.35"))
        XCTAssertEqual(expense.netAmount, Decimal(string: "80.65"))
    }

    /// Ný færsla er óyfirfarin sjálfgefið; hakk er fylgt með færslunni.
    func testReviewedDefaultsToFalse() throws {
        let expense = Expense(amount: 5_000)
        XCTAssertFalse(expense.reviewed)
        expense.reviewed = true
        XCTAssertTrue(expense.reviewed)
    }

    /// Sundurliðuð færsla — Rafha-kvittun: kaffi 1.590 @ 11% (nettó 1.432,
    /// VSK 158) og grill 9.950 @ 24% (nettó 8.024, VSK 1.926). Samtals 11.540.
    func testVatSplitMatchesReceiptBreakdown() throws {
        let expense = Expense(amount: 11_540)
        expense.isVatSplit = true
        expense.splitGross11 = 1_590
        expense.splitGross24 = 9_950

        XCTAssertEqual(expense.vatPart(gross: 1_590, rate: 11), 158)
        XCTAssertEqual(expense.netPart(gross: 1_590, rate: 11), 1_432)
        XCTAssertEqual(expense.vatPart(gross: 9_950, rate: 24), 1_926)
        XCTAssertEqual(expense.netPart(gross: 9_950, rate: 24), 8_024)
        XCTAssertEqual(expense.vatAmount, 158 + 1_926)   // 2.084 — summa þrepa
        XCTAssertEqual(expense.netAmount, 11_540 - 2_084)
    }

    /// Án sundurliðunar hegðar færslan sér eins og áður (eitt hlutfall)
    /// og þrepasviðin eru hunsuð.
    func testVatSplitOffUsesSingleRate() throws {
        let expense = Expense(amount: 11_540)
        expense.taxRate = 24
        expense.splitGross24 = 9_950   // hunsuð þegar isVatSplit er false
        // 11.540 / 1,24 = 9.306,45… → nettó 9.306, VSK 2.234
        XCTAssertEqual(expense.vatAmount, 2_234)
        XCTAssertEqual(expense.netAmount, 9_306)
    }

    /// Sundurliðun af kvittun (Rafha-dæmið) fyllir þrepin sjálfkrafa við inntöku.
    func testApplyBreakdownSplitsExpense() throws {
        let expense = Expense(amount: 0)
        let parsed = ParsedReceipt(vendor: "RAFHA", date: nil, total: 11_540, vat: 2_084,
                                   vatRate: nil,
                                   vatLines: [.init(rate: 11, net: 1_432, vat: 158),
                                              .init(rate: 24, net: 8_024, vat: 1_926)])
        ExpenseIntake.apply(parsed, to: expense, dateProvided: false)
        XCTAssertEqual(expense.vendor, "RAFHA")
        XCTAssertEqual(expense.amount, 11_540)
        XCTAssertTrue(expense.isVatSplit)
        XCTAssertEqual(expense.splitGross11, 1_590)
        XCTAssertEqual(expense.splitGross24, 9_950)
        XCTAssertEqual(expense.vatAmount, 2_084)   // 158 + 1.926
    }

    /// Handvirk sundurliðun er aldrei yfirskrifuð af OCR-lestri.
    func testApplyDoesNotOverrideManualSplit() throws {
        let expense = Expense(amount: 11_540)
        expense.isVatSplit = true
        expense.splitGross24 = 11_540
        let parsed = ParsedReceipt(vendor: nil, date: nil, total: 11_540, vat: nil,
                                   vatRate: nil,
                                   vatLines: [.init(rate: 11, net: 1_432, vat: 158),
                                              .init(rate: 24, net: 8_024, vat: 1_926)])
        ExpenseIntake.apply(parsed, to: expense, dateProvided: false)
        XCTAssertEqual(expense.splitGross24, 11_540)
        XCTAssertEqual(expense.splitGross11, 0)
    }

    func testMakeNextUsesCompanyDefaults() throws {
        let context = try makeContext()
        let company = AppSettings()
        company.defaultTaxRate = 11
        company.defaultCurrencyCode = "EUR"
        context.insert(company)

        let expense = Expense.makeNext(in: context, company: company)
        XCTAssertEqual(expense.company, company)
        XCTAssertEqual(expense.taxRate, 11)
        XCTAssertEqual(expense.currencyCode, "EUR")
        XCTAssertEqual(expense.source, .manual)
    }

    func testBillToBookOrigin() throws {
        let context = try makeContext()
        let company = AppSettings()
        context.insert(company)

        let receipt = Data([0x89, 0x50, 0x4E, 0x47])   // PNG-signature sem sýnigögn
        let expense = Expense.makeFromBillToBook(in: context, company: company, receipt: receipt)
        XCTAssertEqual(expense.source, .billToBook)
        XCTAssertEqual(expense.receiptData, receipt)
    }
}
