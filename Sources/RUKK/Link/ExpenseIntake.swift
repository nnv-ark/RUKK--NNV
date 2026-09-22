import Foundation
import SwiftData

/// Sameiginleg móttaka kostnaðarkvittana — hvort sem þær berast beint úr
/// Bill To Book (RukkLinkService) eða í gegnum póstvaktina (ExpenseMailWatcher).
/// Stofnar færsluna samstundis með viðhenginu og fyllir síðan út það sem
/// Vision les af myndinni, þannig að færslan birtist strax.
@MainActor
enum ExpenseIntake {

    /// Niðurstaða móttöku: færslan sjálf og hvort hún var þegar til.
    struct Result {
        let expense: Expense
        /// Satt þegar sama kvittun (fyrirtæki + kvittunarnúmer) var þegar komin
        /// inn — `expense` er þá eldri færslan og engin ný var stofnuð.
        let isDuplicate: Bool
    }

    /// Stofnar Expense úr kvittunargögnum. Fyrirtækið er fundið eftir kennitölu
    /// þegar hún fylgir (FELAG-skráin, snið 3), annars eftir nafni; finnist
    /// ekkert fellur færslan á virka fyrirtækið. Endursend kvittun (sama númer,
    /// sama fyrirtæki) stofnar ekki aðra færslu.
    @discardableResult
    static func intake(
        receipt: Data,
        source: ExpenseSource,
        companyName: String? = nil,
        kennitala: String? = nil,
        receiptNumber: Int? = nil,
        date: Date? = nil,
        note: String = "",
        in context: ModelContext,
        fallbackCompany: AppSettings
    ) -> Result {
        let company = matchCompany(kennitala: kennitala, named: companyName, in: context)
            ?? fallbackCompany
        if let receiptNumber,
           let previous = existingReceipt(number: receiptNumber, company: company, in: context) {
            return Result(expense: previous, isDuplicate: true)
        }
        // Námunda fyrir geymslu: stórar myndir fara í 1800px JPEG, PDF helst
        // óbreytt (Bill To Book þjappar þegar sjálft).
        let storedReceipt = ReceiptImage.normalized(receipt)
        let expense = Expense.makeFromBillToBook(in: context, company: company,
                                                 receipt: storedReceipt)
        expense.source = source
        expense.receiptNumber = receiptNumber ?? 0
        if let date { expense.date = date }
        if let receiptNumber {
            expense.note = note.isEmpty
                ? "Kvittun #\(receiptNumber)"
                : "Kvittun #\(receiptNumber) — \(note)"
        } else {
            expense.note = note
        }

        // OCR: Vision keyrður undan aðalþræði, uppfærsla færslunnar á aðalþræði.
        // Líkanið sjálft er greipt — ekki persistentModelID, sem er TÍMABUNDIÐ
        // uns context er vistað (save() gerist í fetchUnseen) og úrelta
        // auðkennið olli SwiftData assertion-hruni.
        let receiptCopy = storedReceipt
        Task { @MainActor [expense] in
            let lines = await Task.detached(priority: .utility) {
                await ReceiptReader.textLines(from: receiptCopy)
            }.value
            let parsed = ReceiptParser.parse(lines: lines)
            guard parsed.vendor != nil || parsed.total != nil || parsed.date != nil else { return }
            guard expense.modelContext != nil else { return }   // eytt á meðan
            apply(parsed, to: expense)
        }
        return Result(expense: expense, isDuplicate: false)
    }

    /// Sama kvittun og barst rétt áðan? Endursending — t.d. þegar staðfestingin
    /// týndist á leiðinni og síminn reyndi póstleiðina líka — á ekki að stofna
    /// aðra færslu. Glugginn er vika: teljarinn í Bill To Book byrjar aftur á 1
    /// eftir enduruppsetningu og þá má gömul #1 ekki stöðva nýja kvittun.
    private static func existingReceipt(number: Int, company: AppSettings,
                                        in context: ModelContext) -> Expense? {
        guard number > 0 else { return nil }
        let cid = company.id
        let raw = ExpenseSource.billToBook.rawValue
        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        var descriptor = FetchDescriptor<Expense>(
            predicate: #Predicate<Expense> {
                $0.company?.id == cid
                    && $0.receiptNumber == number
                    && $0.sourceRaw == raw
                    && $0.createdAt > cutoff
            }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Fyllir út færslu úr kvittunarlestri — hreint fall, prófanlegt án OCR.
    /// Tvö eða fleiri VSK-þrep með nettó og VSK á línu (sundurliðunartaflan
    /// neðst á kvittunum: „VSK 11% 1.432 158") virkja sundurliðun sjálfkrafa.
    static func apply(_ parsed: ParsedReceipt, to expense: Expense) {
        if expense.vendor.isEmpty, let vendor = parsed.vendor {
            expense.vendor = vendor
        }
        if expense.amount == 0, let total = parsed.total {
            expense.amount = total
        }
        let rows = parsed.vatLines.compactMap { line -> (rate: Decimal, gross: Decimal)? in
            guard let net = line.net, let vat = line.vat else { return nil }
            return (line.rate, net + vat)
        }
        if parsed.vatLines.count >= 2, rows.count == parsed.vatLines.count,
           parsed.total != nil, !expense.isVatSplit {
            expense.isVatSplit = true
            for row in rows {
                switch row.rate {
                case 24:  expense.splitGross24 += row.gross
                case 11:  expense.splitGross11 += row.gross
                default:  expense.splitGross0 += row.gross
                }
            }
        }
        if !expense.isVatSplit, let rate = parsed.vatRate, parsed.total != nil {
            expense.taxRate = rate
        }
        // Dagsetningin Á kvittuninni er alltaf rétt kaupdagur — sendingardagur
        // Bill To Book (úr pósthausnum) er skannadagur og getur lent í röngu
        // VSK-tímabili. Kvittunardagur vinnur því alltaf þegar hann fæst.
        if let parsedDate = parsed.date {
            expense.date = parsedDate
        }
    }

    /// Finnur fyrirtækið sem kvittunin á að falla á. Kennitalan ræður þegar hún
    /// fylgir — hún kemur úr FELAG-skránni og er sama auðkennið beggja vegna.
    /// Annars er nafnið borið saman (bréfhlutfallslegt, þrengt) eins og áður.
    /// Finnist hvorugt skilar fallið nil og köllandi notar virkt fyrirtæki.
    private static func matchCompany(kennitala: String?, named name: String?,
                                     in context: ModelContext) -> AppSettings? {
        let all = (try? context.fetch(FetchDescriptor<AppSettings>())) ?? []
        if let digits = kennitala?.filter(\.isNumber), !digits.isEmpty,
           let match = all.first(where: { $0.companyNationalID.filter(\.isNumber) == digits }) {
            return match
        }
        guard let name, !name.isEmpty else { return nil }
        let needle = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return all.first {
            $0.companyName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == needle
                || $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == needle
        }
    }
}
