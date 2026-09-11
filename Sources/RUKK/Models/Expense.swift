import Foundation
import SwiftData

/// Uppruni kostnaðarfærslu: handskráð eða byrjuð sem sending úr Bill To Book.
enum ExpenseSource: String, Codable, CaseIterable {
    case manual
    case billToBook
}

/// Kostnaðarfærsla (Kostnaður-flipinn). Handkráðar færslur og færslur úr
/// Bill To Book eru sama líkanið — `source` segir hvaðan færslan kom og
/// `receiptData` heldur myndinni sem Bill To Book sendir (eða droppuð kvittun).
@Model
final class Expense {
    var date: Date = Date()
    var vendor: String = ""                 // seljandi
    var expenseDescription: String = ""     // hvað var keypt
    var category: String = ""               // bókhaldsflokkur (frjáls texti)
    var amount: Decimal = 0                 // heildarupphæð með VSK
    var taxRate: Decimal = 24               // VSK-hlutfall (0 / 11 / 24)
    var currencyCode: String = "ISK"
    var note: String = ""
    /// Hakað við þegar færslan hefur verið yfirfarin (t.d. stemmd við kvittun).
    var reviewed: Bool = false
    /// Mynd kvittunar (PNG/JPEG-gögn). Fyllt af Bill To Book eða við drop.
    var receiptData: Data?
    var sourceRaw: String = ExpenseSource.manual.rawValue
    var createdAt: Date = Date()

    /// Fyrirtækið sem kostnaðurinn tilheyrir (eins og reikningar og viðskiptavinir).
    var company: AppSettings?

    var source: ExpenseSource {
        get { ExpenseSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    init(date: Date = .now, vendor: String = "", amount: Decimal = 0) {
        self.date = date
        self.vendor = vendor
        self.amount = amount
        self.createdAt = .now
    }

    /// VSK innifaldur í upphæðinni, reiknaður eins og á íslenskum kvittunum:
    /// nettó = upphæð ÷ (1 + hlutfall) námundað í minnsta einingu gjaldmiðils,
    /// VSK = upphæð − nettó. Þannig stemmir talan við „Þar af VSK" á kvittuninni
    /// (t.d. 5.000 kr. @ 11 % → nettó 4.505, VSK 495 — ekki 496 eins og beinn
    /// útreikningur 5.000 × 11/111 = 495,495… gæfi eftir tvöfalda námundun).
    var vatAmount: Decimal {
        guard taxRate > 0 else { return 0 }
        let scale = currencyCode == "ISK" ? 0 : 2
        var input = amount / (1 + taxRate / 100)
        var net = Decimal()
        NSDecimalRound(&net, &input, scale, .plain)
        return amount - net
    }

    /// Upphæð án VSK.
    var netAmount: Decimal { amount - vatAmount }

    /// Býr til, stillir og setur inn nýja færslu fyrir tiltekið fyrirtæki.
    @MainActor
    static func makeNext(in context: ModelContext, company: AppSettings) -> Expense {
        let expense = Expense()
        expense.company = company
        expense.taxRate = company.defaultTaxRate
        expense.currencyCode = company.defaultCurrencyCode
        context.insert(expense)
        return expense
    }

    /// Stofnfærir færslu sem byrjar sem sending úr Bill To Book: upphæð, seljandi
    /// og dagsetning lesið úr myndinni af appinu, myndin sjálf fylgir með.
    /// Lesið sjálft kemur síðar — þetta er tengipunkturinn sem það fyllir út í.
    @MainActor
    static func makeFromBillToBook(in context: ModelContext, company: AppSettings,
                                   receipt: Data? = nil) -> Expense {
        let expense = makeNext(in: context, company: company)
        expense.source = .billToBook
        expense.receiptData = receipt
        return expense
    }
}
