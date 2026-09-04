import Foundation
import SwiftData

@Model
final class Invoice {
    var number: String = ""
    var isNumberLocked: Bool = false    // fast raðnúmer eftir útgáfu (sjá issue())
    var isCreditNote: Bool = false    // kreditreikningur (mótreikningur til leiðréttingar)
    var creditedInvoiceNumber: String = ""  // númer upprunalega reikningsins sem er leiðréttur
    var issueDate: Date = Date()
    var dueDate: Date?                // Gjalddagi
    var finalDueDate: Date?           // Eindagi (sjálfgefið gjalddagi + 5 dagar)
    var paymentTermDays: Int?
    var currencyCode: String = "ISK"
    var taxRate: Decimal = 24         // sjálfgefið VSK fyrir nýjar línur
    var isTaxInclusive: Bool = false
    var discountAmount: Decimal = 0        // afsláttur, alltaf í prósentum (%)
    var note: String = ""
    var statusRaw: String = InvoiceStatus.draft.rawValue
    var createdAt: Date = Date()
    var templateName: String = "icelandic"
    var collectionMethod: String = "Rafrænn reikningur"
    var bookingDate: Date?            // Bókunardagur (sjálfgefið = issueDate)
    var printedAt: Date?              // sett þegar reikningur er prentaður/fluttur út
    var paidAt: Date?                 // sett þegar staða verður „Greitt" (fyrir greiðsluhraða)
    var isEstimate: Bool = false      // tilboð — ekki lagalegur reikningur (convertToInvoice() breytir)
    var estimateNumber: String = ""   // tilboðsnúmer (t.d. R-T001), úthlutað við stofnun

    var isPrinted: Bool { printedAt != nil }

    var recipient: Contact?

    /// Fyrirtækið sem gaf reikninginn út (fast við útgáfu svo gamlir reikningar breytast ekki).
    var issuer: AppSettings?

    @Relationship(deleteRule: .cascade, inverse: \LineItem.invoice)
    var lineItems: [LineItem] = []

    var status: InvoiceStatus {
        get { InvoiceStatus(rawValue: statusRaw) ?? .draft }
        set {
            statusRaw = newValue.rawValue
            if newValue == .paid {
                if paidAt == nil { paidAt = .now }
            } else {
                paidAt = nil
            }
        }
    }

    /// Greiðsluhraði í dögum (frá útgáfu til greiðslu), ef greitt.
    var paymentDays: Int? {
        guard let paidAt else { return nil }
        return Calendar.current.dateComponents([.day], from: issueDate, to: paidAt).day
    }

    init(number: String = "", currencyCode: String = "ISK", taxRate: Decimal = 0) {
        self.number = number
        self.currencyCode = currencyCode
        self.taxRate = taxRate
        self.issueDate = .now
        self.createdAt = .now
    }

    /// Býr til, stillir og setur inn nýjan reikning fyrir tiltekið fyrirtæki.
    /// Reikningsnúmer fyrirtækis: forskeyti + núll-fyllt 3-stafa númer (001, 002, …).
    static func formattedNumber(prefix: String, _ n: Int) -> String {
        "\(prefix)\(String(format: "%03d", n))"
    }

    @MainActor
    static func makeNext(in context: ModelContext, company: AppSettings) -> Invoice {
        // Drög fá EKKERT númer — raðnúmer er úthlutað fyrst við útgáfu (issue()),
        // svo eytt drög brenna ekki númer og röðin verður gatalaus.
        let invoice = Invoice(number: "",
                              currencyCode: company.defaultCurrencyCode,
                              taxRate: company.defaultTaxRate)
        invoice.issuer = company
        invoice.paymentTermDays = company.defaultPaymentTermDays
        invoice.templateName = company.defaultTemplate
        invoice.note = company.defaultNote
        invoice.collectionMethod = company.collectionMethod
        invoice.bookingDate = invoice.issueDate
        if let term = invoice.paymentTermDays {
            invoice.dueDate = Calendar.current.date(byAdding: .day, value: term, to: invoice.issueDate)
        }
        // finalDueDate er látið ósett (nil) — `effectiveFinalDueDate` reiknar sjálfgefið
        // gjalddaga + sjálfgildi fyrirtækis þar til notandi sérstillir það.
        context.insert(invoice)
        return invoice
    }

