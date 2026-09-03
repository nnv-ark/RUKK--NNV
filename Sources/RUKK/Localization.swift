import Foundation

/// Tungumál sem RUKK styður — bæði fyrir viðmótið og fyrir reikninginn.
/// Viðmótið og reikningurinn eru valin sjálfstætt (t.d. enskt viðmót, íslenskur reikningur).
enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case icelandic = "is"
    case english = "en"

    var id: String { rawValue }

    /// Heiti tungumálsins á því sjálfu (til að sýna í vali).
    var displayName: String {
        switch self {
        case .icelandic: "Íslenska"
        case .english:   "English"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Öruggt uppflettinafn — fellur á íslensku ef gildið er óþekkt.
    static func from(_ raw: String) -> AppLanguage { AppLanguage(rawValue: raw) ?? .icelandic }

    /// Núverandi viðmótsmál lesið beint úr UserDefaults — til nota utan SwiftUI-view
    /// samhengis (t.d. DateFormatter/NumberFormatter fyrir mælaborð og lista).
    static var currentUI: AppLanguage {
        from(UserDefaults.standard.string(forKey: "uiLanguage") ?? AppLanguage.icelandic.rawValue)
    }
}

/// Textar reikningsins á völdu tungumáli. Sjálfstætt frá viðmótsmáli og
/// prófanlegt (engin bundle-uppfletting) — reikningurinn er lögformlegt skjal.
struct InvoiceStrings {
    let language: AppLanguage
    private var en: Bool { language == .english }

    init(_ language: AppLanguage) { self.language = language }

    // Haus
    var companyPlaceholder: String { en ? "COMPANY" : "FYRIRTÆKI" }

    // Reikningsupplýsingar
    var invoiceNo: String    { en ? "Invoice no." : "Reikningur nr." }
    var estimateNo: String   { en ? "Estimate no." : "Tilboð nr." }
    var validUntil: String   { en ? "Valid until" : "Gildir til" }
    var creditNoteNo: String { en ? "Credit note no." : "Kreditreikningur nr." }
    var creditReason: String { en ? "For invoice no." : "Vegna reiknings nr." }
    var customerNo: String   { en ? "Customer no." : "Viðskiptanúmer" }
    var issueDate: String    { en ? "Issue date" : "Útgáfudagur" }
    var bookingDate: String  { en ? "Booking date" : "Bókunardagur" }
    var dueDate: String      { en ? "Due date" : "Gjalddagi" }
    var finalDueDate: String { en ? "Final due date" : "Eindagi" }
    var collectionMethod: String { en ? "Payment method" : "Innh.máti" }

    // Töfluhausar
    var itemDescription: String { en ? "Description" : "Lýsing" }
    var quantity: String { en ? "Qty" : "Magn" }
    var amount: String   { en ? "Amount" : "Upphæð" }
    var unitPrice: String { en ? "Unit Price" : "Einingaverð" }
    var exclVAT: String  { en ? "(excl. VAT)" : "(án VSK)" }
    var inclVAT: String  { en ? "(incl. VAT)" : "(með VSK)" }
    var vat: String      { en ? "VAT" : "VSK" }
    var total: String    { en ? "Total" : "Samtals" }

    // Samtölur
    var subtotalExclVAT: String { en ? "Subtotal excl. VAT" : "Samtals án VSK" }
    var discount: String    { en ? "Discount" : "Afsláttur" }
    var taxableBase: String { en ? "Taxable base" : "Skattstofn" }
    var totalInclVAT: String { en ? "Total incl. VAT" : "Samtals með VSK" }

    var notes: String { en ? "Notes" : "Athugasemdir" }

    var footerLegal: String {
        en
        ? "This invoice is an external electronic source document pursuant to Icelandic Regulation No. 505/2013. The external electronic source document is deemed the original of the invoice."
        : "Þessi reikningur er rafrænt ytra frumgagn skv. reglugerð nr. 505/2013. Rafrænt ytra frumgagn reiknings telst frumrit hans."
    }

    // Forskeytt gildi
    func idNo(_ value: String) -> String { (en ? "ID no. " : "kt. ") + value }
    func phone(_ value: String) -> String { (en ? "Tel: " : "Sími: ") + value }
    func bankAccount(_ value: String) -> String { (en ? "Bank acc.: " : "Reikningsnr: ") + value }
    func vatNumber(_ value: String) -> String { (en ? "VAT no.: " : "VSK númer: ") + value }
    func discountLabel(_ percent: String) -> String { "\(discount) (\(percent)%)" }

    // Snið talna, gjaldmiðils og dagsetninga — á tungumáli reikningsins
    var currencySuffix: String { en ? "ISK" : "kr." }

    func amountString(_ d: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = language.locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: d as NSDecimalNumber) ?? "\(d)"
    }

    func currency(_ d: Decimal) -> String { amountString(d) + " " + currencySuffix }

    func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = language.locale
        f.dateFormat = "d.M.yyyy"
        return f.string(from: d)
    }
}
