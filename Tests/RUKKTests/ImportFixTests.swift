import XCTest
import SwiftData
@testable import RUKK

/// Prófanir á göllum sem fundust í yfirferð: innlestur og afleidd skjöl.
final class ImportFixTests: XCTestCase {

    // MARK: - Tyme

    private func tymeJSON(duration: Int, unit: String) -> Data {
        Data("""
        {"data":[{"id":"a1","note":"vinna","task":"t","project":"p",
                  "duration":\(duration),"duration_unit":"\(unit)",
                  "rate":19000,"billing":"UNBILLED",
                  "start":"2026-05-01T10:00:00.000+02:00"}]}
        """.utf8)
    }

    func testSecondsAreRoundedRatherThanTruncated() {
        // Heiltöludeiling gerði 30 sekúndur að 0 mínútum — færslan varð verðlaus.
        XCTAssertEqual(TymeImporter.parse(tymeJSON(duration: 30, unit: "s")).first?.durationMinutes, 1)
        XCTAssertEqual(TymeImporter.parse(tymeJSON(duration: 90, unit: "s")).first?.durationMinutes, 2)
        XCTAssertEqual(TymeImporter.parse(tymeJSON(duration: 0, unit: "s")).first?.durationMinutes, 0)
    }

    func testMinutesAndHoursAreUnchanged() {
        XCTAssertEqual(TymeImporter.parse(tymeJSON(duration: 90, unit: "m")).first?.durationMinutes, 90)
        XCTAssertEqual(TymeImporter.parse(tymeJSON(duration: 2, unit: "h")).first?.durationMinutes, 120)
    }

    func testFractionalSecondsInStartDateAreParsed() {
        // ISO8601DateFormatter hafnar sekúndubrotum án .withFractionalSeconds.
        XCTAssertNotNil(TymeImporter.parse(tymeJSON(duration: 60, unit: "m")).first?.start)
    }

    func testEntryIDIsStableAcrossReads() {
        let json = Data("""
        {"data":[{"note":"n","task":"t","project":"p","duration":60,"duration_unit":"m"}]}
        """.utf8)
        XCTAssertEqual(TymeImporter.parse(json).first?.id, TymeImporter.parse(json).first?.id)
    }

    // MARK: - Kreditreikningur

    @MainActor
    func testCreditNoteInheritsTemplateOfTheInvoiceItCorrects() throws {
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext

        let company = AppSettings()
        company.defaultTemplate = "universal"
        context.insert(company)

        let invoice = Invoice.makeNext(in: context, company: company)
        invoice.number = "R-001"
        XCTAssertEqual(invoice.templateName, "universal")

        let credit = Invoice.makeCreditNote(for: invoice, in: context)
        XCTAssertEqual(credit.templateName, "universal",
                       "Kreditreikningur á að nota sama snið og reikningurinn sem hann leiðréttir")
    }

    // MARK: - QR

    func testQRPayloadHasNoGroupingSeparator() {
        let qr = InvoiceQRCode(invoiceNumber: "R-001", date: .now, amount: 1_234_567.89)
        let amount = qr.payload.split(separator: "|").last.map(String.init)
        XCTAssertEqual(amount, "1234567.89")
    }
}

/// Röðun reikningslína — undirstaða þess að draga línu til í viðmótinu.
final class LineItemOrderTests: XCTestCase {

    /// Gámurinn verður að lifa jafn lengi og reikningurinn — annars eyðir SwiftData
    /// líkönunum um leið og hann fer úr gildissviði.
    @MainActor
    private func invoiceWithLines(_ names: [String]) throws -> (Invoice, ModelContainer) {
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let company = AppSettings()
        context.insert(company)
        let invoice = Invoice.makeNext(in: context, company: company)
        for (i, name) in names.enumerated() {
            let item = LineItem(description: name, order: i)
            item.invoice = invoice
            invoice.lineItems.append(item)
            context.insert(item)
        }
        return (invoice, container)
    }

    private func descriptions(_ invoice: Invoice) -> [String] {
        invoice.orderedItems.map(\.itemDescription)
    }

    @MainActor func testMovingALineDown() throws {
        let (invoice, container) = try invoiceWithLines(["A", "B", "C", "D"])
        defer { _ = container }
        XCTAssertTrue(invoice.moveItem(from: 0, to: 2))
        XCTAssertEqual(descriptions(invoice), ["B", "C", "A", "D"])
    }

    @MainActor func testMovingALineUp() throws {
        let (invoice, container) = try invoiceWithLines(["A", "B", "C", "D"])
        defer { _ = container }
        XCTAssertTrue(invoice.moveItem(from: 3, to: 1))
        XCTAssertEqual(descriptions(invoice), ["A", "D", "B", "C"])
    }

    @MainActor func testOrderIsRenumberedContiguously() throws {
        let (invoice, container) = try invoiceWithLines(["A", "B", "C"])
        defer { _ = container }
        invoice.moveItem(from: 2, to: 0)
        XCTAssertEqual(invoice.orderedItems.map(\.order), [0, 1, 2],
                       "order á að vera samfellt eftir færslu, annars skarast nýjar línur")
    }

    @MainActor func testOutOfRangeAndNoOpMovesAreRejected() throws {
        let (invoice, container) = try invoiceWithLines(["A", "B"])
        defer { _ = container }
        XCTAssertFalse(invoice.moveItem(from: 1, to: 1))
        XCTAssertFalse(invoice.moveItem(from: 0, to: 5))
        XCTAssertFalse(invoice.moveItem(from: -1, to: 0))
        XCTAssertEqual(descriptions(invoice), ["A", "B"])
    }
}

/// Sendingar utanfrá (BLIZZ) mega bera rukkaða vinnu — hún á aldrei að rata á reikning.
final class BilledLineFilterTests: XCTestCase {

    private func payload(_ flags: [Bool?]) -> InvoiceImportPayload {
        InvoiceImportPayload(
            source: "blizz",
            lines: flags.enumerated().map { i, billed in
                InvoiceImportPayload.Line(description: "lína \(i)", quantity: 1,
                                          unitPrice: 0, unit: "klst", billed: billed)
            })
    }

    func testBilledLinesAreLeftBehind() {
        let p = payload([false, true, false])
        XCTAssertEqual(p.unbilledLines.map(\.description), ["lína 0", "lína 2"])
    }

    func testOlderSendingsWithoutTheFlagAreKept() {
        // Eldri BLIZZ-útgáfur senda ekkert `billed` — þá er engu sleppt.
        XCTAssertEqual(payload([nil, nil]).unbilledLines.count, 2)
    }

    func testAFullyBilledSendingHasNothingToImport() {
        XCTAssertTrue(payload([true, true]).unbilledLines.isEmpty)
    }

    func testDecodingASendingWithoutTheFlag() throws {
        let json = Data("""
        {"version":1,"source":"blizz","lines":[{"description":"vinna","quantity":2,"unitPrice":0}]}
        """.utf8)
        let decoded = try JSONDecoder().decode(InvoiceImportPayload.self, from: json)
        XCTAssertEqual(decoded.unbilledLines.count, 1)
        XCTAssertNil(decoded.lines[0].billed)
    }
}
