import Foundation
import SwiftData

/// Sameiginleg móttaka kostnaðarkvittana — hvort sem þær berast beint úr
/// Bill To Book (RukkLinkService) eða í gegnum póstvaktina (ExpenseMailWatcher).
/// Stofnar færsluna samstundis með viðhenginu og fyllir síðan út það sem
/// Vision les af myndinni, þannig að færslan birtist strax.
@MainActor
enum ExpenseIntake {

    /// Stofnar Expense úr kvittunargögnum. `companyName` (frá Bill To Book) er
    /// parað við fyrirtæki í RUKK eftir nafni; finnst ekkert fellur færslan á
    /// virka fyrirtækið.
    @discardableResult
    static func intake(
        receipt: Data,
        source: ExpenseSource,
        companyName: String? = nil,
        receiptNumber: Int? = nil,
        date: Date? = nil,
        note: String = "",
        in context: ModelContext,
        fallbackCompany: AppSettings
    ) -> Expense {
        let company = matchCompany(named: companyName, in: context) ?? fallbackCompany
        // Námunda fyrir geymslu: stórar myndir fara í 1800px JPEG, PDF helst
        // óbreytt (Bill To Book þjappar þegar sjálft).
        let storedReceipt = ReceiptImage.normalized(receipt)
        let expense = Expense.makeFromBillToBook(in: context, company: company,
                                                 receipt: storedReceipt)
        expense.source = source
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
            if expense.vendor.isEmpty, let vendor = parsed.vendor {
                expense.vendor = vendor
            }
            if expense.amount == 0, let total = parsed.total {
                expense.amount = total
            }
            if let rate = parsed.vatRate, parsed.total != nil {
                expense.taxRate = rate
            }
            if let parsedDate = parsed.date, date == nil {
                expense.date = parsedDate
            }
        }
        return expense
    }

    /// Finnr fyrirtæki í RUKK með sama nafni og Bill To Book sendir (samanburður
    /// bréfhlutfallslegur, þrengdur). Annars nil og köllandi notar virkt fyrirtæki.
    private static func matchCompany(named name: String?, in context: ModelContext) -> AppSettings? {
        guard let name, !name.isEmpty else { return nil }
        let needle = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let all = (try? context.fetch(FetchDescriptor<AppSettings>())) ?? []
        return all.first {
            $0.companyName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == needle
                || $0.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == needle
        }
    }
}
