import Foundation
import SwiftData

/// VSK-yfirlit fyrir VSKIL — JSON-samningur milli RUKK og VSKIL.
/// RUKK flytur út, VSKIL les inn og fyllir færslur virðisaukaskattsskýrslunnar.
///
/// Inntakið er útgefnir reikningar (og kreditreikningar, með mínus) samkvæmt
/// bókunardegi, og kostnaðarfærslur með VSK. Upphæðir eru námundaðar eins og
/// í rafræna reikningnum (EInvoiceTotals) svo skýrslan stemmi við reikningana.
struct VskYfirlitPayload: Codable {
    var tegund = "VSKIL-YFIRLIT"
    var utgafa = 1
    var kennitala: String
    var fyrirtaeki: String
    var vskNumer: String
    /// Ár og tímabil í númerum Skattsins (tveggja mánaða tímabil: 08–48).
    var ar: Int
    var timabil: Int
    var timabilHeiti: String
    var dagsFra: String
    var dagsTil: String
    var sala: [Skjal]
    var innkaup: [Skjal]
    var samtala: Samtala

    struct Skjal: Codable {
        var lysing: String
        var threp: Int
        var netto: Decimal
        var vsk: Decimal
    }

    /// Sömu svæði og samantala VSKIL — reiknuð hér af færslunum sjálfum.
    struct Samtala: Codable {
        var velta24: Decimal = 0
        var velta11: Decimal = 0
        var undanthegin: Decimal = 0
        var utskattur24: Decimal = 0
        var utskattur11: Decimal = 0
        var innskattur24: Decimal = 0
        var innskattur11: Decimal = 0
    }
}

/// Reiknar VSK-yfirlit út frá gögnum RUKK. Hreint felli — auðvelt að prófa.
enum VskSummaryExporter {

    /// Stutt nöfn mánaða — sama lista og VSKIL notar, óháð staðfærslu.
    static let manudurStutt = ["jan", "feb", "mar", "apr", "maí", "jún",
                               "júl", "ágú", "sep", "okt", "nóv", "des"]

    /// Númer tímabils hjá Skattinum (sannreynt: jan–feb = 08, nóv–des = 48).
    static func rskNumer(timabilNr: Int) -> Int { timabilNr * 8 }

    /// Heiti tímabils: "júl–ágú".
    static func timabilHeiti(timabilNr: Int) -> String {
        let fyrsti = manudurStutt[2 * timabilNr - 2]
        let annar = manudurStutt[2 * timabilNr - 1]
        return "\(fyrsti)–\(annar)"
    }

    /// Heiti tímabilsins sem dagurinn fellur í (1–6).
    static func numerTimabils(dags: Date, kal: Calendar) -> Int {
        (kal.component(.month, from: dags) + 1) / 2
    }

    /// [fra, til] dagsetningabil tímabils, frá fyrsta degi fyrsta mánaðar til
    /// síðasta dags síðara mánaðar.
    static func timabilBil(ar: Int, timabilNr: Int, kal: Calendar) -> ClosedRange<Date> {
        let fyrsti = kal.date(from: DateComponents(year: ar, month: 2 * timabilNr - 1, day: 1))!
        let naesti = kal.date(from: DateComponents(year: ar, month: 2 * timabilNr + 1, day: 1))!
        let sidasti = kal.date(byAdding: .day, value: -1, to: naesti)!
        return fyrsti...sidasti
    }

