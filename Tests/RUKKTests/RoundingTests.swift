import XCTest
import SwiftData
@testable import RUKK

/// Upphæðir í rafrænum reikningi verða að stemma innbyrðis: summa línanna er
/// LineExtensionAmount, og skattstofn + VSK er heildarupphæðin (BR-CO-10 o.fl.).
@MainActor
final class RoundingTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func invoice(in context: ModelContext,
                         lines: [(Decimal, Decimal, Decimal)],
                         discount: Decimal = 0) -> Invoice {
        let inv = Invoice(number: "0000001", currencyCode: "ISK", taxRate: 24)
        inv.discountAmount = discount
        context.insert(inv)
        for (i, l) in lines.enumerated() {
            let item = LineItem(description: "Lína \(i + 1)", quantity: l.0,
                                unitPrice: l.1, taxRate: l.2, order: i)
            item.invoice = inv; inv.lineItems.append(item); context.insert(item)
        }
        return inv
    }

    /// Þrjár línur sem enda á hálfum eyri hver — áður rak summan frá heildartölunni.
    func testHalfUpLinesSumToLineExtension() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let inv = invoice(in: context, lines: [
            (Decimal(string: "3")!, Decimal(string: "0.125")!, 24),
            (Decimal(string: "3")!, Decimal(string: "0.125")!, 24),
            (Decimal(string: "3")!, Decimal(string: "0.125")!, 24)
        ])
        let t = EInvoiceTotals(invoice: inv)

        // 0,375 → 0,38 (hálft upp), ekki 0,37 eins og bankanámundun gefur.
        XCTAssertEqual(t.lines.map(\.net), [Decimal(string: "0.38")!,
                                            Decimal(string: "0.38")!,
                                            Decimal(string: "0.38")!])
        XCTAssertEqual(t.lineExtension, Decimal(string: "1.14")!)
        XCTAssertEqual(t.lines.reduce(Decimal(0)) { $0 + $1.net }, t.lineExtension)
    }

    func testTotalsReconcile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let inv = invoice(in: context, lines: [
            (Decimal(string: "1.5")!, Decimal(string: "333.33")!, 24),
            (Decimal(string: "2.25")!, Decimal(string: "77.77")!, 11),
            (1, 10_000, 0)
        ], discount: 7)
        let t = EInvoiceTotals(invoice: inv)

        XCTAssertEqual(t.subtotals.reduce(Decimal(0)) { $0 + $1.lineNet }, t.lineExtension)
        XCTAssertEqual(t.subtotals.reduce(Decimal(0)) { $0 + $1.allowance }, t.allowanceTotal)
        XCTAssertEqual(t.subtotals.reduce(Decimal(0)) { $0 + $1.tax }, t.taxTotal)
        XCTAssertEqual(t.taxExclusive, t.lineExtension - t.allowanceTotal)
        XCTAssertEqual(t.taxInclusive, t.taxExclusive + t.taxTotal)
        for g in t.subtotals { XCTAssertEqual(g.base, g.lineNet - g.allowance) }
    }

    /// Tölurnar í XML-inu sjálfu verða að stemma, ekki bara reiknilagið.
    func testExportedXMLAmountsReconcile() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let company = AppSettings()
        company.companyName = "Demó ehf."
        company.companyNationalID = "1234567890"
        company.bankAccountNumber = "0000-11-222222"
        context.insert(company)
        let contact = Contact(name: "Kaupandi", company: "Kaupandi ehf.",
                              nationalID: "0101302129", address: "Gata 1")
        context.insert(contact)

        let inv = invoice(in: context, lines: [
            (Decimal(string: "3")!, Decimal(string: "0.125")!, 24),
            (Decimal(string: "3")!, Decimal(string: "0.125")!, 24)
        ])
        inv.issuer = company
        inv.recipient = contact

        let xml = UBLInvoiceExporter.xml(for: inv, company: company)
        func amounts(_ tag: String) -> [Decimal] {
            xml.components(separatedBy: "<\(tag)")
                .dropFirst()
                .compactMap { chunk in
                    guard let gt = chunk.firstIndex(of: ">"),
                          let lt = chunk[gt...].firstIndex(of: "<") else { return nil }
                    return Decimal(string: String(chunk[chunk.index(after: gt)..<lt]))
                }
        }
        let lineAmounts = amounts("cbc:LineExtensionAmount")
        // Síðasta talan er skjalsins, hinar eru línurnar.
        let documentTotal = lineAmounts.first
        let perLine = Array(lineAmounts.dropFirst())
        XCTAssertEqual(perLine.reduce(Decimal(0), +), documentTotal)

        let exclusive = amounts("cbc:TaxExclusiveAmount").first
        let inclusive = amounts("cbc:TaxInclusiveAmount").first
        let payable = amounts("cbc:PayableAmount").first
        let tax = amounts("cbc:TaxAmount").first
        XCTAssertEqual(inclusive, (exclusive ?? 0) + (tax ?? 0))
        XCTAssertEqual(payable, inclusive)
    }
}
