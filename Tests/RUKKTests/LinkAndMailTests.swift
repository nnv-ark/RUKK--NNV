import XCTest
import Foundation
import Network
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

    // MARK: - IMAPClient streymislestur (regression: hrun við köflótt svar)

    /// Hermi-IMAPþjónn á loopback sem svarar í litlum TCP-bútum. Sannreynir að
    /// readLine/readBytes þoli svar sem berst í köflum — fyrri útgáfa krafaði
    /// EXC_BREAKPOINT í Data.subdata þegar Gmail skilaði FETCH-svari í bútum.
    func testFetchAcrossTCPChunks() async throws {
        let message = (1...40).map { "Lína \($0): KVITTUN 12.500 kr" }
            .joined(separator: "\r\n")
        let server = try MiniIMAPServer(messageBody: Data(message.utf8))
        let port = try server.start()
        defer { server.stop() }

        let client = IMAPClient(host: "127.0.0.1", port: port, useTLS: false)
        try await client.connect()
        try await client.login(username: "procurator@example.is", password: "x")
        try await client.select(mailbox: "INBOX")
        let uids = try await client.searchUnseen()
        XCTAssertEqual(uids, [42])
        let fetched = try await client.fetchMessage(uid: 42)
        XCTAssertEqual(fetched, Data(message.utf8))
        try await client.markSeen(uid: 42)
        await client.logout()
    }
}

// MARK: - MiniIMAPServer (prófunarþjónn á loopback)

/// Lágmarks IMAP-hermir: kveður, svarar LOGIN/SELECT/SEARCH/FETCH/STORE/LOGOUT.
/// Sendir allt í 7-bæta köflum til að herma eftir köflóttri afhendingu Gmail.
private final class MiniIMAPServer: @unchecked Sendable {
    private let messageBody: Data
    private var listener: NWListener?

    init(messageBody: Data) { self.messageBody = messageBody }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [messageBody] conn in
            conn.start(queue: .global())
            MiniIMAPServer.serve(conn, messageBody: messageBody, buffer: Data())
        }
        // Bíða eftir ready-stöðu áður en tenging er reind — port er ekki
        // bindað fyrr en listener nær .ready (annars EADDRNOTAVAIL).
        let semaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { semaphore.signal() }
        }
        listener.start(queue: .global())
        guard semaphore.wait(timeout: .now() + 5) == .success,
              let port = listener.port?.rawValue else {
            throw NSError(domain: "test", code: 1)
        }
        return port
    }

    func stop() { listener?.cancel() }

    private static func serve(_ conn: NWConnection, messageBody: Data, buffer: Data) {
        if buffer.isEmpty {
            sendChunked(conn, Data("* OK MiniIMAP tilbúinn\r\n".utf8))
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, _ in
            guard let data, !isComplete else { conn.cancel(); return }
            var acc = buffer + data
            while let r = acc.range(of: Data([0x0D, 0x0A])) {
                let line = String(decoding: acc[acc.startIndex ..< r.lowerBound], as: UTF8.self)
                acc = Data(acc[r.upperBound...])
                let tag = line.split(separator: " ").first.map(String.init) ?? "a1"
                let response: Data
                if line.contains("LOGIN") || line.contains("SELECT") || line.contains("STORE") {
                    response = Data("\(tag) OK\r\n".utf8)
                } else if line.contains("UID SEARCH") {
                    response = Data("* SEARCH 42\r\n\(tag) OK\r\n".utf8)
                } else if line.contains("UID FETCH") {
                    let n = messageBody.count
                    var r2 = Data("* 1 FETCH (UID 42 BODY[] {\(n)}\r\n".utf8)
                    r2.append(messageBody)
                    r2.append(Data(")\r\n\(tag) OK\r\n".utf8))
                    response = r2
                } else {
                    response = Data("\(tag) OK\r\n".utf8)
                }
                sendChunked(conn, response)
            }
            serve(conn, messageBody: messageBody, buffer: acc)
        }
    }

    /// Sendir í 7-bæta köflum með smá millibili — hermir eftir raunneti.
    private static func sendChunked(_ conn: NWConnection, _ data: Data) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + 7, data.count)
            conn.send(content: data[offset ..< end], completion: .idempotent)
            offset = end
        }
    }
}
