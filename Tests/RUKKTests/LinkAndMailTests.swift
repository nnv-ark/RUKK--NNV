import XCTest
import Foundation
@testable import RUKK

final class LinkAndMailTests: XCTestCase {

    // MARK: - RukkEnvelope

    func testEnvelopeRoundTrip() throws {
        let header = RukkEnvelope.Header(kind: "receipt", company: "Demó ehf.",
                                         receiptNumber: 12, date: "2026-09-11",
                                         mime: "application/pdf", fileName: "receipt-0012.pdf")
        let payload = Data("%PDF-falskt en nógu gott".utf8)
        let encoded = try RukkEnvelope(header: header, payload: payload).encoded()

        let decoded = try RukkEnvelope.decode(encoded)
        XCTAssertEqual(decoded.header.company, "Demó ehf.")
        XCTAssertEqual(decoded.header.receiptNumber, 12)
        XCTAssertEqual(decoded.header.mime, "application/pdf")
        XCTAssertEqual(decoded.payload, payload)
    }

    func testEnvelopeRejectsGarbage() {
        XCTAssertThrowsError(try RukkEnvelope.decode(Data([1, 2])))
        XCTAssertThrowsError(try RukkEnvelope.decode(Data("engin kvittun hér".utf8)))
    }

    // MARK: - ReceiptParser

    func testParseIcelandicAmounts() {
        XCTAssertEqual(ReceiptParser.parseAmount("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(ReceiptParser.parseAmount("12.400"), 12_400)          // punktur = þúsundaskil
        XCTAssertEqual(ReceiptParser.parseAmount("12.90"), Decimal(string: "12.90"))
        XCTAssertEqual(ReceiptParser.parseAmount("1.990 kr."), 1_990)
        XCTAssertEqual(ReceiptParser.parseAmount("engin tala"), nil)
    }

    func testParseTypicalReceipt() {
        let lines = [
            "BÓNUS ÞÓRSHÖFN",
            "Kt. 550169-0769",
            "Dags. 11.09.2026 14:32",
            "Mjólk 2%           429",
            "Brauð              510",
            "Ostur            1.240",
            "SAMTALS          2.179",
            "Þar af VSK 11%     216",
            "KORTIÐ ****1234",
        ]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.vendor, "BÓNUS ÞÓRSHÖFN")
        XCTAssertEqual(parsed.total, 2_179)
        XCTAssertEqual(parsed.vat, 216)
        XCTAssertEqual(parsed.vatRate, 11)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: try! XCTUnwrap(parsed.date))
        XCTAssertEqual(comps.year, 2026); XCTAssertEqual(comps.month, 9); XCTAssertEqual(comps.day, 11)
    }

    func testVendorSkipsSystemLines() {
        let lines = ["Kvittun nr. 4412", "Kassi 3", "OLÍS ÁRTÚNSBREKKA", "SAMTALS 8.490"]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.vendor, "OLÍS ÁRTÚNSBREKKA")
    }

    func testTotalFallsBackToLargestAmount() {
        let lines = ["VEITINGASTAÐURINN", "Lambhamborgari 3.490", "Kók 450"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).total, 3_490)
    }

    func testISODate() {
        let parsed = ReceiptParser.parse(lines: ["VERSLANA MÍN", "2026-09-11", "SAMTALS 1.000"])
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: try! XCTUnwrap(parsed.date))
        XCTAssertEqual(comps.year, 2026); XCTAssertEqual(comps.month, 9); XCTAssertEqual(comps.day, 11)
    }

    // MARK: - MIMEMessage

    func testMultipartWithPDFAttachment() throws {
        let pdf = Data("%PDF-1.4 syni".utf8)
        let body = "Scan attached.\r\n\r\nCompany:  Demó ehf.\r\nReceipt:  #0012\r\nDate:     2026-09-11\r\n\r\nMade with Bill To Book\r\n"
        let raw = [
            "From: Síminn <siminn@example.is>",
            "Subject: =?UTF-8?B?UmVjZWlwdCAjMDAxMg==?=",
            "Content-Type: multipart/mixed; boundary=\"xyz\"",
            "",
            "--xyz",
            "Content-Type: text/plain; charset=utf-8",
            "",
            body,
            "--xyz",
            "Content-Type: application/pdf; name=\"receipt-0012.pdf\"",
            "Content-Disposition: attachment; filename=\"receipt-0012.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            pdf.base64EncodedString(),
            "--xyz--",
        ].joined(separator: "\r\n")

        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertEqual(message.subject, "Receipt #0012")
        XCTAssertTrue(message.bodyText.contains("Made with Bill To Book"))
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(message.attachments[0].mimeType, "application/pdf")
        XCTAssertEqual(message.attachments[0].fileName, "receipt-0012.pdf")
        XCTAssertEqual(message.attachments[0].data, pdf)
    }

    func testPlainMessageWithoutAttachment() throws {
        let raw = "Subject: Halló\r\nContent-Type: text/plain\r\n\r\nBara texti."
        let message = try XCTUnwrap(MIMEMessage.parse(Data(raw.utf8)))
        XCTAssertEqual(message.subject, "Halló")
        XCTAssertTrue(message.attachments.isEmpty)
        XCTAssertTrue(message.bodyText.contains("Bara texti"))
    }
}
