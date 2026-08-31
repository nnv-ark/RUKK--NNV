import XCTest
import SwiftData
@testable import RUKK

/// Tilboð (isEstimate): númerakerfi, gildistími, breyting í reikning.
@MainActor
final class EstimateTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeCompany(_ context: ModelContext, prefix: String = "R-") -> AppSettings {
        let company = AppSettings()
        company.invoiceNumberPrefix = prefix
        company.defaultPaymentTermDays = 14
        context.insert(company)
        return company
    }

    // MARK: - Stofnun tilboðs

    func testMakeEstimateAssignsNumberAndValidity() throws {
        let context = try makeContext()
        let company = makeCompany(context)

        let est = Invoice.makeEstimate(in: context, company: company)

        XCTAssertTrue(est.isEstimate)
        XCTAssertEqual(est.estimateNumber, "R-T001")
        XCTAssertEqual(company.nextEstimateNumber, 2)
        XCTAssertTrue(est.number.isEmpty)                 // engin raðnúmer á tilboðum
        XCTAssertEqual(company.nextInvoiceNumber, 1)      // reikningsröð ósnortin
        XCTAssertEqual(est.status, .draft)

        // Gildistími: útgáfudagur + 30 dagar.
        let expected = Calendar.current.date(byAdding: .day, value: 30, to: est.issueDate)
        XCTAssertEqual(est.validUntil.timeIntervalSince1970,
                       expected?.timeIntervalSince1970 ?? -1, accuracy: 1)
    }

    func testEstimateNumbersIncrement() throws {
        let context = try makeContext()
        let company = makeCompany(context)

        let first = Invoice.makeEstimate(in: context, company: company)
        let second = Invoice.makeEstimate(in: context, company: company)

        XCTAssertEqual(first.estimateNumber, "R-T001")
        XCTAssertEqual(second.estimateNumber, "R-T002")
    }

    // MARK: - Breyting í reikning

    func testConvertToInvoice() throws {
        let context = try makeContext()
        let company = makeCompany(context)
        let est = Invoice.makeEstimate(in: context, company: company)
        est.note = "Upprunaleg athugasemd."

        est.convertToInvoice()

        XCTAssertFalse(est.isEstimate)
        XCTAssertEqual(est.status, .draft)
        XCTAssertTrue(est.number.isEmpty)                 // raðnúmer fyrst við issue()
        XCTAssertTrue(est.note.hasPrefix("Samkvæmt tilboði nr. R-T001."))
        XCTAssertTrue(est.note.contains("Upprunaleg athugasemd."))
        XCTAssertNotNil(est.bookingDate)
        XCTAssertNil(est.finalDueDate)                    // eindagi reiknast af gjalddaga
        XCTAssertEqual(est.paymentTermDays, 14)

        // Gjalddagi = nýr útgáfudagur + greiðslufrestur.
        let expectedDue = Calendar.current.date(byAdding: .day, value: 14, to: est.issueDate)
        XCTAssertEqual(est.dueDate?.timeIntervalSince1970 ?? -1,
                       expectedDue?.timeIntervalSince1970 ?? -1, accuracy: 1)

        // Issue úthlutar næsta reikningsnúmeri.
        est.issue()
        XCTAssertEqual(est.number, "R-001")
        XCTAssertEqual(company.nextInvoiceNumber, 2)
    }

    func testConvertToInvoiceIsNoOpForRegularInvoice() throws {
        let context = try makeContext()
        let company = makeCompany(context)
        let inv = Invoice.makeNext(in: context, company: company)

        inv.convertToInvoice()  // má ekki breyta neinu

        XCTAssertFalse(inv.isEstimate)
        XCTAssertTrue(inv.estimateNumber.isEmpty)
        XCTAssertFalse(inv.note.hasPrefix("Samkvæmt tilboði"))
    }

    // MARK: - Aðskilnaður

    func testIsOverdueNeverTrueForEstimates() throws {
        let context = try makeContext()
        let company = makeCompany(context)
        let est = Invoice.makeEstimate(in: context, company: company)
        est.status = .sent
        est.finalDueDate = Calendar.current.date(byAdding: .day, value: -10, to: .now)

        XCTAssertFalse(est.isOverdue)
    }

    func testIsOverdueForOverdueSentInvoice() throws {
        let context = try makeContext()
        let company = makeCompany(context)
        let inv = Invoice.makeNext(in: context, company: company)
        inv.dueDate = Calendar.current.date(byAdding: .day, value: -30, to: .now)
        inv.finalDueDate = Calendar.current.date(byAdding: .day, value: -10, to: .now)
        inv.status = .sent

        XCTAssertTrue(inv.isOverdue)
    }

    func testDocumentFileName() throws {
        let context = try makeContext()
        let company = makeCompany(context)

        let est = Invoice.makeEstimate(in: context, company: company)
        XCTAssertEqual(est.documentFileName, "R-T001")

        let inv = Invoice.makeNext(in: context, company: company)
        XCTAssertEqual(inv.documentFileName, "reikningur")   // drög án númers
        inv.issue()
        XCTAssertEqual(inv.documentFileName, "R-001")
    }

    // MARK: - Textar

    func testEstimateStrings() {
        let is_ = InvoiceStrings(.icelandic)
        XCTAssertEqual(is_.estimateNo, "Tilboð nr.")
        XCTAssertEqual(is_.validUntil, "Gildir til")

        let en = InvoiceStrings(.english)
        XCTAssertEqual(en.estimateNo, "Estimate no.")
        XCTAssertEqual(en.validUntil, "Valid until")
    }
}
