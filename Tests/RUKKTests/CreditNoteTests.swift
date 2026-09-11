import XCTest
import SwiftData
@testable import RUKK

@MainActor
final class CreditNoteTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func issuedInvoice(_ context: ModelContext) -> (Invoice, AppSettings) {
        let company = AppSettings()
        company.companyName = "Demó ehf."
        company.companyNationalID = "1234567890"
        company.bankAccountNumber = "0000-11-222222"
        context.insert(company)

        let contact = Contact(name: "Jón Jónsson", company: "Kaupandi ehf.",
                              nationalID: "0101302129", address: "Götuheiti 1")
        context.insert(contact)

        let invoice = Invoice(number: "0000087", currencyCode: "ISK", taxRate: 24)
        invoice.issuer = company
        invoice.recipient = contact
        context.insert(invoice)

        let l1 = LineItem(description: "Hönnun", quantity: 1, unitPrice: 100_000, taxRate: 24, order: 0)
        l1.invoice = invoice; invoice.lineItems.append(l1); context.insert(l1)
        let l2 = LineItem(description: "Kostnaður", quantity: 2, unitPrice: 10_000, taxRate: 0, order: 1)
        l2.invoice = invoice; invoice.lineItems.append(l2); context.insert(l2)

        return (invoice, company)
    }

    // MARK: - Líkanið

    func testCreditNoteNegatesQuantitiesAndReferencesOriginal() throws {
        let context = try makeContext()
        let (original, _) = issuedInvoice(context)
        let credit = Invoice.makeCreditNote(for: original, in: context)

        XCTAssertTrue(credit.isCreditNote)
        XCTAssertEqual(credit.creditedInvoiceNumber, "0000087")
        XCTAssertEqual(credit.recipient, original.recipient)
        XCTAssertEqual(credit.issuer, original.issuer)
        XCTAssertEqual(credit.lineItems.count, 2)
        XCTAssertEqual(credit.orderedItems[0].quantity, -1)
        XCTAssertEqual(credit.orderedItems[1].quantity, -2)
        // Einingaverð helst jákvætt — forðið liggur í magninu.
        XCTAssertEqual(credit.orderedItems[0].unitPrice, 100_000)
        XCTAssertEqual(credit.total, -original.total)
    }

    // MARK: - UBL-útflutningur

    func testCreditNoteExportsAsCreditNoteRoot() throws {
        let context = try makeContext()
        let (original, company) = issuedInvoice(context)
        let credit = Invoice.makeCreditNote(for: original, in: context)
        credit.number = "0000088"
        let xml = UBLInvoiceExporter.xml(for: credit, company: company)

        // PEPPOL krefst CreditNote-rótar, ekki Invoice með kóða 381.
        XCTAssertTrue(xml.contains("<CreditNote"))
        XCTAssertTrue(xml.contains("ubl:schema:xsd:CreditNote-2"))
        XCTAssertFalse(xml.contains("<Invoice "))
        XCTAssertFalse(xml.contains("InvoiceTypeCode"))
    }

    func testCreditNoteAmountsArePositive() throws {
        let context = try makeContext()
        let (original, company) = issuedInvoice(context)
        let credit = Invoice.makeCreditNote(for: original, in: context)
        let xml = UBLInvoiceExporter.xml(for: credit, company: company)

        // Upphæðir í CreditNote eru jákvæðar — forðið berst með tegundinni.
        XCTAssertTrue(xml.contains("<cbc:LineExtensionAmount currencyID=\"ISK\">120000.00</cbc:LineExtensionAmount>"))
        XCTAssertTrue(xml.contains("<cbc:TaxAmount currencyID=\"ISK\">24000.00</cbc:TaxAmount>"))
        XCTAssertTrue(xml.contains("<cbc:TaxInclusiveAmount currencyID=\"ISK\">144000.00</cbc:TaxInclusiveAmount>"))
        XCTAssertTrue(xml.contains("<cbc:PayableAmount currencyID=\"ISK\">144000.00</cbc:PayableAmount>"))
        XCTAssertFalse(xml.contains(">-"), "Engin neikvæð upphæð má koma fram í skjalinu")
    }

    func testCreditNoteLinesUseCreditedQuantity() throws {
        let context = try makeContext()
        let (original, company) = issuedInvoice(context)
        let credit = Invoice.makeCreditNote(for: original, in: context)
        let xml = UBLInvoiceExporter.xml(for: credit, company: company)

        let lines = xml.components(separatedBy: "<cac:CreditNoteLine>").count - 1
        XCTAssertEqual(lines, 2)
        XCTAssertFalse(xml.contains("cac:InvoiceLine"))
        XCTAssertTrue(xml.contains("<cbc:CreditedQuantity unitCode=\"C62\">1</cbc:CreditedQuantity>"))
        XCTAssertTrue(xml.contains("<cbc:CreditedQuantity unitCode=\"C62\">2</cbc:CreditedQuantity>"))
    }

    func testCreditNoteReferencesCreditedInvoice() throws {
        let context = try makeContext()
        let (original, company) = issuedInvoice(context)
        let credit = Invoice.makeCreditNote(for: original, in: context)
        let xml = UBLInvoiceExporter.xml(for: credit, company: company)

        XCTAssertTrue(xml.contains("<cac:BillingReference>"))
        XCTAssertTrue(xml.contains("<cac:InvoiceDocumentReference>"))
        XCTAssertTrue(xml.contains("<cbc:ID>0000087</cbc:ID>"))
    }

    // MARK: - Tilboð og númeraröð

    func testEstimateConvertsToDraftInvoice() throws {
        let context = try makeContext()
        let company = AppSettings()
        company.invoiceNumberPrefix = "R-"
        company.defaultPaymentTermDays = 14
        context.insert(company)

        let estimate = Invoice.makeEstimate(in: context, company: company)
        XCTAssertTrue(estimate.isEstimate)
        XCTAssertEqual(estimate.estimateNumber, "R-T001")
        XCTAssertEqual(company.nextEstimateNumber, 2)

        estimate.convertToInvoice()
        XCTAssertFalse(estimate.isEstimate)
        XCTAssertEqual(estimate.status, .draft)
        XCTAssertNil(estimate.finalDueDate)
        XCTAssertNotNil(estimate.dueDate)
        XCTAssertTrue(estimate.note.contains("R-T001"))
    }

    func testIssueAssignsGaplessNumberOnlyAtIssue() throws {
        let context = try makeContext()
        let company = AppSettings()
        company.invoiceNumberPrefix = "R-"
        context.insert(company)

        // Drög fá ekkert númer og brenna ekki númerum.
        let draft = Invoice.makeNext(in: context, company: company)
        XCTAssertEqual(draft.number, "")
        XCTAssertEqual(company.nextInvoiceNumber, 1)

        draft.issue()
        XCTAssertEqual(draft.number, "R-001")
        XCTAssertEqual(company.nextInvoiceNumber, 2)
        XCTAssertEqual(draft.status, .sent)

        // Eytt drög á milli valda ekki gati í röðinni.
        let dropped = Invoice.makeNext(in: context, company: company)
        context.delete(dropped)
        let second = Invoice.makeNext(in: context, company: company)
        second.issue()
        XCTAssertEqual(second.number, "R-002")
    }
}
