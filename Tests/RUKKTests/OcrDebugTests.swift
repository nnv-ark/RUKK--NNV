import XCTest
@testable import RUKK

/// TÍMABUNDIN greining: hvað les Vision af BÓNUS-kvittuninni?
/// Sleppir sér sjálfkrafa ef prufuskráin er ekki til staðar.
final class OcrDebugTests: XCTestCase {
    func testPrintOcrLines() async throws {
        let url = URL(fileURLWithPath: "/Users/olafurhjordisarsonjonsson/Developer/VSK SKIL/bonus_kvittun.pdf")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Prufuskrá ekki til staðar: \(url.path)")
        }
        let data = try Data(contentsOf: url)
        let lines = await ReceiptReader.textLines(from: data)
        for (i, line) in lines.enumerated() {
            print(String(format: "OCR[%02d]: %@", i, line))
        }
        let parsed = ReceiptParser.parse(lines: lines)
        print("PARSED vendor:", parsed.vendor as Any)
        print("PARSED total:", parsed.total as Any)
        print("PARSED vat:", parsed.vat as Any)
        print("PARSED rate:", parsed.vatRate as Any)
        print("PARSED date:", parsed.date as Any)
    }
}
