import XCTest
import Foundation
import Network
import AppKit
import CoreImage
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

    /// Kennitala (6-4 eða 10 tölur í röð) má aldrei verða upphæð — hún er
    /// næstan alltaf stærsta talan á kvittuninni og drap varafallið áður.
    func testKennitalaIsNotAnAmount() {
        let lines = ["BÓNUS", "Laugavegi 59, 101 Reykjavík", "Kt. 640198-2029",
                     "Mjólk 289", "Samtals: 1.737 kr."]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.total, 1_737)
        // Og þegar samtals-línan lesist ekki (lélegt OCR) má kt. ekki vinna.
        let noTotal = ["BÓNUS", "Kt. 640198-2029", "Mjólk 289"]
        XCTAssertEqual(ReceiptParser.parse(lines: noTotal).total, 289)
    }

    /// Kt. með bili í stað bandstrikis („640198 2029") er jafn ógild upphæð.
    func testKennitalaMedBiliIsNotAnAmount() {
        let lines = ["BÓNUS", "Kt. 640198 2029", "Mjólk 289"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).total, 289)
    }

    /// Dagsetningar- og tímatölur (11.09.2026 13:42) mega ekki verða upphæðir.
    func testDateAndTimeNumbersAreNotAmounts() {
        let lines = ["BÓNUS", "11.09.2026 13:42", "Mjólk 289"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).total, 289)
        // Ár eitt og sér (2026) er líka hættulegt — það er alltaf stóra talan.
        let yearOnly = ["VERSLUN", "Ár: 2026", "Vara 450"]
        XCTAssertEqual(ReceiptParser.parse(lines: yearOnly).total, 450)
    }

    /// Prósentutala á afslætti („Afsláttur 10%") er ekki upphæð.
    func testPercentIsNotAnAmount() {
        let lines = ["VERSLUN", "Afsláttur 10%", "Samtals 450"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).total, 450)
    }

    /// Dálkaskipt OCR: „Samtals:“ og „1.737 kr.“ koma sem tvær aðskildar
    /// línur (raunveruleg útkoma Vision af BÓNUS-kvittun). Þá skal para
    /// lykilorðalínuna við næstu upphæðar-línu — ekki falla á stærstu
    /// dagsetningartölunni eins og áður (total varð 2026).
    func testColumnSplitTotalPairsWithAmountLine() {
        let lines = [   // nákvæmlega það sem Vision skilar fyrir þessa kvittun
            "BÓNUS",
            "Laugavegi 59, 101 Reykjavik",
            "Kt. 640198-2029",
            "Mjólk", "Braud", "Ostur",
            "289", "549", "899",
            "Samtals:",
            "VSK 24% innifalinn",
            "11.09.2026 13:42",
            "Takk fyrir heimsóknina",
            "1.737 kr.",
        ]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.total, 1_737)
        XCTAssertEqual(parsed.vendor, "BÓNUS")
    }

    /// Þegar hvorki lykilorð né upphæðar-lína finnst: stærsta líkindatölun
    /// (stakur hlutur) — aldrei kt. eða ártal.
    func testFallbackNeverPicksDateOrKennitala() {
        let lines = ["BÓNUS", "Kt. 640198-2029", "11.09.2026", "Mjólk 289"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).total, 289)
    }

    /// „VSK 24% innifalinn" — engin upphæð, en prósentan gefur hlutfallið
    /// beint. Þetta er raunveruleg Vision-útkoma af BÓNUS-kvittun.
    func testVatRateFromPercentOnlyLine() {
        let lines = [
            "BÓNUS", "Laugavegi 59, 101 Reykjavik", "Kt. 640198-2029",
            "Mjólk", "Braud", "Ostur", "289", "549", "899",
            "Samtals:", "VSK 24% innifalinn", "11.09.2026 13:42",
            "Takk fyrir heimsóknina", "1.737 kr.",
        ]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.total, 1_737)
        XCTAssertEqual(parsed.vatRate, 24)
        XCTAssertNil(parsed.vat)
    }

    /// 11% prósentan á VSK-línu ræður — ekki má sjálfgefið falla á 24%.
    func testVatRateElevenPercentFromLine() {
        let lines = ["VEITINGAR", "Hamborgari 2.490", "SAMTALS 2.490", "VSK 11% innifalinn"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).vatRate, 11)
    }

    /// Prentuð prósentan ræður þótt total/vat bendi til annars (OCR-villa
    /// í upphæð er líklegri en villa í prentaðu hlutfalli).
    func testPrintedRateWinsOverInferred() {
        let lines = ["VERSLUN", "SAMTALS 5.000", "Þar af VSK 11% 496"]
        XCTAssertEqual(ReceiptParser.parse(lines: lines).vatRate, 11)
    }

    /// Sundurliðunartaflan neðst á Rafha-kvittun: „VSK 11% 1.432 158" og
    /// „VSK 24.0% 8.024 1.926" — tvö þrep með nettó og VSK á hverri línu.
    func testVatBreakdownLines() {
        let lines = [
            "RAFHA",
            "Samlokugrill 3 in 1 Domo grænt 9.950",
            "Kaffi Kimbo Nespresso Intenso 795",
            "Kaffi Kimbo Nespresso Napoli 795",
            "Samtals ISK með vsk. 11.540",
            "þar af vsk. 2.083",
            "VSK 11% 1.432 158",
            "VSK 24.0% 8.024 1.926",
        ]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.total, 11_540)
        XCTAssertEqual(parsed.vatLines.count, 2)
        let l11 = parsed.vatLines.first { $0.rate == 11 }
        XCTAssertEqual(l11?.net, 1_432)
        XCTAssertEqual(l11?.vat, 158)
        let l24 = parsed.vatLines.first { $0.rate == 24 }
        XCTAssertEqual(l24?.net, 8_024)
        XCTAssertEqual(l24?.vat, 1_926)
        // Heildar-VSK er summa þrepalínanna (2.084) — sundurliðunin ræður
        // yfir samantektarkassans (2.083) sem kassinn námundaði sérstaklega.
        XCTAssertEqual(parsed.vat, 2_084)
        // Mörg þrep → ekki eitt hlutfall heldur sundurliðun.
        XCTAssertNil(parsed.vatRate)
    }

    /// Ein þrepalína með aðeins VSK-upphæð („Þar af VSK 11% 216") — óbreytt.
    func testSingleVatLineStillWorks() {
        let lines = ["BÓNUS", "SAMTALS 2.179", "Þar af VSK 11% 216"]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.vat, 216)
        XCTAssertEqual(parsed.vatRate, 11)
        XCTAssertEqual(parsed.vatLines.count, 1)
        XCTAssertNil(parsed.vatLines.first?.net)
    }

    /// OCR les stundum þúsundaskilapunkt sem kommu: „1,926" átti að vera
    /// „1.926". Komma með 3 tölum á eftir er þúsundaskil, ekki aukastafur.
    func testCommaMisreadAsThousandsSeparator() {
        let lines = ["RAFHA", "Samtals ISK með vsk. 11.540",
                     "VSK 11% 1.432 158", "VSK 24.0% 8.024 1,926"]
        let parsed = ReceiptParser.parse(lines: lines)
        let l24 = parsed.vatLines.first { $0.rate == 24 }
        XCTAssertEqual(l24?.net, 8_024)
        XCTAssertEqual(l24?.vat, 1_926)
        XCTAssertEqual(parsed.vat, 2_084)
    }

    /// BÓNUS-snið: sundurliðunartaflan hefur dálkalykil en ekkert „vsk“-orð
    /// á sjálfri línunni — „D 11 2.829 311 3.140“ (lykill, hlutfall, nettó,
    /// VSK, bruttó). Báðar raðirnar þurfa að þekkjast og gefa réttar upphæðir.
    func testVatTableRowsWithoutVskWord() {
        let lines = [
            "BÓNUS",
            "BÓNUS Holtagörðum",
            "Kt. 450199-3389",
            "Dags.: 27.08.26 10:20",
            "SAMTALS 3.708",
            "D 11 2.829 311 3.140",
            "E 24 458 110 568",
        ]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.total, 3_708)
        XCTAssertEqual(parsed.vatLines.count, 2)
        let l11 = parsed.vatLines.first { $0.rate == 11 }
        XCTAssertEqual(l11?.net, 2_829)
        XCTAssertEqual(l11?.vat, 311)
        let l24 = parsed.vatLines.first { $0.rate == 24 }
        XCTAssertEqual(l24?.net, 458)
        XCTAssertEqual(l24?.vat, 110)
        // Heildar-VSK = summa þrepanna (311 + 110 = 421).
        XCTAssertEqual(parsed.vat, 421)
        XCTAssertNil(parsed.vatRate)
    }

    /// Töflulína án dálkalykils og án bruttódálks — „24 8.024 1.926“.
    func testVatTableRowWithoutKeyAndGross() {
        let parsed = ReceiptParser.parse(lines: ["VERSLANA", "SAMTALS 9.950", "24 8.024 1.926"])
        XCTAssertEqual(parsed.vatLines.count, 1)
        XCTAssertEqual(parsed.vatLines.first?.rate, 24)
        XCTAssertEqual(parsed.vatLines.first?.net, 8_024)
        XCTAssertEqual(parsed.vatLines.first?.vat, 1_926)
    }

    /// Vörulínur, dagsetningar og aðrar tölur meiga EKKI þekkjast sem
    /// VSK-töflur raðir: bókstafur á eftir hlutfalli eða orð fremst hafnar.
    func testProductAndDateLinesAreNotVatRows() {
        let lines = [
            "BÓNUS",
            "Dags.: 27.08.26 10:20",
            "2 stk @ 139 278 D",
            "pepsi 500 ml uppruna 282 D 201",
            "SAMTALS 3.708",
        ]
        let parsed = ReceiptParser.parse(lines: lines)
        XCTAssertEqual(parsed.vatLines.count, 0)
        XCTAssertEqual(parsed.total, 3_708)
    }

    /// Röðsameining: textabútar á sömu sjónröð sameinast vinstri-hægri,
    /// línur á mismunandi hæð halda sér. Grunnurinn að dálkalesstri.
    func testJoinRowsMergesColumns() {
        let rows = ReceiptReader.joinRows([
            (rect: CGRect(x: 0.05, y: 0.80, width: 0.2, height: 0.02), text: "VSK 11%"),
            (rect: CGRect(x: 0.60, y: 0.80, width: 0.1, height: 0.02), text: "1.432"),
            (rect: CGRect(x: 0.80, y: 0.805, width: 0.1, height: 0.02), text: "158"),
            (rect: CGRect(x: 0.05, y: 0.75, width: 0.2, height: 0.02), text: "VSK 24.0%"),
            (rect: CGRect(x: 0.60, y: 0.75, width: 0.1, height: 0.02), text: "8.024"),
            (rect: CGRect(x: 0.80, y: 0.75, width: 0.1, height: 0.02), text: "1,926"),
        ])
        XCTAssertEqual(rows, ["VSK 11% 1.432 158", "VSK 24.0% 8.024 1,926"])
    }

    func testISODate() {
        let parsed = ReceiptParser.parse(lines: ["VERSLANA MÍN", "2026-09-11", "SAMTALS 1.000"])
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: try! XCTUnwrap(parsed.date))
        XCTAssertEqual(comps.year, 2026); XCTAssertEqual(comps.month, 9); XCTAssertEqual(comps.day, 11)
    }

    /// Google sýnir app-lykilorð með bilum („ytim tmsw hxhc otka“) — þau eru
    /// hreinsuð bæði við lestur og skrif, þannig að líming beint úr Google
    /// virki án þess að IMAP-innskráning mistakist (AUTHENTICATIONFAILED).
    func testAppPasswordNormalization() {
        XCTAssertEqual(MailboxSettings.normalizePassword("ytim tmsw hxhc otka"), "ytimtmswhxhcotka")
        XCTAssertEqual(MailboxSettings.normalizePassword("ytimtmswhxhcotka"), "ytimtmswhxhcotka")
        XCTAssertEqual(MailboxSettings.normalizePassword(" ytimtmswhxhcotka\n"), "ytimtmswhxhcotka")
        XCTAssertEqual(MailboxSettings.normalizePassword("   "), "")
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

// MARK: - ReceiptImage

extension LinkAndMailTests {

    private func makeTestPDF() -> Data {
        // macOS-hefðbundin PDF (UIGraphicsPDFRenderer er iOS-einstök): hvít síða
        // með svörtum reit sem stendur fyrir „efni" á síðunni.
        let data = NSMutableData()
        var pageRect = CGRect(x: 0, y: 0, width: 300, height: 420)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let ctx = CGContext(consumer: consumer, mediaBox: &pageRect, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 100, height: 60))
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// PDF-rendring í fullri upplausn: löng hlið = longSide, ekki tóm mynd.
    func testRenderPDFAtFullResolution() {
        let pdf = makeTestPDF()
        XCTAssertTrue(ReceiptImage.isPDF(pdf))
        let image = ReceiptImage.render(pdf, longSide: 2000)
        let cg = try! XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(max(cg.width, cg.height), 2000)
        // Myndin má ekki vera eingöngu hvít — textinn á að hafa rendrast.
        let data = cg.dataProvider!.data! as Data
        let dark = data.filter { $0 < 100 }.count
        XCTAssertGreaterThan(dark, 500, "PDF-rendringinn virðist tómur")
    }

    /// Stór mynd er smækkuð í 1800px JPEG; lítil mynd er óbreytt.
    func testNormalizeDownscalesLargeImages() throws {
        let cg = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8,
                           bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let bigImage = NSImage(cgImage: cg.makeImage()!, size: NSSize(width: 4000, height: 3000))
        let bigData = try XCTUnwrap(bigImage.tiffRepresentation)

        let out = ReceiptImage.normalized(bigData)
        XCTAssertEqual(out.prefix(3), Data([0xFF, 0xD8, 0xFF]), "úttakið á að vera JPEG")
        let outCG = try XCTUnwrap(NSImage(data: out)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(max(outCG.width, outCG.height), 1800)

        // PDF fer óbreytt í gegn.
        let pdf = makeTestPDF()
        XCTAssertEqual(ReceiptImage.normalized(pdf), pdf)
    }
}
