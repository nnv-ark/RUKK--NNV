import SwiftUI
import SwiftData
import os

let appLog = Logger(subsystem: "is.calmail.kula", category: "app")

@main
struct RUKKApp: App {
    let container: ModelContainer
    /// Tungumál viðmótsins — óháð tungumáli reikninga (sjá Stillingar → Tungumál).
    @AppStorage("uiLanguage") private var uiLanguage: String = AppLanguage.icelandic.rawValue

    init() {
        // Bundle.main velur á milli is.lproj/en.lproj eftir „AppleLanguages“, ekki eftir
        // SwiftUI-umhverfi — samstillt við hvert ræsingu svo viðmótið fylgi ávallt
        // valinu í Stillingar → Tungumál, óháð kerfismáli macOS.
        let uiLang = UserDefaults.standard.string(forKey: "uiLanguage") ?? AppLanguage.icelandic.rawValue
        UserDefaults.standard.set([uiLang], forKey: "AppleLanguages")

        do {
            #if DEBUG
            // Demó-ham keyrir á in-memory grunni svo sýnigögn snerti ekki raunveruleg gögn.
            let config = Demo.isActive ? ModelConfiguration(isStoredInMemoryOnly: true) : ModelConfiguration()
            container = try ModelContainer(
                for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self,
                configurations: config
            )
            #else
            container = try ModelContainer(
                for: Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self
            )
            #endif
        } catch {
            // ModelContainer failure at launch is unrecoverable — the store is corrupt or
            // the schema is incompatible. Surface it via Logger before terminating.
            appLog.fault("Failed to create ModelContainer: \(error, privacy: .public)")
            fatalError("Failed to create ModelContainer: \(error)")
        }
        #if DEBUG
        if Demo.isActive {
            MainActor.assumeIsolated { Demo.seedIfNeeded(container.mainContext) }
        }
        #endif
    }

    var body: some Scene {
        // Single-glugga svið: macOS bætir sjálfkrafa „RUKK“ atriði í Window-valmyndina
        // svo opna megi gluggann aftur eftir að honum er lokað (App Review gl. 4.0).
        Window("RUKK", id: "main") {
            RootView()
                .appAppearance()
        }
        .modelContainer(container)
        .defaultSize(width: 1200, height: 760)
        // Full hæð á tækjastikunni (eins og í BLIZZ) — ekki samanfallin titilrönd.
        .windowToolbarStyle(.unified(showsTitle: true))
        // Frjálst skalanlegur gluggi (innihald ræður lágmarki). `Window` fær annars
        // `.contentSize` sjálfgefið sem gerir hann erfiðan að stækka/minnka.
        .windowResizability(.contentMinSize)
        .commands { RUKKCommands() }
        .environment(\.locale, AppLanguage.from(uiLanguage).locale)

        Settings {
            SettingsView()
                .modelContainer(container)
                .appAppearance()
        }
        .defaultSize(width: 640, height: 760)
        .environment(\.locale, AppLanguage.from(uiLanguage).locale)
    }
}

// MARK: - Rótarsýn — áskriftargátt

/// Sýnir aðalviðmótið ef áskrift er virk, annars áskriftarskjáinn.
struct RootView: View {
    @State private var subscriptions = SubscriptionStore()
    /// Reikningur sem berst utanfrá — um `rukk://` slóð (t.d. úr Tyme) eða `.rukktime`
    /// skrá (bein sending úr BLIZZ) — bíður hér uns viðmótið er tilbúið.
    @State private var inbox = ImportInbox()
    /// DEBUG-only: leyfir að sleppa paywall við prófun (aldrei lesið í App Store-byggingum).
    @AppStorage("debugUnlocked") private var debugUnlocked = false

    private var forcePaywall: Bool {
        #if DEBUG
        return Demo.showPaywall
        #else
        return false
        #endif
    }

    private var unlocked: Bool {
        #if BETA_UNLOCK
        // Ópinber beta (GitHub DMG): StoreKit virkar ekki utan App Store/TestFlight,
        // svo paywall er sleppt. Fáninn er aldrei skilgreindur í App Store-byggingum.
        return true
        #else
        #if DEBUG
        if Demo.isActive { return true }
        if debugUnlocked { return true }
        #endif
        return subscriptions.isSubscribed
        #endif
    }

    var body: some View {
        ZStack {
            if forcePaywall {
                PaywallView(store: subscriptions)
            } else if unlocked {
                ContentView()
            } else if subscriptions.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            } else {
                PaywallView(store: subscriptions)
            }
        }
        .environment(subscriptions)
        .environment(inbox)
        .onOpenURL { url in
            if let payload = InvoiceImport.payload(from: url) {
                inbox.pending = payload
            }
        }
    }
}

// MARK: - Native valmyndaskipanir

struct RUKKCommands: Commands {
    @FocusedValue(\.newInvoice) private var newInvoice
    @FocusedValue(\.newEstimate) private var newEstimate
    @FocusedValue(\.printInvoice) private var printInvoice
    @FocusedValue(\.exportPDF) private var exportPDF
    @FocusedValue(\.exportXML) private var exportXML
    @FocusedValue(\.importCustomers) private var importCustomers

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nýr reikningur") { newInvoice?() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(newInvoice == nil)
            Button("Nýtt tilboð") { newEstimate?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(newEstimate == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Flytja inn viðskiptavini…") { importCustomers?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(importCustomers == nil)
            Divider()
            Button("Flytja út PDF…") { exportPDF?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exportPDF == nil)
            Button("Flytja út rafrænan reikning (UBL / TS-136)…") { exportXML?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(exportXML == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Prenta…") { printInvoice?() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(printInvoice == nil)
            Button("Síðuuppsetning…") { PDFRenderer.pageSetup() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

