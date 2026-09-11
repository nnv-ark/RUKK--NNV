#if DEBUG
import Foundation
import SwiftData
import AppKit
import os

/// Eigin logger — appLog býr í RUKKApp.swift sem er utan SwiftPM-marksins.
private let demoLog = Logger(subsystem: "is.calmail.kula", category: "demo")

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

        // Öll fyrirtæki hér eru tilbúningur. Sýnigögnin rata í skjámyndir á App Store,
        // svo hér mega hvorki raunveruleg fyrirtæki né raunverulegar kennitölur koma við sögu.
        func customer(_ name: String, _ company: String, _ kt: String, _ email: String, _ addr: String) -> Contact {
            let c = Contact(name: name, company: company, nationalID: kt, email: email, phone: "", address: addr)
            c.owner = a
            context.insert(c)
            return c
        }
        let blaa = customer("Anna Björk", "Sjávarbakki ehf.", "4906091230", "reikningar@sjavarbakki.is", "Hafnargata 12\n240 Grindavík")
        let air = customer("Gunnar Þór", "Vindás Flutningar ehf.", "5102101450", "bokhald@vindas.is", "Fiskislóð 31\n101 Reykjavík")
        let marel = customer("Sigrún Halls", "Straumur Tækni ehf.", "6503121890", "reikningar@straumurtaekni.is", "Austurhraun 9\n210 Garðabær")
        let nordur = customer("Davíð Örn", "Ullarsel ehf.", "4408141670", "bokhald@ullarsel.is", "Bankastræti 5\n101 Reykjavík")

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
        // Langur reikningur — sýnir tímaskýrsluna sem tekur við þegar sundurliðunin
        // kemst ekki á reikninginn sjálfan.
        let longWork: [(String, Decimal, Decimal)] = [
            ("Verkfundur og þarfagreining", 6, 19000),
            ("Skissur — fyrsta yfirferð", 8, 19000),
            ("Skissur — önnur yfirferð", 5.5, 19000),
            ("Grunnmyndir 1. hæð", 12, 19000),
            ("Grunnmyndir 2. hæð", 9, 19000),
            ("Sniðteikningar", 7.5, 19000),
            ("Útlitsteikningar norður og austur", 6, 19000),
            ("Útlitsteikningar suður og vestur", 6, 19000),
            ("Deiliteikningar glugga", 4.5, 19000),
            ("Deiliteikningar stiga", 5, 19000),
            ("Efnisval og áferðir", 3.5, 19000),
            ("Samráð við burðarþolshönnuð", 4, 19000),
            ("Samráð við lagnahönnuð", 3, 19000),
            ("Yfirferð með verkkaupa", 2.5, 19000),
            ("Leiðréttingar eftir yfirferð", 6, 19000),
            ("Byggingarnefndarteikningar", 10, 19000),
            ("Umsókn og fylgigögn", 3, 19000),
            ("Svör við athugasemdum", 4, 19000),
            ("Magntaka", 5.5, 19000),
            ("Útboðsgögn", 8, 19000),
            ("Yfirferð tilboða", 3, 19000),
            ("Eftirlit á verkstað — september", 6, 19000),
            ("Eftirlit á verkstað — október", 6, 19000),
            ("Lokaúttekt", 4, 19000),
            ("Skilagögn og teikningasafn", 5, 19000),
        ]
        invoice(marel,  9, day(2026, 5, 28),  due: 30, status: .sent,
                note: "Sundurliðun fylgir í tímaskýrslu.", items: longWork)
        a.nextInvoiceNumber = 10

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

// MARK: - Skjámyndir fyrir App Store

/// Tekur mynd af eigin glugga — engin skjáupptökuheimild kemur við sögu, því
/// glugginn teiknar sig sjálfur í bitmap. EINGÖNGU í DEBUG.
@MainActor
enum Screenshotter {

    /// Mappan sem myndirnar lenda í. RUKK er í sandkassa, svo skrifað er í eigin
    /// gámamöppu — þaðan má afrita þær hvert sem er.
    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "AppStoreShots", directoryHint: .isDirectory)
    }

    /// Stillir gluggann á 1280×800 punkta — 2560×1600 dílar á Retina, sem er
    /// nákvæmlega það sem App Store vill fyrir macOS.
    static func resizeForAppStore() {
        guard let window = mainWindow else { return }
        // Á 1x-skjá yrði myndin 1280×800 díla; Retina-skjárinn skilar 2560×1600,
        // sem er stærðin sem App Store vill. Því er glugginn fluttur þangað fyrst.
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        var frame = window.frame
        let target = NSSize(width: 1280, height: 800)
        let chrome = frame.height - (window.contentView?.frame.height ?? frame.height)
        frame.size = NSSize(width: target.width, height: target.height + chrome)
        if let screen = retina {
            let visible = screen.visibleFrame
            frame.origin = NSPoint(x: visible.midX - frame.width / 2,
                                   y: visible.midY - frame.height / 2)
        }
        window.setFrame(frame, display: true)
    }

    /// Skrifar PNG af glugganum eins og hann er núna.
    @discardableResult
    static func capture(named name: String) -> URL? {
        guard let window = mainWindow else { NSSound.beep(); return nil }

        // cacheDisplay nær ekki SwiftUI-efninu (það býr í eigin lögum), svo glugginn
        // er myndaður eins og gluggi — eigin gluggi krefst engrar skjáupptökuheimildar.
        guard let cg = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(window.windowNumber),
                [.boundsIgnoreFraming, .bestResolution]) else {
            demoLog.error("Screenshot: window image unavailable")
            NSSound.beep(); return nil
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            NSSound.beep(); return nil
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: "\(name).png")
            try data.write(to: url)
            demoLog.info("Screenshot written: \(url.path, privacy: .public)")
            return url
        } catch {
            demoLog.error("Screenshot failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return nil
        }
    }

    /// Nafnlaus skot fá hlaupandi númer.
    private static var counter = 0
    static func captureNext() {
        counter += 1
        capture(named: String(format: "shot-%02d", counter))
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
    }
}


#endif
