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
    /// Sundurliðun eftir VSK-þrepum: hluti upphæðar (með VSK) í hvoru þrepi.
    /// Notað þegar kvittun spannar fleiri en eitt þrep — t.d. Rafha-kvittun
    /// með kaffi @ 11% (1.590) og grilli @ 24% (9.950). `isVatSplit` ræður
    /// hvort sundurliðunin gildir í stað eins hlutfalls fyrir allt.
    var isVatSplit: Bool = false
    var splitGross24: Decimal = 0
    var splitGross11: Decimal = 0
    var splitGross0: Decimal = 0
    var currencyCode: String = "ISK"
    var note: String = ""
    /// Hakað við þegar færslan hefur verið yfirfarin (t.d. stemmd við kvittun).
    var reviewed: Bool = false
    /// Stöðugt auðkenni fyrir VSK-yfirlitið sem VSKIL les (útgáfa 2).
    /// Tómt á eldri færslum þar til `VskSummaryExporter.tryggjaAudkenni`
    /// fyllir það í — aldrei breytt eftir það, því VSKIL þekkir röðina á því.
    var vskilAudkenni: String = ""
    /// Mynd kvittunar (PNG/JPEG-gögn). Fyllt af Bill To Book eða við drop.
    var receiptData: Data?
    /// Kvittunarnúmer úr teljara Bill To Book (0 = ekkert). Þekkir endursenda
    /// kvittun svo sama sendingin stofni ekki tvær færslur.
    var receiptNumber: Int = 0
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
    /// Við sundurliðun er VSK summan af VSK hvers þreps fyrir sig.
    var vatAmount: Decimal {
        if isVatSplit {
            return vatPart(gross: splitGross24, rate: 24)
                 + vatPart(gross: splitGross11, rate: 11)
        }
        guard taxRate > 0 else { return 0 }
        return vatPart(gross: amount, rate: taxRate)
    }

    /// Nettóhluti upphæðar í tilteknu þrepi (námundaður eins og á kvittun).
    func netPart(gross: Decimal, rate: Decimal) -> Decimal {
        let scale = currencyCode == "ISK" ? 0 : 2
        var input = gross / (1 + rate / 100)
        var net = Decimal()
        NSDecimalRound(&net, &input, scale, .plain)
        return net
    }

    /// VSK-hluti upphæðar í tilteknu þrepi: gross − námundað nettó.
    func vatPart(gross: Decimal, rate: Decimal) -> Decimal {
        guard rate > 0, gross != 0 else { return 0 }
        return gross - netPart(gross: gross, rate: rate)
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
