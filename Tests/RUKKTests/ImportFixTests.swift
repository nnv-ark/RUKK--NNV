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
