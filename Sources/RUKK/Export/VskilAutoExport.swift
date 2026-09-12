import Foundation
import SwiftData
import AppKit

/// Sjálfvirkur VSKIL-flutningur: þegar kostnaðarfærslu er hakað „Búið að
/// yfirfara" (eða hákkið tekið af) er VSK-yfirlitið fyrir tímabilið
/// endurreiknað og skrifað í VSKIL-möppuna — sama skrá og handvirki
/// útflutningurinn (`_vskil-<kt>-<ár>-<tímabil>.json`), svo VSKIL tekur
/// alltaf inn nýjustu stöðuna.
///
/// Mappan er utan sandkassans — notandinn velur hana einu sinni og RUKK
/// geymir app-scope bókamerki (com.apple.security.files.bookmarks.app-scope).
enum VskilAutoExport {
    private static let enabledKey = "vskilAuto.enabled"
    private static let bookmarkKey = "vskilAuto.folderBookmark"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// VSKIL-mappan, leyst úr öruggu bókamerkinu. Nil ef ekki valin eða
    /// bókamerkið er úreltt (mappa færð/eydd — notandinn velur þá aftur).
    static var folderURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale), !stale
        else { return nil }
        return url
    }

    /// Notandinn velur VSKIL-möppu; bókamerkið er geymt og flutningur virkjaður.
    @discardableResult
    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Velja")
        panel.message = String(localized: "Veldu möppuna sem VSKIL les úr")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil) else { return nil }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        isEnabled = true
        return url
    }

    /// Kveikjan: færsla var yfirfarin (eða tekin úr yfirferð). Endurreiknar
    /// yfirlitið fyrir tímabil hennar og skrifar í VSKIL-möppuna.
    /// Skilar stuttum stöðutexta fyrir viðmótið; nil ef ekkert var gert
    /// (slökkt á þjónustunni, engin mappa, engin fyrirtækjaupplýsing).
    @MainActor
    @discardableResult
    static func expenseReviewChanged(_ expense: Expense, in context: ModelContext) -> String? {
        guard isEnabled, let folder = folderURL, let company = expense.company else { return nil }
        let kal = Calendar.current
        do {
            let url = try exportPeriod(containing: expense.date, company: company,
                                       to: folder, in: context, kal: kal)
            let timabilNr = VskSummaryExporter.numerTimabils(dags: expense.date, kal: kal)
            let heiti = VskSummaryExporter.timabilHeiti(timabilNr: timabilNr)
            return String(localized: "VSKIL uppfært — \(heiti) → \(url.lastPathComponent)")
        } catch {
            return nil
        }
    }

    /// Reiknar yfirlitið fyrir tímabilið sem `date` fellur í og skrifar það
    /// frumstætt í `folder`. Skilar slóð skrárinnar. Prófanlegur kjarni.
    @MainActor
    @discardableResult
    static func exportPeriod(containing date: Date, company: AppSettings,
                             to folder: URL, in context: ModelContext,
                             kal: Calendar) throws -> URL {
        let ar = kal.component(.year, from: date)
        let timabilNr = VskSummaryExporter.numerTimabils(dags: date, kal: kal)

        let invoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let payload = VskSummaryExporter.payload(invoices: invoices, expenses: expenses,
                                                 company: company, ar: ar,
                                                 timabilNr: timabilNr, kal: kal)
        let gogn = try VskSummaryExporter.gogn(payload)

        let nafn = "_vskil-\(company.companyNationalID)-\(ar)-\(VskSummaryExporter.rskNumer(timabilNr: timabilNr)).json"
        let url = folder.appendingPathComponent(nafn)
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        try gogn.write(to: url, options: .atomic)
        return url
    }
}
