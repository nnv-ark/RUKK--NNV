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