    /// Býr til yfirlit fyrir valið tímabil. `timabilNr` er 1–6 (jan–feb … nóv–des);
    /// skráin ber númer Skattsins (08–48).
    @MainActor
    static func payload(invoices: [Invoice], expenses: [Expense], company: AppSettings,
                        ar: Int, timabilNr: Int, kal: Calendar) -> VskYfirlitPayload {
        let bil = timabilBil(ar: ar, timabilNr: timabilNr, kal: kal)
        let dagur = DateFormatter()
        dagur.calendar = kal
        dagur.timeZone = kal.timeZone
        dagur.dateFormat = "dd.MM.yyyy"

        // Útgefnir reikningar (og kreditreikningar) fyrirtækisins á tímabilinu,
        // ISK-eingöngu, dagsetningar samkvæmt bókunardegi (sjálfgefið útgáfudagur).
        let reikningar = invoices
            .filter {
                $0.isIssued && !$0.isEstimate && $0.currencyCode == "ISK"
                    && $0.issuer?.id == company.id
                    && bil.contains($0.bookingDate ?? $0.issueDate)
            }
            .sorted { ($0.bookingDate ?? $0.issueDate) < ($1.bookingDate ?? $1.issueDate) }

        var sala: [VskYfirlitPayload.Skjal] = []
        for inv in reikningar {
            let totals = EInvoiceTotals(invoice: inv)
            let dagsetning = dagur.string(from: inv.bookingDate ?? inv.issueDate)
            let heiti = inv.isCreditNote ? "Kreditreikningur" : "Reikningur"
            for st in totals.subtotals where st.base != 0 || st.tax != 0 {
                sala.append(.init(lysing: "\(heiti) \(inv.number) — \(dagsetning)",
                                  threp: threpTala(st.rate), netto: st.base, vsk: st.tax))
            }
        }

        // Kostnaður á tímabilinu — VSK upphæðin færð sem innskattur.
        // Aðeins kostnaður sem merktur er sem yfirfarinn fer með: VSKIL tekur
        // þá sjálfkrafa inn það sem hefur verið yfirfarið í RUKK.
        let kostnadur = expenses
            .filter {
                $0.currencyCode == "ISK" && $0.company?.id == company.id
                    && bil.contains($0.date) && $0.amount != 0 && $0.reviewed
            }
            .sorted { $0.date < $1.date }

        // Sundurliðuð færsla verður ein lína á hverju VSK-þrepi (sama
        // sundurliðun og prentast neðst á kvittuninni: „VSK 11% 1.432 158",
        // „VSK 24% 8.024 1.926"). Óúthlutaður munur (upphæð sem ekki ratar
        // á neitt þrep) fer sem undanþeginn hluti (þrep 0) svo ekkert glatist
        // á leiðinni yfir í VSKIL — heild innkaupanna er alltaf sú sama og
        // `amount`.
        let innkaup: [VskYfirlitPayload.Skjal] = kostnadur.flatMap { e -> [VskYfirlitPayload.Skjal] in
            let lysing = "\(e.vendor): \(e.expenseDescription) — \(dagur.string(from: e.date))"
            guard e.isVatSplit else {
                return [.init(lysing: lysing, threp: threpTala(e.taxRate),
                              netto: e.netAmount, vsk: e.vatAmount)]
            }
            var rows: [VskYfirlitPayload.Skjal] = []
            if e.splitGross24 != 0 {
                rows.append(.init(lysing: lysing, threp: 24,
                                  netto: e.netPart(gross: e.splitGross24, rate: 24),
                                  vsk: e.vatPart(gross: e.splitGross24, rate: 24)))
            }
            if e.splitGross11 != 0 {
                rows.append(.init(lysing: lysing, threp: 11,
                                  netto: e.netPart(gross: e.splitGross11, rate: 11),
                                  vsk: e.vatPart(gross: e.splitGross11, rate: 11)))
            }
            let afinnsla = e.splitGross0 + (e.amount - e.splitGross24 - e.splitGross11 - e.splitGross0)
            if afinnsla != 0 {
                rows.append(.init(lysing: lysing, threp: 0,
                                  netto: afinnsla, vsk: 0))
            }
            return rows
        }

        return VskYfirlitPayload(
            kennitala: company.companyNationalID,
            fyrirtaeki: company.displayName,
            vskNumer: company.companyVATNumber,
            ar: ar,
            timabil: rskNumer(timabilNr: timabilNr),
            timabilHeiti: timabilHeiti(timabilNr: timabilNr),
            dagsFra: isoDagur(bil.lowerBound, kal: kal),
            dagsTil: isoDagur(bil.upperBound, kal: kal),
            sala: sala,
            innkaup: innkaup,
            samtala: samtala(sala: sala, innkaup: innkaup)
        )
    }

