#if DEBUG
import Foundation
import SwiftData
import AppKit

/// Demó-stuðningur — EINGÖNGU í DEBUG og aðeins virkur með ræsibreytum.
/// Notað til að taka skjámyndir (App Store). Fer aldrei í útgáfu (Release sleppir #if DEBUG).
enum Demo {
    /// `-RUKKDemo`: opnar appið (sleppir áskrift) og sáir íslenskum sýnigögnum.
    static var isActive: Bool { CommandLine.arguments.contains("-RUKKDemo") }
    /// `-RUKKPaywall`: þvingar áskriftarskjáinn (með staðgengilsverði) fyrir skjámynd.
    static var showPaywall: Bool { CommandLine.arguments.contains("-RUKKPaywall") }

    @MainActor
    static func seedIfNeeded(_ context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<AppSettings>())) ?? []
        guard existing.isEmpty else { return }

        let logo = logoData()
        let cal = Calendar(identifier: .gregorian)
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d)) ?? .now
        }

        // MARK: Fyrirtæki A — Norðurljós Hönnun ehf. (ríkulega útfyllt)
        let a = AppSettings()
        a.companyName = "Norðurljós Hönnun ehf."
        a.fullName = "Norðurljós Hönnun ehf."
        a.companyTagline = "hallo@nordurljos.is"
        a.companyEmail = "hallo@nordurljos.is"
        a.companyPhone = "519 4400"
        a.companyAddress = "Laugavegur 27\n101 Reykjavík"
        a.companyNationalID = "5811021450"
        a.companyVATNumber = "129876"
        a.bankAccountNumber = "0133-26-004567"
        a.invoiceNumberPrefix = "R-"
        a.logoData = logo
        context.insert(a)

        func customer(_ name: String, _ company: String, _ kt: String, _ email: String, _ addr: String) -> Contact {
            let c = Contact(name: name, company: company, nationalID: kt, email: email, phone: "", address: addr)
            c.owner = a
            context.insert(c)
            return c
        }
        let blaa = customer("Anna Björk", "Bláa Lónið hf.", "5006830489", "reikningar@bluelagoon.is", "Norðurljósavegur 9\n240 Grindavík")
        let air = customer("Gunnar Þór", "Icelandair ehf.", "4612951079", "ap@icelandair.is", "Reykjavíkurflugvöllur\n101 Reykjavík")
        let marel = customer("Sigrún Halls", "Marel hf.", "6710040570", "invoice@marel.is", "Austurhraun 9\n210 Garðabær")
        let nordur = customer("Davíð Örn", "66°Norður", "5304692359", "bokhald@66north.is", "Bankastræti 5\n101 Reykjavík")

        func invoice(_ recipient: Contact, _ n: Int, _ issue: Date, due: Int,
                     status: InvoiceStatus, paidAfter: Int? = nil, discount: Decimal = 0,
                     note: String = "", items: [(String, Decimal, Decimal)]) {
            let inv = Invoice(number: a.invoiceNumberPrefix + String(format: "%03d", n), currencyCode: "ISK", taxRate: 24)
            inv.issuer = a
            inv.recipient = recipient
            inv.issueDate = issue
            inv.bookingDate = issue
            inv.createdAt = issue
            inv.dueDate = cal.date(byAdding: .day, value: due, to: issue)
            inv.discountAmount = discount
            inv.note = note
            for (i, it) in items.enumerated() {
                let li = LineItem(description: it.0, quantity: it.1, unitPrice: it.2, taxRate: 24, order: i)
                li.invoice = inv
                inv.lineItems.append(li)
                context.insert(li)
            }
            if status == .paid, let paidAfter {
                inv.paidAt = cal.date(byAdding: .day, value: paidAfter, to: issue)
            }
            inv.status = status
            context.insert(inv)
        }

        invoice(blaa,   1, day(2025, 9, 3),  due: 14, status: .paid, paidAfter: 9,
                items: [("Vörumerkjahönnun", 1, 480000), ("Hönnunarstaðall", 1, 220000)])
        invoice(air,    2, day(2025, 10, 12), due: 14, status: .paid, paidAfter: 12,
                items: [("Vefhönnun – áfangi 1", 1, 650000)])
        invoice(marel,  3, day(2025, 11, 5),  due: 30, status: .paid, paidAfter: 21, discount: 10,
                note: "10% magnafsláttur.", items: [("UI/UX ráðgjöf", 40, 18500), ("Frumgerð í Figma", 1, 240000)])
        invoice(nordur, 4, day(2025, 12, 1),  due: 14, status: .paid, paidAfter: 6,
                items: [("Jólaherferð", 1, 390000), ("Prentgripir", 500, 320)])
        invoice(blaa,   5, day(2026, 2, 18),  due: 14, status: .sent,
                items: [("Vefhönnun – áfangi 2", 1, 650000), ("Myndataka", 1, 180000)])
        invoice(air,    6, day(2026, 3, 22),  due: 14, status: .sent, note: "Sent í tölvupósti.",
                items: [("Auglýsingahönnun", 12, 24000)])
        invoice(marel,  7, day(2026, 4, 9),   due: 7,  status: .sent,
                items: [("Skjákynning", 1, 145000)])               // gjaldfallið
        invoice(nordur, 8, day(2026, 5, 20),  due: 30, status: .sent,
                items: [("Vörusíða", 1, 410000), ("SEO-úttekt", 1, 95000)])
        a.nextInvoiceNumber = 9

        // Sýni-tilboð (opin fyrir „Breyta í reikning“).
        let est = Invoice(number: "", currencyCode: "ISK", taxRate: 24)
        est.issuer = a
        est.recipient = marel
        est.isEstimate = true
        est.estimateNumber = a.invoiceNumberPrefix + "T001"
        est.issueDate = day(2026, 8, 18)
        est.createdAt = est.issueDate
        est.finalDueDate = cal.date(byAdding: .day, value: 30, to: est.issueDate)
        est.note = "Gildir í 30 daga. Verð miðast við vinnufjölda hér að ofan."
        let estLi1 = LineItem(description: "UI/UX ráðgjöf", quantity: 30, unitPrice: 18500, taxRate: 24, order: 0)
        estLi1.invoice = est; est.lineItems.append(estLi1); context.insert(estLi1)
        let estLi2 = LineItem(description: "Frumgerð í Figma", quantity: 1, unitPrice: 240000, taxRate: 24, order: 1)
        estLi2.invoice = est; est.lineItems.append(estLi2); context.insert(estLi2)
        context.insert(est)
        a.nextEstimateNumber = 2

        // MARK: Fyrirtæki B — Verkfræðistofan Berg ehf.
        let b = AppSettings()
        b.companyName = "Verkfræðistofan Berg ehf."
        b.companyEmail = "berg@berg.is"
        b.companyAddress = "Suðurlandsbraut 18\n108 Reykjavík"
        b.companyNationalID = "4709001230"
        b.companyVATNumber = "98123"
        b.bankAccountNumber = "0515-26-112233"
        b.invoiceNumberPrefix = "B-"
        context.insert(b)
        let eva = Contact(name: "Eva Lind", company: "Verk ehf.", nationalID: "5402882459", email: "eva@verk.is", address: "Hafnargata 2\n220 Hafnarfjörður")
        eva.owner = b
        context.insert(eva)
        let bInv = Invoice(number: "B-001", currencyCode: "ISK", taxRate: 24)
        bInv.issuer = b
        bInv.recipient = eva
        bInv.issueDate = day(2026, 5, 4); bInv.createdAt = bInv.issueDate; bInv.bookingDate = bInv.issueDate
        bInv.dueDate = cal.date(byAdding: .day, value: 14, to: bInv.issueDate)
        let bLi = LineItem(description: "Burðarþolshönnun", quantity: 1, unitPrice: 540000, taxRate: 24, order: 0)
        bLi.invoice = bInv; bInv.lineItems.append(bLi); context.insert(bLi)
        bInv.paidAt = cal.date(byAdding: .day, value: 11, to: bInv.issueDate); bInv.status = .paid
        context.insert(bInv)
        b.nextInvoiceNumber = 2

        // MARK: Fyrirtæki C — Kaffi Krús ehf. (sýnir „mörg fyrirtæki")
        let c = AppSettings()
        c.companyName = "Kaffi Krús ehf."
        c.companyEmail = "kaffi@krus.is"
        c.companyAddress = "Austurvegur 22\n800 Selfoss"
        c.companyNationalID = "6201913310"
        c.invoiceNumberPrefix = "K-"
        context.insert(c)

        // Virkt fyrirtæki = A; sleppa einskiptis-leiðréttingu svo sýninúmer haldist.
        UserDefaults.standard.set(a.id.uuidString, forKey: "activeCompanyID")
        UserDefaults.standard.set(true, forKey: "kulaNormalizedV1")

        try? context.save()
    }

    /// PNG-gögn úr „Logo" eigninni (fyrir lógó sýnifyrirtækis).
    static func logoData() -> Data? {
        guard let img = NSImage(named: "Logo"),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