    /// Hefur reikningurinn fengið fast útgáfunúmer?
    var isIssued: Bool { isNumberLocked && !number.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Bætir línum úr utanaðkomandi sendingu (BLIZZ, Tyme) aftast á reikninginn.
    @MainActor
    func append(_ lines: [InvoiceImportPayload.Line], in context: ModelContext) {
        var next = (lineItems.map(\.order).max() ?? -1) + 1
        for line in lines {
            let item = line.heading == true
                ? LineItem.heading(line.description, order: next)
                : LineItem(description: line.description,
                           quantity: line.quantity,
                           unitPrice: line.unitPrice,
                           taxRate: taxRate,
                           order: next)
            item.invoice = self
            lineItems.append(item)
            context.insert(item)
            next += 1
        }
    }

    /// Færir línu á nýjan stað í listanum og endurnúmerar `order` samfellt (0, 1, 2 …).
    /// `to` er staðan sem línan á að taka í listanum eins og hann var fyrir færsluna.
    @discardableResult
    func moveItem(from: Int, to: Int) -> Bool {
        var items = orderedItems
        guard from != to, items.indices.contains(from), items.indices.contains(to) else { return false }
        let moved = items.remove(at: from)
        items.insert(moved, at: min(to, items.count))
        for (i, item) in items.enumerated() { item.order = i }
        return true
    }

    /// Númer til birtingar í listum: reikningsnúmer, tilboðsnúmer, annars staðgengill.
    var displayNumber: String {
        let n = isEstimate ? estimateNumber : number
        return n.isEmpty ? String(localized: "(ekkert númer)") : n
    }

    /// Skráarheiti fyrir PDF/viðhengi: reikningsnúmer, tilboðsnúmer eða „reikningur“.
    var documentFileName: String {
        if !number.isEmpty { return number }
        if isEstimate && !estimateNumber.isEmpty { return estimateNumber }
        return "reikningur"
    }

    /// Gildistími tilboðs: sérstilltur (finalDueDate) ef settur, annars útgáfudagur + 30 dagar.
    var validUntil: Date {
        if let finalDueDate { return finalDueDate }
        return Calendar.current.date(byAdding: .day, value: 30, to: issueDate) ?? issueDate
    }

    /// Ógreiddur, útgefinn reikningur sem er gjaldfallinn — áminning á við.
    var isOverdue: Bool {
        !isEstimate && (status == .sent || status == .overdue) && effectiveFinalDueDate < .now
    }

    /// Eindagi til notkunar: sérstilltur ef settur, annars gjalddagi (eða útgáfudagur)
    /// + sjálfgildi fyrirtækis (5 dagar). Ein heimild fyrir ritil og reikningssnið.
    var effectiveFinalDueDate: Date {
        if let finalDueDate { return finalDueDate }
        let base = dueDate ?? issueDate
        let days = issuer?.defaultEindagiDays ?? 5
        return Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
    }

    /// Gefur reikninginn út: úthlutar næsta raðnúmeri fyrirtækisins (ef ekkert hefur þegar
    /// verið slegið inn handvirkt), festir númerið og setur stöðu í „Sent“.
    /// Kallast þegar ýtt er á „Gefa út reikning“ — í lok reikningsgerðar.
    @MainActor
    func issue() {
        if number.trimmingCharacters(in: .whitespaces).isEmpty, let company = issuer {
            number = Invoice.formattedNumber(prefix: company.invoiceNumberPrefix, company.nextInvoiceNumber)
            company.nextInvoiceNumber += 1
        }
        isNumberLocked = true
        if status == .draft { status = .sent }
    }

    /// Býr til kreditreikning (mótreikning) fyrir útgefinn reikning: afritar móttakanda og
    /// línur með NEIKVÆÐU magni svo fjárhæðir verði til frádráttar. Fær eigið raðnúmer við útgáfu.
    /// Leiðrétting útgefins reiknings skal gerð með kreditreikningi (reglug. 505/2013, 15. gr.).
    @MainActor
    static func makeCreditNote(for original: Invoice, in context: ModelContext) -> Invoice {
        let credit = Invoice(number: "", currencyCode: original.currencyCode, taxRate: original.taxRate)
        credit.issuer = original.issuer
        credit.recipient = original.recipient
        credit.isCreditNote = true
        credit.creditedInvoiceNumber = original.number
        credit.templateName = original.templateName   // sama snið og reikningurinn sem er leiðréttur
        credit.collectionMethod = original.collectionMethod
        credit.discountAmount = original.discountAmount
        credit.bookingDate = credit.issueDate
        credit.dueDate = credit.issueDate
        credit.finalDueDate = credit.issueDate
        credit.note = "Kreditreikningur vegna reiknings nr. \(original.number)."
        for item in original.orderedItems {
            let li = LineItem(description: item.itemDescription,
                              quantity: -item.quantity,
                              unitPrice: item.unitPrice,
                              taxRate: item.taxRate,
                              order: item.order)
            li.invoice = credit
            credit.lineItems.append(li)
            context.insert(li)
        }
        context.insert(credit)
        return credit
    }

    /// Býr til tilboð (ekki lagalegan reikningur): fær eigið T-númer strax og 30 daga
    /// gildistíma (finalDueDate, „Gildir til“). Verður að reikningi með convertToInvoice().
    /// Tilboð brenna ekki raðnúmerum og hafa engin gatalaus-númeraskilyrði.
    @MainActor
    static func makeEstimate(in context: ModelContext, company: AppSettings) -> Invoice {
        let estimate = Invoice(number: "",
                               currencyCode: company.defaultCurrencyCode,
                               taxRate: company.defaultTaxRate)
        estimate.issuer = company
        estimate.isEstimate = true
        estimate.estimateNumber = Invoice.formattedNumber(prefix: company.invoiceNumberPrefix + "T",
                                                          company.nextEstimateNumber)
        company.nextEstimateNumber += 1
        estimate.templateName = company.defaultTemplate
        estimate.note = company.defaultNote
        estimate.collectionMethod = company.collectionMethod
        estimate.finalDueDate = Calendar.current.date(byAdding: .day, value: 30, to: estimate.issueDate)
        context.insert(estimate)
        return estimate
    }

    /// Breytir tilboði í reikningsdrög: nýr útgáfa- og bókunardagur, gjalddagi eftir
    /// sjálfgefnum greiðslufresti fyrirtækis, tilvísun í tilboðið færð fremst í athugasemd.
    /// Raðnúmer fæst ekki fyrr en við útgáfu (issue()) — eins og venjuleg drög.
    @MainActor
    func convertToInvoice() {
        guard isEstimate else { return }
        isEstimate = false
        let now = Date.now
        issueDate = now
        bookingDate = now
        finalDueDate = nil
        paymentTermDays = issuer?.defaultPaymentTermDays
        if let term = paymentTermDays {
            dueDate = Calendar.current.date(byAdding: .day, value: term, to: now)
        }
        if !estimateNumber.isEmpty {
            let ref = "Samkvæmt tilboði nr. \(estimateNumber)."
            note = note.isEmpty ? ref : "\(ref)\n\(note)"
        }
        status = .draft
    }

    // MARK: - Computed totals

    var orderedItems: [LineItem] {
        lineItems.sorted { $0.order < $1.order }
    }

    /// Línur sem bera upphæð — fyrirsagnir eru aðeins texti og telja hvergi með.
    var billableItems: [LineItem] { lineItems.filter { !$0.isHeading } }

    var subtotal: Decimal {                                  // samtals án VSK
        billableItems.reduce(0) { $0 + $1.subtotal }
    }

    /// Afsláttur (prósenta af undirsamtölu) dreifist hlutfallslega á allar VSK-línur.
    var discountValue: Decimal { subtotal * discountAmount / 100 }

    /// Hlutfall verðs sem stendur eftir afslátt (1.0 = enginn afsláttur).
    var discountFactor: Decimal { 1 - discountAmount / 100 }

    var taxableBase: Decimal { subtotal - discountValue }   // skattstofn eftir afslátt

    var taxValue: Decimal {                                  // heildar VSK á afsláttargrunni
        vatBreakdown.reduce(0) { $0 + $1.tax }
    }

    var total: Decimal { taxableBase + taxValue }            // samtals með VSK

    /// Samtala línanna með VSK, fyrir afslátt — til að sýna í einu lagi á reikningi
    /// sem vísar á tímaskýrslu.
    var subtotalIncTaxTotal: Decimal {
        billableItems.reduce(0) { $0 + $1.subtotalIncTax }
    }

    /// Línusamtölur (án VSK, FYRIR afslátt) flokkað eftir VSK-hlutfalli.
    /// Notað fyrir skjals-afslátt í UBL (AllowanceCharge per skattflokk).
    var lineNetByRate: [(rate: Decimal, net: Decimal)] {
        Dictionary(grouping: billableItems, by: { $0.taxRate })
            .map { rate, items in (rate, items.reduce(Decimal(0)) { $0 + $1.subtotal }) }
            .sorted { $0.rate < $1.rate }
    }

    /// Sundurliðun VSK eftir hlutfalli, með afslátt dreginn frá grunni:
    /// [(hlutfall%, skattstofn eftir afslátt, VSK upphæð)].
    var vatBreakdown: [(rate: Decimal, base: Decimal, tax: Decimal)] {
        lineNetByRate.map { rate, net in
            let base = net * discountFactor
            return (rate, base, base * rate / 100)
        }
    }
}