    /// Sama flokkun og VSKIL notar: sala 24%/11% sérstaklega, önnur sala
    /// undanþegin; innskattur aðeins af 24%/11% innkaupum.
    static func samtala(sala: [VskYfirlitPayload.Skjal],
                        innkaup: [VskYfirlitPayload.Skjal]) -> VskYfirlitPayload.Samtala {
        var s = VskYfirlitPayload.Samtala()
        for x in sala {
            switch x.threp {
            case 24: s.velta24 += x.netto; s.utskattur24 += x.vsk
            case 11: s.velta11 += x.netto; s.utskattur11 += x.vsk
            default: s.undanthegin += x.netto
            }
        }
        for x in innkaup {
            switch x.threp {
            case 24: s.innskattur24 += x.vsk
            case 11: s.innskattur11 += x.vsk
            default: break
            }
        }
        s.velta24 = s.velta24.roundedMoney
        s.velta11 = s.velta11.roundedMoney
        s.undanthegin = s.undanthegin.roundedMoney
        s.utskattur24 = s.utskattur24.roundedMoney
        s.utskattur11 = s.utskattur11.roundedMoney
        s.innskattur24 = s.innskattur24.roundedMoney
        s.innskattur11 = s.innskattur11.roundedMoney
        return s
    }

    /// Decimal-þrep (24.0, 11.0, 0) yfir í heiltölu — námundað fyrst svo
    /// 24.5 verði ekki 24 fyrir slysni.
    static func threpTala(_ d: Decimal) -> Int {
        NSDecimalNumber(decimal: d.roundedMoney).intValue
    }

    /// yyyy-MM-dd fyrir dagsFra/dagsTil.
    static func isoDagur(_ d: Date, kal: Calendar) -> String {
        let c = kal.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: - Gjalddagi

    /// Gjalddagi tímabils: 5. dagur mánaðarins tveimur mánuðum á eftir
    /// lokamánuði tímabilsins (jan–feb → 5. apríl). Lendist dagurinn á
    /// helgi eða almennum frídegi færist hann á næsta virka dag
    /// („Færður vegna helgi" eins og VSKIL sýnir).
    static func gjalddagi(ar: Int, timabilNr: Int, kal: Calendar) -> (dags: Date, faerdur: Bool) {
        var manudur = 2 * timabilNr + 2
        var arUt = ar
        if manudur > 12 { manudur -= 12; arUt += 1 }
        var dags = kal.date(from: DateComponents(year: arUt, month: manudur, day: 5))!
        var faerdur = false
        while erFridagur(dags, kal: kal) {
            faerdur = true
            dags = kal.date(byAdding: .day, value: 1, to: dags)!
        }
        return (dags, faerdur)
    }

    /// Satt ef dagur er helgi eða íslenskur almennur frídagur. Fastir
    /// frídagar (1. jan, 1. maí, 17. jún, 24., 25., 26. og 31. des) geta
    /// aldrei lent á gjalddaga (5. degi) en eru með fyrir almennra nota.
    static func erFridagur(_ dags: Date, kal: Calendar) -> Bool {
        let vikudagur = kal.component(.weekday, from: dags)
        if vikudagur == 1 || vikudagur == 7 { return true }   // sunnu-/laugardagur
        let y = kal.component(.year, from: dags)
        let m = kal.component(.month, from: dags)
        let d = kal.component(.day, from: dags)
        let fastir: Set<Int> = [101, 501, 617, 1224, 1225, 1226, 1231]
        if fastir.contains(m * 100 + d) { return true }
        // Páskatengdir: skírdagur, langaföstudagur, páskadagur, annar í
        // páskum, uppstigningardagur, hvítasunnudagur, annar í hvítasunnu.
        let paskar = paskadagur(ar: y, kal: kal)
        for offset in [-3, -2, 0, 1, 39, 49, 50] {
            if let h = kal.date(byAdding: .day, value: offset, to: paskar),
               kal.isDate(h, inSameDayAs: dags) { return true }
        }
        // Frídagur verslunarmanna: fyrsti mánudagur í ágúst.
        if m == 8, let fyrsti = kal.date(from: DateComponents(year: y, month: 8, day: 1)) {
            let vd1 = kal.component(.weekday, from: fyrsti)
            if d == 1 + (9 - vd1) % 7 { return true }
        }
        return false
    }

    /// Páskadagur ársins — Anonymous Gregorian reikniritið.
    static func paskadagur(ar y: Int, kal: Calendar) -> Date {
        let a = y % 19, b = y / 100, c = y % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        return kal.date(from: DateComponents(year: y,
                                             month: (h + l - 7 * m + 114) / 31,
                                             day: (h + l - 7 * m + 114) % 31 + 1))!
    }

    /// Kóðar yfirlit sem JSON-gögn (fallega prentað, UTF-8).
    static func gogn(_ payload: VskYfirlitPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }
}
