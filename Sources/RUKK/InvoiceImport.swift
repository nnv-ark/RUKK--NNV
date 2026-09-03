import Foundation
import Observation

/// Gögn sem berast utanfrá (t.d. úr Tyme-viðbót) gegnum `rukk://` slóð til að búa til drög-reikning.
struct InvoiceImportPayload: Codable, Equatable {
    struct Line: Codable, Equatable {
        let description: String
        let quantity: Decimal
        let unitPrice: Decimal
        var unit: String?       // t.d. "klst" — eingöngu til upplýsingar
        /// Þegar sendandinn (BLIZZ) veit að vinnan er þegar rukkuð. RUKK sleppir
        /// slíkum línum, svo dráttur sem ber með sér rukkaða vinnu skilar aðeins
        /// því sem eftir stendur.
        var billed: Bool?
    }
    var version: Int = 1
    var source: String?          // t.d. "tyme"
    var currency: String?        // t.d. "ISK"
    var customer: String?        // verkefnaheiti úr upprunanum (valkvætt)
    var estimate: Bool?          // true = búa til tilboð í stað reikningsdraga (BLIZZ „Senda tilboð“)
    var lines: [Line]

    /// Línurnar sem eiga erindi á reikning — rukkuð vinna er skilin eftir.
    var unbilledLines: [Line] { lines.filter { $0.billed != true } }
}

/// Les tvær gerðir af innflutningi í `InvoiceImportPayload`:
/// - `rukk://invoice?data=<base64 JSON>` slóðir (t.d. úr Tyme-viðbót)
/// - `.rukktime` skrár sem RUKK er beðið um að opna (bein „Send to RUKK“ sending úr BLIZZ).
///   Skrár sem berast um LaunchServices („opna með“) fá sandkassaleyfi sjálfkrafa.
enum InvoiceImport {
    static func payload(from url: URL) -> InvoiceImportPayload? {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(InvoiceImportPayload.self, from: data)
        }
        guard url.scheme?.lowercased() == "rukk" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = comps.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = decodeBase64(encoded) else { return nil }
        return try? JSONDecoder().decode(InvoiceImportPayload.self, from: data)
    }

    /// Tekur við bæði venjulegu og URL-öruggu base64 (og vantandi „=“ fyllingu).
    private static func decodeBase64(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let pad = s.count % 4
        if pad > 0 { s += String(repeating: "=", count: 4 - pad) }
        return Data(base64Encoded: s)
    }
}

/// Geymir reikning sem bíður þess að vera búinn til þegar aðalviðmótið birtist.
/// Fyllt af `.onOpenURL`, tæmt af `ContentView`.
@Observable
final class ImportInbox {
    var pending: InvoiceImportPayload?
}
