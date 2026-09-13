import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import FyrirtaekiKit
import os

private let settingsLog = Logger(subsystem: "is.calmail.kula", category: "settings")

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AppSettings.companyName) private var companies: [AppSettings]
    @AppStorage("activeCompanyID") private var activeCompanyID = ""
    @State private var selectedID: String = ""
    @State private var flipi: SettingsFlipi = .snid

    private var selected: AppSettings? {
        companies.first { $0.id.uuidString == selectedID } ?? companies.first
    }

    var body: some View {
        HStack(spacing: 0) {
            flipaStika
            Divider()
            VStack(spacing: 0) {
                companyBar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
                if let s = selected {
                    flipaInnihald(s)
                        .id(s.id)                       // endurræsir flipa þegar skipt er um fyrirtæki
                        .padding()
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(flipi.heiti)
        .frame(minWidth: 620, minHeight: 500)
        .task {
            let company = AppSettings.active(in: context, activeID: activeCompanyID)
            if activeCompanyID.isEmpty { activeCompanyID = company.id.uuidString }
            if selectedID.isEmpty { selectedID = company.id.uuidString }
        }
    }

    /// Lóðrétt táknastika vinstra megin — sama mynstur og VSKIL notar.
    /// Aðeins tákn; heitið birtist sem vísbending (help) og í gluggatitli.
    private var flipaStika: some View {
        VStack(spacing: 4) {
            ForEach(SettingsFlipi.allCases) { f in
                Button { flipi = f } label: {
                    Image(systemName: f.takn)
                        .font(.system(size: 17))
                        .foregroundStyle(flipi == f ? .primary : .secondary)
                        .frame(width: 40, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(flipi == f ? 0.12 : 0))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(f.heiti)
            }
            Spacer()
        }
        .padding(.top, 12)
        .padding(.horizontal, 8)
        .frame(width: 56)
    }

    @ViewBuilder
    private func flipaInnihald(_ s: AppSettings) -> some View {
        switch flipi {
        case .snid:      ProfileTab(settings: s)
        case .reikningur: InvoiceTab(settings: s)
        case .utlit:     AppearanceTab(settings: s)
        case .stodur:    StatusesTab()
        case .tungumal:  LanguageTab(settings: s)
        case .postvakt:  MailWatchTab()
        case .vskil:     VskilTab()
        }
    }

    private var companyBar: some View {
        HStack(spacing: 8) {
            // Merki fyrirtækisins efst — sami haus og VSKIL sýnir.
            if let data = selected?.logoData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Picker("Fyrirtæki", selection: $selectedID) {
                ForEach(companies) { c in
                    Text(c.displayName).tag(c.id.uuidString)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)

            Button { addCompany() } label: { Image(systemName: "plus") }
                .help("Nýtt fyrirtæki")
            Button { if let s = selected { delete(s) } } label: { Image(systemName: "minus") }
                .help("Eyða fyrirtæki")
                .disabled(companies.count <= 1)

            Spacer()

            if let s = selected {
                if s.id.uuidString == activeCompanyID {
                    Label("Virkt", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("Gera virkt") { activeCompanyID = s.id.uuidString }
                }
            }
        }
    }

    private func addCompany() {
        let c = AppSettings()
        c.companyName = "Nýtt fyrirtæki"
        context.insert(c)
        selectedID = c.id.uuidString
    }

    private func delete(_ company: AppSettings) {
        guard companies.count > 1 else { return }
        let wasActive = company.id.uuidString == activeCompanyID
        context.delete(company)
        if wasActive, let next = companies.first(where: { $0.id != company.id }) {
            activeCompanyID = next.id.uuidString
            selectedID = next.id.uuidString
        }
    }
}

/// Fliparnir í Stillingum — lóðrétt táknaröð vinstra megin eins og í VSKIL.
private enum SettingsFlipi: CaseIterable, Identifiable {
    case snid, reikningur, utlit, stodur, tungumal, postvakt, vskil

    var id: Self { self }

    var heiti: String {
        switch self {
        case .snid:       return "Snið"
        case .reikningur: return "Reikningur"
        case .utlit:      return "Útlit"
        case .stodur:     return "Stöður"
        case .tungumal:   return "Tungumál"
        case .postvakt:   return "Póstvakt"
        case .vskil:      return "VSKIL"
        }
    }

    var takn: String {
        switch self {
        case .snid:       return "person.crop.square"
        case .reikningur: return "doc.text"
        case .utlit:      return "textformat"
        case .stodur:     return "tag"
        case .tungumal:   return "globe"
        case .postvakt:   return "envelope.badge"
        case .vskil:      return "arrow.right.doc.on.clipboard"
        }
    }
}

// MARK: - VSKIL (sjálfvirkur flutningur við yfirferð)

/// Stillingar sjálfvirks VSKIL-flutnings: þegar kostnaðarfærslu er hakað
/// „Búið að yfirfara" er VSK-yfirlitið fyrir tímabilið skrifað í VSKIL-möppuna.
private struct VskilTab: View {
    @State private var folder: URL? = VskilAutoExport.folderURL
    @State private var enabled: Bool = VskilAutoExport.isEnabled

    var body: some View {
        Form {
            Section("Sjálfvirkur flutningur") {
                Toggle("Senda í VSKIL þegar færslu er yfirfarið", isOn: Binding(
                    get: { enabled },
                    set: { enabled = $0; VskilAutoExport.isEnabled = $0 }))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VSKIL-mappa")
                        Text(folder?.path ?? String(localized: "Engin mappa valin"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Velja möppu…") {
                        if let url = VskilAutoExport.chooseFolder() {
                            folder = url
                            enabled = true
                        }
                    }
                }
            }
            Section {
                Text("Þegar þú hakkar „Búið að yfirfara“ á kostnaðarfærslu endurreiknar RUKK VSK-yfirlitið fyrir tímabilið og skrifar það í VSKIL-möppuna. VSKIL les skrána („Hlaupa úr RUKK…“) með nýjustu stöðunni. Aðeins yfirfarðar færslur fara með.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            folder = VskilAutoExport.folderURL
            enabled = VskilAutoExport.isEnabled
        }
    }
}

// MARK: - Póstvakt (Kostnaður ← tölvupóstur)

/// Stillingar pósvaktarinnar — IMAP-fang sem Bill To Book (eða annar) sendir
/// kvittanir á. Lykilorð/umbóðskóði geymist í Keychain, aldrei í UserDefaults.
private struct MailWatchTab: View {
    @Environment(ExpenseMailWatcher.self) private var watcher: ExpenseMailWatcher?
    @State private var password = ""
    @State private var testResult: String?

    var body: some View {
        Form {
            Section("Pósthólf") {
                Toggle("Vakta pósthólf", isOn: Binding(
                    get: { watcher?.settings.isEnabled ?? false },
                    set: { watcher?.settings.isEnabled = $0 }))
                TextField("Póstþjónn (IMAP)", text: Binding(
                    get: { watcher?.settings.host ?? "" },
                    set: { watcher?.settings.host = $0 }),
                    prompt: Text("imap.gmail.com"))
                TextField("Gátt", value: Binding(
                    get: { watcher?.settings.port ?? 993 },
                    set: { watcher?.settings.port = $0 }), format: .number)
                TextField("Notandanafn (netfang)", text: Binding(
                    get: { watcher?.settings.username ?? "" },
                    set: { watcher?.settings.username = $0 }),
                    prompt: Text("kvittanir@example.is"))
                SecureField("Lykilorð / umbóðskóði", text: $password,
                            prompt: Text("geymst í Keychain"))
                    .onSubmit {
                        guard !password.isEmpty else { return }
                        watcher?.settings.setPassword(password)
                        password = ""
                        testResult = String(localized: "Lykilorð vistað í Keychain.")
                    }
                    .onChange(of: password) { old, new in
                        // Líming (stök breyting um fleiri en einn staf) vistar
                        // strax; stafur-sleginn-í-einu vistar með Enter (onSubmit).
                        guard new.count - old.count > 1 else { return }
                        watcher?.settings.setPassword(new)
                        password = ""
                        testResult = String(localized: "Lykilorð vistað í Keychain.")
                    }
                TextField("Pósthólf", text: Binding(
                    get: { watcher?.settings.mailbox ?? "INBOX" },
                    set: { watcher?.settings.mailbox = $0.isEmpty ? "INBOX" : $0 }))
            }
            Section {
                Text("Bill To Book sendir skannið í tölvupósti á þetta netfang. RUKK sækir ólesnar kvittanir reglulega á meðan appið er opið, les þær og stofnar kostnaðarfærslur. Notaðu app-lykilorð / umbóðskóða frá póstþjónustunni — ekki venjulegt innskráningarlykilorð.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Prófa tengingu") { testConnection() }
                        .disabled(watcher == nil)
                    if let testResult {
                        Text(testResult)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testConnection() {
        guard let watcher else { return }
        let settings = watcher.settings
        testResult = String(localized: "Prófar…")
        Task {
            do {
                guard let password = settings.password() else {
                    testResult = String(localized: "Lykilorð vantar.")
                    return
                }
                let client = IMAPClient(host: settings.host, port: UInt16(settings.port))
                try await client.connect()
                try await client.login(username: settings.username, password: password)
                try await client.select(mailbox: settings.mailbox)
                await client.logout()
                testResult = String(localized: "Tenging í lagi ✓")
            } catch {
                testResult = error.localizedDescription
            }
        }
    }
}

// MARK: - Profile

private struct ProfileTab: View {
    @Bindable var settings: AppSettings
    @Environment(FelagAgent.self) private var felag

    /// True þegar þessi færsla fylgir FELAG-fyrirtæki — þá eru auðkenni,
    /// samskipti og merki stjórnað í FELAG (samstillt hingað eftir kennitölu).
    private var fráFelag: Bool { felag.felagFyrirtæki(fyrir: settings) != nil }

    var body: some View {
        Form {
            Section("Merki") {
                if fráFelag {
                    HStack(spacing: 12) {
                        FelagLogoSýn(data: settings.logoData)
                        Text("Merkið er stjórnað í FELAG.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LogoPicker(data: $settings.logoData)
                }
                Slider(value: $settings.logoScale, in: 0.5...3.0, step: 0.05) {
                    Text("Stærð")
                } minimumValueLabel: { Text("50%") } maximumValueLabel: { Text("300%") }
                LabeledContent("Skali", value: "\(Int(settings.logoScale * 100))%")
            }
            Section("Auðkenni") {
                if fráFelag {
                    LabeledContent("Fyrirtæki", value: settings.companyName.isEmpty ? "—" : settings.companyName)
                    LabeledContent("Kennitala",
                                   value: Kennitala(settings.companyNationalID)?.formatted
                                        ?? (settings.companyNationalID.isEmpty ? "—" : settings.companyNationalID))
                    LabeledContent("VSK-númer", value: settings.companyVATNumber.isEmpty ? "—" : settings.companyVATNumber)
                    LabeledContent("Bankareikningur",
                                   value: settings.bankAccountNumber.isEmpty ? "—" : settings.bankAccountNumber)
                    Text("Stjórnað í FELAG — auðkenni, heimilisfang, samskipti og merki eru breytt þar og samstillt hingað.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    TextField("Fullt nafn", text: $settings.fullName)
                    TextField("Fyrirtæki", text: $settings.companyName)
                    TextField("Kennitala", text: $settings.companyNationalID)
                    TextField("VSK-númer", text: $settings.companyVATNumber)
                    TextField("Bankareikningur (Reikningsnr.)", text: $settings.bankAccountNumber)
                }
                TextField("Innh.máti (sjálfgefið)", text: $settings.collectionMethod)
            }
            Section("Hafa samband") {
                if fráFelag {
                    LabeledContent("Netfang", value: settings.companyEmail.isEmpty ? "—" : settings.companyEmail)
                    LabeledContent("Sími", value: settings.companyPhone.isEmpty ? "—" : settings.companyPhone)
                    LabeledContent("Vefsíða", value: settings.companyWebsite.isEmpty ? "—" : settings.companyWebsite)
                    LabeledContent("Heimilisfang", value: settings.companyAddress.isEmpty ? "—" : settings.companyAddress)
                } else {
                    TextField("Netfang", text: $settings.companyEmail)
                    TextField("Sími", text: $settings.companyPhone)
                    TextField("Vefsíða", text: $settings.companyWebsite)
                    TextField("Heimilisfang", text: $settings.companyAddress, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            Section("FELAG") {
                if felag.tengt {
                    Label("Tengt við FELAG — auðkenni og merki samstillt úr companies.xml.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Aftengja FELAG…") { felag.aftengja() }
                        .font(.caption)
                } else {
                    Text("FELAG geymir sameiginlegu fyrirtækjagögnin (nafn, kennitala, VSK-númer, heimilisfang, banki, merki) sem VSKIL, RUKK, BLIZZ og LAUNA deila.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Tengjast FELAG…") { felag.veljaMöppu() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Óbreytanleg sýn á merki (FELAG-ham) — sami rammi og LogoPicker.
private struct FelagLogoSýn: View {
    let data: Data?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.1))
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 80, height: 80)
        .background(data != nil && colorScheme == .dark ? Color.white.opacity(0.92) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct LogoPicker: View {
    @Binding var data: Data?
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDropTarget = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.1))
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 80, height: 80)
            // Dökk merki á gagnsæjum grunni þurfa ljósan flöt í dökku útliti.
            .background(data != nil && colorScheme == .dark ? Color.white.opacity(0.92) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Draga mynd beint á reitinn í stað þess að fara gegnum „Velja mynd…“.
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 2)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: DroppedFile.isImage),
                      let dropped = DroppedFile.data(at: url),
                      NSImage(data: dropped) != nil else { return false }
                data = dropped
                return true
            } isTargeted: { isDropTarget = $0 }

            VStack(alignment: .leading, spacing: 6) {
                Button("Velja mynd…", action: choose)
                if data != nil {
                    Button("Fjarlægja", role: .destructive) { data = nil }
                }
                Text("PNG, JPEG eða SVG — eða dragðu mynd á reitinn. Birtist efst á hverjum reikningi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            data = try Data(contentsOf: url)
        } catch {
            settingsLog.error("Failed to load logo from \(url, privacy: .public): \(error, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Tókst ekki að lesa myndina")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Invoice defaults

private struct InvoiceTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Sjálfgildi") {
                TextField("Myntkóði", text: $settings.defaultCurrencyCode)
                LabeledContent("Virðisaukaskattur %") {
                    TextField("", value: $settings.defaultTaxRate, format: .number)
                        .frame(maxWidth: 100)
                }
                LabeledContent("Greiðslufrestur (dagar)") {
                    TextField("", value: $settings.defaultPaymentTermDays, format: .number)
                        .frame(maxWidth: 100)
                }
                LabeledContent("Eindagi — dagar eftir gjalddaga") {
                    TextField("", value: $settings.defaultEindagiDays, format: .number)
                        .frame(maxWidth: 100)
                }
                Picker("Dagsetningarsnið", selection: $settings.dateFormat) {
                    Text("Stutt").tag("short")
                    Text("Miðlungs").tag("medium")
                    Text("Langt").tag("long")
                }
                Picker("Reikningssnið", selection: $settings.defaultTemplate) {
                    Text("Íslenskt (reglug. 505/2013)").tag("icelandic")
                    Text("Universal (enska)").tag("universal")
                }
            }
            Section("Númerakerfi") {
                TextField("Forskeyti", text: $settings.invoiceNumberPrefix)
                LabeledContent("Næsta númer") {
                    TextField("", value: $settings.nextInvoiceNumber, format: .number)
                        .frame(maxWidth: 100)
                }
            }
            Section("Sjálfgefin athugasemd") {
                TextEditor(text: $settings.defaultNote)
                    .frame(minHeight: 80)
            }
            Section {
                TextField("Efni", text: $settings.emailSubject)
                TextEditor(text: $settings.emailBody)
                    .frame(minHeight: 120)
            } header: {
                Text("Tölvupóstur til viðskiptavinar")
            } footer: {
                Text("Sjálfvirkt útfyllt: {nafn} = nafn viðskiptavinar · {númer} = reikningsnúmer · {fyrirtæki} = nafn fyrirtækis.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance / typography

private struct AppearanceTab: View {
    @Bindable var settings: AppSettings
    @AppStorage("appAppearance") private var appAppearance = AppAppearance.system.rawValue

    private let families: [String] = {
        (["" ] + NSFontManager.shared.availableFontFamilies).sorted {
            $0.isEmpty ? true : ($1.isEmpty ? false : $0 < $1)
        }
    }()

    var body: some View {
        Form {
            Section {
                Picker("Útlit", selection: $appAppearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Útlit forritsins")
            } footer: {
                Text("Gildir um RUKK sjálft. Reikningurinn breytist ekki — hann er alltaf prentaður á hvítan pappír.")
            }

            Section("Leturgerð") {
                Picker("Letur", selection: $settings.fontName) {
                    ForEach(families, id: \.self) { fam in
                        Text(fam.isEmpty ? String(localized: "Kerfisletur") : fam).tag(fam)
                    }
                }
                Stepper(value: $settings.baseFontSize, in: 7...16, step: 0.5) {
                    LabeledContent("Grunnstærð", value: "\(settings.baseFontSize.formatted()) pt")
                }
                Stepper(value: $settings.headingFontSize, in: 18...48, step: 1) {
                    LabeledContent("Fyrirsögn / logo-texti", value: "\(settings.headingFontSize.formatted()) pt")
                }
                ColorPicker("Litur texta", selection: Binding(
                    get: { Color(hex: settings.textColorHex) ?? .black },
                    set: { settings.textColorHex = $0.toHex() ?? "#000000" }
                ))
            }

            Section("Blaðsíða") {
                Picker("Pappírsstærð", selection: $settings.paperSize) {
                    Text("A4").tag("a4")
                    Text("US Letter").tag("letter")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Language

/// Tvö óháð tungumálaval: viðmótið (allt forritið) og reikningurinn (þetta fyrirtæki).
/// Þannig má t.d. keyra enskt viðmót en gefa út íslenska reikninga.
private struct LanguageTab: View {
    @Bindable var settings: AppSettings
    @AppStorage("uiLanguage") private var uiLanguage: String = AppLanguage.icelandic.rawValue
    @State private var needsRestart = false

    var body: some View {
        Form {
            Section {
                Picker("Viðmót", selection: $uiLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: uiLanguage) { _, newValue in
                    // macOS velur is.lproj/en.lproj eftir „AppleLanguages“ við ræsingu —
                    // breytingin krefst því endurræsingar til að taka gildi alls staðar.
                    UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                    needsRestart = true
                }

                if needsRestart {
                    HStack {
                        Label("Endurræstu RUKK til að breytingin taki gildi alls staðar.", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Endurræsa núna", action: relaunch)
                    }
                }
            } header: {
                Text("Tungumál viðmóts")
            } footer: {
                Text("Ræður tungumáli valmynda, hnappa og texta í RUKK sjálfu.")
            }

            Section {
                Picker("Reikningur", selection: $settings.invoiceLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Tungumál reiknings")
            } footer: {
                Text("Ræður tungumáli á PDF-reikningum þessa fyrirtækis — óháð tungumáli viðmóts að ofan. Tekur gildi samstundis, engin endurræsing þörf.")
            }
        }
        .formStyle(.grouped)
    }

    /// Ræsir nýtt eintak af RUKK og lokar núverandi — eina leiðin til að láta
    /// macOS endurmeta hvaða `.lproj` möppu skal nota fyrir viðmótið.
    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundleURL.path]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Custom statuses

private struct StatusesTab: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomStatus.order) private var statuses: [CustomStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sérsniðnar stöður").font(.headline)
                Spacer()
                Button {
                    let s = CustomStatus(name: "Ný staða", colorHex: "#888888",
                                         order: (statuses.map(\.order).max() ?? -1) + 1)
                    context.insert(s)
                } label: { Label("Bæta við", systemImage: "plus") }
            }
            Text("Innbyggðar stöður (Drög, Sent, Greitt, Á eftir, Endurgreitt, Hætt við) eru alltaf í boði. Sérsniðnar stöður birtast við hlið þeirra í reikningsvalmyndinni.")
                .font(.caption).foregroundStyle(.secondary)

            List {
                ForEach(statuses) { status in
                    StatusRow(status: status)
                        .contextMenu {
                            Button(role: .destructive) {
                                context.delete(status)
                            } label: { Label("Eyða", systemImage: "trash") }
                        }
                }
                .onDelete { offsets in
                    for i in offsets { context.delete(statuses[i]) }
                }
            }
            .frame(minHeight: 200)
        }
        .padding(.horizontal, 8)
    }
}

private struct StatusRow: View {
    @Bindable var status: CustomStatus

    var body: some View {
        HStack {
            ColorPicker("", selection: Binding(
                get: { Color(hex: status.colorHex) ?? .gray },
                set: { status.colorHex = $0.toHex() ?? "#888888" }
            ))
            .labelsHidden()
            .frame(width: 40)
            TextField("Nafn", text: $status.name)
        }
    }
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xFF) / 255
        let g = Double((v >> 8) & 0xFF) / 255
        let b = Double(v & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }

    func toHex() -> String? {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.gray
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
