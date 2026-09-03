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

/// Fyrirsagnarlínur: kaflaskil sem mega hvergi hafa áhrif á upphæðir.
final class HeadingLineTests: XCTestCase {

    @MainActor
    private func invoice() throws -> (Invoice, ModelContainer, ModelContext) {
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let company = AppSettings()
        container.mainContext.insert(company)
        return (Invoice.makeNext(in: container.mainContext, company: company),
                container, container.mainContext)
    }

    @MainActor func testAHeadingAddsNothingToTheTotals() throws {
        let (invoice, container, context) = try invoice()
        defer { _ = container }
        invoice.append([
            .init(description: "GLUGGI Í KJALLARA", quantity: 0, unitPrice: 0, heading: true),
            .init(description: "teikningar", quantity: 2, unitPrice: 10_000),
        ], in: context)

        XCTAssertEqual(invoice.subtotal, 20_000)
        XCTAssertEqual(invoice.vatBreakdown.count, 1, "fyrirsögn á ekki að búa til nýjan VSK-flokk")
        XCTAssertEqual(invoice.orderedItems.count, 2)
        XCTAssertTrue(invoice.orderedItems[0].isHeading)
    }

    @MainActor func testTwoTasksKeepTheirOwnHeadings() throws {
        let (invoice, container, context) = try invoice()
        defer { _ = container }
        invoice.append([
            .init(description: "VERK A", quantity: 0, unitPrice: 0, heading: true),
            .init(description: "vinna 1", quantity: 1, unitPrice: 1000),
        ], in: context)
        invoice.append([
            .init(description: "VERK B", quantity: 0, unitPrice: 0, heading: true),
            .init(description: "vinna 2", quantity: 1, unitPrice: 2000),
        ], in: context)

        XCTAssertEqual(invoice.orderedItems.map(\.itemDescription),
                       ["VERK A", "vinna 1", "VERK B", "vinna 2"])
        XCTAssertEqual(invoice.subtotal, 3000)
    }

    func testAHeadingWhoseWorkIsAllBilledIsDropped() {
        // Öll vinnan undir fyrirsögninni er rukkuð — fyrirsögnin á þá ekkert erindi.
        let payload = InvoiceImportPayload(lines: [
            .init(description: "VERK A", quantity: 0, unitPrice: 0, heading: true),
            .init(description: "rukkað", quantity: 1, unitPrice: 100, billed: true),
            .init(description: "VERK B", quantity: 0, unitPrice: 0, heading: true),
            .init(description: "órukkað", quantity: 1, unitPrice: 100),
        ])
        XCTAssertEqual(payload.unbilledLines.map(\.description), ["VERK B", "órukkað"])
    }
}
