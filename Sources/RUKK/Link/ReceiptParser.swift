import Foundation

/// Útkoma úr kvittunarlestri — allt valfrjálst, notandi staðfestir í formi.
struct ParsedReceipt: Equatable, Sendable {
    var vendor: String?
    var date: Date?
    /// Heildarupphæð með VSK.
    var total: Decimal?
    /// VSK-upphæð ef hún fannst á kvittuninni.
    var vat: Decimal?
    /// Ályktað VSK-hlutfall (0 / 11 / 24) út frá total og vat.
    var vatRate: Decimal?
}

/// Les útgildi úr OCR-texta kvittunar. Hrein föll án kerfiskalla — prófanleg.
/// Snið íslenskra kvittana: „SAMTALS 12.400", „Þar af VSK 24% 2.400", „11.09.2026".
enum ReceiptParser {

    static func parse(lines: [String]) -> ParsedReceipt {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ParsedReceipt(
            vendor: guessVendor(clean),
            date: guessDate(clean),
            total: guessTotal(clean),
            vat: guessVat(clean),
            vatRate: nil
        ).withInferredRate()
    }

    // MARK: - Upphæðir

    /// Íslensk upphæð: „1.234,56", „1.234", „1234,56", „12.90", „12,90 kr."
    /// Punktur með nákvæmlega 3 aukastöfum er þúsundaskil; annars aukastafur.
    static func parseAmount(_ raw: String) -> Decimal? {
        var s = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "kr", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "ISK", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        // Aðeins tölur, skilgreindir skilamunir og formerki mega standa eftir.
        s = s.replacingOccurrences(of: #"[^\d,.\-]"#, with: "", options: .regularExpression)
        // Skilamunir í endum eru aldrei upphæðarhluti („1.990 kr.“ → „1.990.“ → „1.990“).
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !s.isEmpty else { return nil }

        if s.contains(",") {
            // Komma = aukastafur; punktar og bil eru þúsundaskil.
            s = s.replacingOccurrences(of: ".", with: "")
                 .replacingOccurrences(of: ",", with: ".")
        } else if let dot = s.lastIndex(of: ".") {
            let decimals = s.distance(from: s.index(after: dot), to: s.endIndex)
            if decimals == 3 {
                s = s.replacingOccurrences(of: ".", with: "")   // þúsundaskil
            }
            // 1–2 aukastafir: punktur er aukastafur — haldið óbreyttu.
        }
        return Decimal(string: s)
    }

    /// Allar upphæðir sem koma fram í textalínu. Kennitalur (123456-7890 eða
    /// 10 tölur í röð) eru hunsunar — þær eru næstan alltaf stærsta talan á
    /// kvittuninni og myndu annars verða fyrir „stærstu tölunnar" varafallinu.
    private static func amounts(in line: String) -> [Decimal] {
        let withoutKt = line.replacingOccurrences(
            of: #"\d{6}\s?-\s?\d{4}|\b\d{10}\b"#,
            with: " ", options: .regularExpression)
        let pattern = #"\d{1,3}(?:[ .]\d{3})+(?:,\d{1,2})?|\d+(?:[.,]\d{1,2})?"#
        return (try? NSRegularExpression(pattern: pattern))
            .map { re in
                re.matches(in: withoutKt, range: NSRange(withoutKt.startIndex..., in: withoutKt))
                    .compactMap { Range($0.range, in: withoutKt) }
                    .compactMap { parseAmount(String(withoutKt[$0])) }
            } ?? []
    }

    /// Heildarupphæð: lína með lykilorði (samtals/total/til greiðslu …),
    /// annars stærsta upphæðin á kvittuninni.
    private static func guessTotal(_ lines: [String]) -> Decimal? {
        let keywords = ["samtals", "total", "til greiðslu", "heild", "alls", "að greiða"]
        for line in lines.reversed() {   // samtalan er neðst
            let lower = line.lowercased()
            if keywords.contains(where: lower.contains),
               let amount = amounts(in: line).max() {
                return amount
            }
        }
        return lines.flatMap(amounts).max()
    }

    /// VSK-upphæð: lína með „vsk" — sleppa prósentutölunni (henni fylgir %).
    private static func guessVat(_ lines: [String]) -> Decimal? {
        for line in lines {
            let lower = line.lowercased()
            guard lower.contains("vsk") || lower.contains("virðisaukaskattur") else { continue }
            let withoutPercent = line.replacingOccurrences(of: #"\d+(?:[.,]\d+)?\s*%"#,
                                                           with: "", options: .regularExpression)
            if let amount = amounts(in: withoutPercent).max() { return amount }
        }
        return nil
    }

    // MARK: - Dagsetning

    private static func guessDate(_ lines: [String]) -> Date? {
        let patterns: [(String, String)] = [
            (#"\b(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{4})\b"#, "dmy4"),
            (#"\b(\d{1,2})[.\-/](\d{1,2})[.\-/](\d{2})\b"#, "dmy2"),
            (#"\b(\d{4})-(\d{2})-(\d{2})\b"#, "ymd"),
        ]
        let cal = Calendar.current
        for line in lines {
            for (pattern, kind) in patterns {
                guard let re = try? NSRegularExpression(pattern: pattern),
                      let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let r1 = Range(m.range(at: 1), in: line),
                      let r2 = Range(m.range(at: 2), in: line),
                      let r3 = Range(m.range(at: 3), in: line),
                      let a = Int(line[r1]), let b = Int(line[r2]), let c = Int(line[r3])
                else { continue }
                let d, mo, y: Int
                switch kind {
                case "ymd":  (y, mo, d) = (a, b, c)
                case "dmy2": (d, mo, y) = (a, b, 2000 + c)
                default:     (d, mo, y) = (a, b, c)
                }
                if (1...31).contains(d), (1...12).contains(mo), y >= 2000,
                   let date = cal.date(from: DateComponents(year: y, month: mo, day: d)) {
                    return date
                }
            }
        }
        return nil
    }

    // MARK: - Seljandi

    /// Seljandi: fremsta línan með a.m.k. þremur bókstöfum, að hún sé ekki
    /// augljós kerfislína (kvittun, kassi, sími, kt., dagsetningar).
    private static func guessVendor(_ lines: [String]) -> String? {
        let skip = ["kvittun", "receipt", "kassi", "sími", "kt.", "kt:", "dags", "date"]
        for line in lines {
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 3 else { continue }
            let lower = line.lowercased()
            if skip.contains(where: lower.contains) { continue }
            return line
        }
        return nil
    }
}

private extension ParsedReceipt {
    /// Ályktar VSK-hlutfall út frá total/vat og smellur á næsta löglega stig.
    func withInferredRate() -> ParsedReceipt {
        var copy = self
        guard let total, let vat, total > vat, vat > 0 else {
            if total != nil { copy.vatRate = copy.vat == 0 ? 0 : copy.vatRate }
            return copy
        }
        let implied = vat / (total - vat) * 100
        for rate: Decimal in [24, 11] where abs(implied - rate) < 1.5 {
            copy.vatRate = rate
            return copy
        }
        return copy
    }
}
