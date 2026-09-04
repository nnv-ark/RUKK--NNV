import XCTest
import SwiftData
import PDFKit
@testable import RUKK

/// Fjölblaðsíðu reikningar. Áður var teiknuð ein blaðsíða og allt sem ekki komst
/// fyrir hvarf þegjandi — á lögformlegu skjali.
final class PaginationTests: XCTestCase {

    @MainActor
    private func invoice(lines: Int, template: String = "icelandic",
                         description: String = "Vinna við verkþátt númer")
    throws -> (Invoice, AppSettings, ModelContainer) {
        let container = try ModelContainer(
            for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let company = AppSettings()
        company.companyName = "Prófun ehf."
        company.companyNationalID = "1234567890"
        company.defaultTemplate = template
        context.insert(company)

        let invoice = Invoice.makeNext(in: context, company: company)
        invoice.number = "R-001"
        for i in 0..<lines {
            let item = LineItem(description: "\(description) \(i + 1)",
                                quantity: 2, unitPrice: 19_000, taxRate: 24, order: i)
            item.invoice = invoice
            invoice.lineItems.append(item)
            context.insert(item)
        }
        return (invoice, company, container)
    }

    @MainActor
    func testAShortInvoiceStaysOnOnePage() throws {
        let (invoice, company, container) = try invoice(lines: 5)
        defer { _ = container }
        let pages = InvoicePagination.split(invoice: invoice, settings: company,
                                            layout: InvoiceRenderer.layout(for: invoice))
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].count, 5)
    }

    @MainActor
    func testALongInvoiceGetsATimeReport() throws {
        let (invoice, company, container) = try invoice(lines: 60)
        defer { _ = container }
        let pages = InvoicePagination.split(invoice: invoice, settings: company,
                                            layout: InvoiceRenderer.layout(for: invoice))
        XCTAssertGreaterThan(pages.count, 1, "60 línur komast ekki á eina A4-síðu")
        XCTAssertTrue(pages[0].isEmpty, "Reikningssíðan sjálf ber eina línu — enga sundurliðun")
    }

    @MainActor
    func testNoLineIsLostOrDuplicatedBySplitting() throws {
        let (invoice, company, container) = try invoice(lines: 60)
        defer { _ = container }
        let pages = InvoicePagination.split(invoice: invoice, settings: company,
                                            layout: InvoiceRenderer.layout(for: invoice))
        let flattened = pages.flatMap { $0 }.map(\.itemDescription)
        XCTAssertEqual(flattened, invoice.orderedItems.map(\.itemDescription),
                       "Allar línur eiga að skila sér, í réttri röð, nákvæmlega einu sinni")
        XCTAssertFalse(pages.dropFirst().contains { $0.isEmpty },
                       "Engin tímaskýrslusíða á að vera tóm")
    }

    @MainActor
    func testAnEverydayInvoiceKeepsItsLinesOnTheInvoice() throws {
        // Íslenska sniðið hefur sjö dálka, svo lýsingardálkurinn er þröngur og
        // langar lýsingar brjóta sig á tvær línur. Tíu stuttar línur eiga samt
        // að rúmast á reikningnum sjálfum — annars fengju hversdagslegir
        // reikningar tímaskýrslu að óþörfu.
        let (invoice, company, container) = try invoice(lines: 10, description: "Vinna")
        defer { _ = container }
        let pages = InvoicePagination.split(invoice: invoice, settings: company,
                                            layout: InvoiceRenderer.layout(for: invoice))
        XCTAssertEqual(pages.count, 1, "tíu stuttar línur eiga að rúmast á einni síðu")
        XCTAssertEqual(pages[0].count, 10)
    }

    @MainActor
    func testTheRenderedPDFHasThePagesTheSplitPromised() throws {
        let (invoice, company, container) = try invoice(lines: 60)
        defer { _ = container }
        let expected = InvoicePagination.split(invoice: invoice, settings: company,
                                               layout: InvoiceRenderer.layout(for: invoice)).count

        let data = try XCTUnwrap(PDFRenderer.pdfData(invoice: invoice, settings: company))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, expected)

        // Síðasta línan verður að vera einhvers staðar í skjalinu — ekki skorin af.
        // Lýsingar brjóta sig milli lína í PDF-textanum, svo bilin eru jöfnuð fyrst.
        let text = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: " ")
            .replacingOccurrences(of: "\n", with: " ")
        XCTAssertTrue(text.contains("númer 60"), "Síðasta línan á að prentast")
        XCTAssertTrue(text.contains("númer 1 "), "Fyrsta línan á að prentast")
        XCTAssertTrue(text.contains("Tímaskýrsla"), "Sundurliðunin á að heita tímaskýrsla")
    }

    @MainActor
    func testTheTotalStaysOnTheFirstPage() throws {
        let (invoice, company, container) = try invoice(lines: 60)
        defer { _ = container }
        let data = try XCTUnwrap(PDFRenderer.pdfData(invoice: invoice, settings: company))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let first = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(first.contains("Samtals með VSK"),
                      "Upphæðin sem greiða skal á að vera á forsíðunni")
        XCTAssertTrue(first.contains("Sjá tímaskýrslu"),
                      "Forsíðan á að vísa á tímaskýrsluna í stað sundurliðunar")
        XCTAssertFalse(first.contains("númer 42"),
                       "Sundurliðunin á ekki að vera á forsíðunni")
    }

    @MainActor
    func testTheUniversalTemplatePaginatesToo() throws {
        let (invoice, company, container) = try invoice(lines: 60, template: "universal")
        defer { _ = container }
        let data = try XCTUnwrap(PDFRenderer.pdfData(invoice: invoice, settings: company))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
    }
}
