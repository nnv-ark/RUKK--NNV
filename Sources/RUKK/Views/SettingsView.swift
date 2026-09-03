import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import os

private let settingsLog = Logger(subsystem: "is.calmail.kula", category: "settings")

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \AppSettings.companyName) private var companies: [AppSettings]
    @AppStorage("activeCompanyID") private var activeCompanyID = ""
    @State private var selectedID: String = ""

    private var selected: AppSettings? {
        companies.first { $0.id.uuidString == selectedID } ?? companies.first
    }

    var body: some View {
        VStack(spacing: 0) {
            companyBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            if let s = selected {
                SettingsTabs(settings: s)
                    .id(s.id)                       // endurræsir flipa þegar skipt er um fyrirtæki
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 500)
        .task {
            let company = AppSettings.active(in: context, activeID: activeCompanyID)
            if activeCompanyID.isEmpty { activeCompanyID = company.id.uuidString }
            if selectedID.isEmpty { selectedID = company.id.uuidString }
        }
    }

    private var companyBar: some View {
        HStack(spacing: 8) {
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

private struct SettingsTabs: View {
    @Bindable var settings: AppSettings

    var body: some View {
        TabView {
            ProfileTab(settings: settings)
                .tabItem { Label("Snið", systemImage: "person.crop.square") }

            InvoiceTab(settings: settings)
                .tabItem { Label("Reikningur", systemImage: "doc.text") }

            AppearanceTab(settings: settings)
                .tabItem { Label("Útlit", systemImage: "textformat") }

            StatusesTab()
                .tabItem { Label("Stöður", systemImage: "tag") }

            LanguageTab(settings: settings)
                .tabItem { Label("Tungumál", systemImage: "globe") }
        }
        .padding()
    }
}

// MARK: - Profile

private struct ProfileTab: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Merki") {
                LogoPicker(data: $settings.logoData)
                Slider(value: $settings.logoScale, in: 0.5...3.0, step: 0.05) {
                    Text("Stærð")
                } minimumValueLabel: { Text("50%") } maximumValueLabel: { Text("300%") }
                LabeledContent("Skali", value: "\(Int(settings.logoScale * 100))%")
            }
            Section("Auðkenni") {
                TextField("Fullt nafn", text: $settings.fullName)
                TextField("Fyrirtæki", text: $settings.companyName)
                TextField("Kennitala", text: $settings.companyNationalID)
                TextField("VSK-númer", text: $settings.companyVATNumber)
                TextField("Bankareikningur (Reikningsnr.)", text: $settings.bankAccountNumber)
                TextField("Innh.máti (sjálfgefið)", text: $settings.collectionMethod)
            }
            Section("Hafa samband") {
                TextField("Netfang", text: $settings.companyEmail)
                TextField("Sími", text: $settings.companyPhone)
                TextField("Vefsíða", text: $settings.companyWebsite)
                TextField("Heimilisfang", text: $settings.companyAddress, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LogoPicker: View {
    @Binding var data: Data?
    @Environment(\.colorScheme) private var colorScheme

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

            VStack(alignment: .leading, spacing: 6) {
                Button("Velja mynd…", action: choose)
                if data != nil {
                    Button("Fjarlægja", role: .destructive) { data = nil }
                }
                Text("PNG, JPEG eða SVG. Birtist efst á hverjum reikningi.")
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
