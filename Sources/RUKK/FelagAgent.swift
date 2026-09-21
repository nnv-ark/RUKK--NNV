//  FelagAgent.swift — RUKK
//  Tengir RUKK við FELAG: les companies.xml (sandkassinn fær aðgang með
//  öryggisumfangs bókamerki — sama mynstur og LAUNA notar fyrir valda möppu)
//  og samræmir auðkennisupplýsingarnar inn í AppSettings-færslurnar eftir
//  kennitölu. FELAG er eini ritill auðkennis (nafn, kennitala, VSK-númer,
//  heimilisfang, samskipti, banki, merki); RUKK heldur reikningsstillingar.
//
//  © 2026 NNV ehf.

import Foundation
import SwiftData
import AppKit
import FyrirtaekiKit

@MainActor
@Observable
final class FelagAgent {

    /// Fyrirtækin eins og þau liggja í companies.xml (tóm ef ekki tengt).
    private(set) var fyrirtæki: [Company] = []

    /// True þegar bókamerki leystist og companies.xml lasst.
    private(set) var tengt = false

    /// `active` auðkennið úr XML — notað til að velja sjálfgefið virkt fyrirtæki.
    private var xmlVirkt: String = ""

    private var aðgangsURL: URL?

    init() { endurhlaða() }

    // MARK: Tenging

    /// Opnar valmynd þar sem notandi velur FELAG-möppuna í fyrsta skipti.
    /// Bókamerkið er geymt í UserDefaults og gildir þar til því er eytt.
    func veljaMöppu() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Veldu FELAG-möppu"
        panel.message = "Veldu möppuna þar sem FELAG geymir companies.xml."
        panel.directoryURL = CompanyStore.defaultFileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope) else { return }
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        endurhlaða()
    }

    /// Gleyma bókamerkinu — RUKK fer þá alfarið á staðbundnu geymsluna.
    func aftengja() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        endurhlaða()
    }

    // MARK: Lesing

    /// Les companies.xml aftur (t.d. þegar forritið verður aftur virkt eða
    /// notandi velur möppu í fyrsta sinn). Ekkert bókamerki eða ólæsileg
    /// skrá → tengt = false og RUKK notar staðbundnu gögnin óbreytt.
    func endurhlaða() {
        hættaAðgang()
        // Sameignin með FELAG fyrst — þar þarf hvorki bókamerki né möppuval.
        // Bókamerkið hér að neðan er varaleið fyrir eldri FELAG utan hennar.
        if let sameign = CompanyStore.sameign {
            let file = sameign.load()
            fyrirtæki = file.companies
            xmlVirkt = file.active
            tengt = true
            return
        }
        guard let raw = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            fyrirtæki = []; tengt = false; return
        }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: raw, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                fyrirtæki = []; tengt = false; return
            }
            aðgangsURL = url
            let file = CompanyStore(fileURL: url.appendingPathComponent("companies.xml")).load()
            fyrirtæki = file.companies
            xmlVirkt = file.active
            tengt = true
        } catch {
            fyrirtæki = []; tengt = false
        }
    }

    // MARK: Samræming

    /// FELAG-fyrirtækið sem svarar til tiltekinna AppSettings, eftir kennitölu.
    func felagFyrirtæki(fyrir s: AppSettings) -> Company? {
        let kt = s.companyNationalID.filter(\.isNumber)
        guard !kt.isEmpty else { return nil }
        return fyrirtæki.first { $0.kennitala.filter(\.isNumber) == kt }
    }

    /// Dregur auðkenni FELAG-fyrirtækja inn í AppSettings-færslur (býr færslu
    /// ef kennitalan er ekki þegar til staðar). Kallað við ræsingu og þegar
    /// glugginn verður aftur virkur — FELAG breytist jafnvel meðan RUKK er
    /// í bili. Reikningsstillingar eru ósnortnar.
    func samræma(context: ModelContext) {
        #if DEBUG
        // Demó-gagnasafnið á að vera óháð FELAG svo forsyllur séu stöðugar.
        if Demo.isActive { return }
        #endif
        guard tengt else { return }

        var allar = (try? context.fetch(FetchDescriptor<AppSettings>())) ?? []
        for company in fyrirtæki {
            let kt = company.kennitala.filter(\.isNumber)
            let row: AppSettings
            if !kt.isEmpty, let match = allar.first(where: { $0.companyNationalID.filter(\.isNumber) == kt }) {
                row = match
            } else if !company.name.isEmpty,
                      let match = allar.first(where: { $0.companyName == company.name }) {
                row = match
            } else {
                row = AppSettings()
                context.insert(row)
                allar.append(row)
            }
            row.sync(frá: company)
        }
        try? context.save()

        // Sjálfgefið virkt fyrirtæki: ef staðbundið val vísar hvergi,
        // taka `active` úr XML (ef slík færsla finnst).
        let valið = UserDefaults.standard.string(forKey: "activeCompanyID") ?? ""
        guard !allar.contains(where: { $0.id.uuidString == valið }),
              let virkt = fyrirtæki.first(where: { $0.id.uuidString == xmlVirkt }) else { return }
        let kt = virkt.kennitala.filter(\.isNumber)
        if let row = allar.first(where: { $0.companyNationalID.filter(\.isNumber) == kt }) {
            UserDefaults.standard.set(row.id.uuidString, forKey: "activeCompanyID")
        }
    }

    // MARK: Einkamál

    private static let bookmarkKey = "felagMappaBookmark"

    private func hættaAðgang() {
        aðgangsURL?.stopAccessingSecurityScopedResource()
        aðgangsURL = nil
    }
}

extension AppSettings {
    /// Yfirfærir auðkenni frá FELAG-fyrirtæki — FELAG ræður þessum reitum.
    /// Reikningsstillingar (tölvar, snið, tölvupóstur, letur) eru ósnortnar.
    func sync(frá company: Company) {
        fullName = company.name
        companyName = company.name
        companyTagline = company.tagline
        companyEmail = company.email
        companyPhone = company.phone
        companyWebsite = company.website
        companyNationalID = company.kennitala
        companyVATNumber = company.vskNumber
        bankAccountNumber = company.bankAccount
        logoData = company.logoData
        var parts: [String] = []
        if !company.street.isEmpty { parts.append(company.street) }
        let póstBær = [company.postalCode, company.city].filter { !$0.isEmpty }.joined(separator: " ")
        if !póstBær.isEmpty { parts.append(póstBær) }
        companyAddress = parts.joined(separator: ", ")
    }
}
