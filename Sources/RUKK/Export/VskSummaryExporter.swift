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

        // Sundurliðuð færsla verður ein lína á VSK-þrep (sama sundurliðun og
        // prentast neðst á kvittuninni: „VSK 11% 1.432 158", „VSK 24% 8.024 1.926").
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
            if e.splitGross0 != 0 {
                rows.append(.init(lysing: lysing, threp: 0, netto: e.splitGross0, vsk: 0))
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

    /// Kóðar yfirlit sem JSON-gögn (fallega prentað, UTF-8).
    static func gogn(_ payload: VskYfirlitPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }
}
