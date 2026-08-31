import XCTest
@testable import RUKK

final class InvoiceImportTests: XCTestCase {

    /// Dæmigert payload eins og BLIZZ „Send to RUKK“ skrifar í `.rukktime` skrá.
    private let sampleJSON = """
    {
      "version": 1,
      "source": "blizz",
      "currency": "ISK",
      "customer": "Viðskiptavinur — Verkefni",
      "lines": [
        { "description": "Hönnun", "quantity": 2.5, "unitPrice": 18000, "unit": "klst" },
        { "description": "Fundur", "quantity": 1, "unitPrice": 18000, "unit": "klst" }
      ]
    }
    """

    // MARK: - `rukk://` slóð (base64 JSON)

    func testRukkURLDecodesPayload() {
        let data = Data(sampleJSON.utf8)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = URL(string: "rukk://invoice?data=\(encoded)")!

        let payload = InvoiceImport.payload(from: url)

        XCTAssertEqual(payload?.version, 1)
        XCTAssertEqual(payload?.source, "blizz")
        XCTAssertEqual(payload?.customer, "Viðskiptavinur — Verkefni")
        XCTAssertEqual(payload?.lines.count, 2)
        XCTAssertEqual(payload?.lines.first?.description, "Hönnun")
        XCTAssertEqual(payload?.lines.first?.quantity, Decimal(2.5))
        XCTAssertEqual(payload?.lines.first?.unitPrice, Decimal(18000))
        XCTAssertEqual(payload?.lines.first?.unit, "klst")
    }

    // MARK: - `.rukktime` skrá (bein BLIZZ-sending)

    func testFileURLDecodesPayload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
            .appendingPathExtension("rukktime")
        try Data(sampleJSON.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let payload = InvoiceImport.payload(from: url)

        XCTAssertEqual(payload?.source, "blizz")
        XCTAssertEqual(payload?.lines.count, 2)
        XCTAssertEqual(payload?.lines.last?.description, "Fundur")
        XCTAssertEqual(payload?.lines.last?.quantity, Decimal(1))
    }

    // MARK: - Tilboðs-flagg (`estimate`)

    func testEstimateFlagDecodes() {
        let json = """
        { "version": 1, "source": "blizz", "currency": "ISK", "customer": "Verkefni",
          "estimate": true,
          "lines": [ { "description": "Hönnun", "quantity": 1, "unitPrice": 10000 } ] }
        """
        let payload = try? JSONDecoder().decode(InvoiceImportPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload?.estimate, true)
    }

    func testMissingEstimateFlagDecodesAsNil() {
        // Eldri sendingar (og Tyme-viðbót) hafa ekki `estimate`-lykil — þá verða þetta reikningsdrög.
        let payload = try? JSONDecoder().decode(InvoiceImportPayload.self, from: Data(sampleJSON.utf8))
        XCTAssertNil(payload?.estimate)
    }

    // MARK: - Ógild inntök

    func testFileURLWithGarbageReturnsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
            .appendingPathExtension("rukktime")
        try Data("ekki JSON".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertNil(InvoiceImport.payload(from: url))
    }

    func testMissingFileReturnsNil() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
            .appendingPathExtension("rukktime")
        XCTAssertNil(InvoiceImport.payload(from: url))
    }

    func testUnknownSchemeReturnsNil() {
        let url = URL(string: "https://example.com/invoice")!
        XCTAssertNil(InvoiceImport.payload(from: url))
    }
}
