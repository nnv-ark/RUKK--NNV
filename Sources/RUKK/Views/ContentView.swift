import SwiftUI
import SwiftData

enum SidebarItem: Hashable {
    case dashboard
    case invoices
    case estimates
    case expenses
    case contacts
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ImportInbox.self) private var inbox
    /// Bein tenging við Bill To Book — nil ef þjónustan er ekki í umhverfinu (forsýn).
    @Environment(RukkLinkService.self) private var link: RukkLinkService?
    @Environment(ExpenseMailWatcher.self) private var mailWatcher: ExpenseMailWatcher?
    @Query(sort: \AppSettings.companyName) private var companies: [AppSettings]
    @AppStorage("activeCompanyID") private var activeCompanyID = ""
    @AppStorage("kulaNormalizedV1") private var didNormalize = false
    @State private var selection: SidebarItem = .dashboard
    /// Valinn reikningur í Reikninga-flipanum.
    @State private var selectedInvoice: Invoice?
    /// Valið tilboð í Tilboða-flipanum — eigið val svo flipaskipti sýni aldrei
    /// reikning í tilboðsflipanum (og öfugt).
    @State private var selectedEstimate: Invoice?
    /// Valin kostnaðarfærsla í Kostnaðar-flipanum.
    @State private var selectedExpense: Expense?
    @State private var selectedContact: Contact?
    /// Viðskiptavinur sem var rétt í þessu stofnaður — fær innflutningsvalkost í dálki 2.
    @State private var newContactID: PersistentIdentifier?
    /// Skilaboð þegar sending sem sleppt var hafði ekkert nýtt að bera.
    @State private var dropMessage: String?

    /// Innflutningur viðskiptavina (xlsx / CSV / XML) — hér svo ⌘I virki óháð völdum
    /// flipa. Ferlið sjálft býr í `CustomerImportFlow`.
    @State private var customerImport = CustomerImportFlow()

    /// VSK-yfirlit fyrir VSKIL: tímabil valið í þessu spjaldi, útflutningur sjálfur í VskExportView.
    @State private var synaVskExport = false

    /// Gluggamyndin sjálf. Aðskilin frá `body` svo hvorug keðjan verði of löng
    /// fyrir þýðandann (hann gefst upp á að tegundagreina eina risakeðju).
    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            detail
                // Verkþáttur dreginn úr BLIZZ: bætist á opinn reikning, annars
                // verða til ný drög. Gildir um allan dálkinn — líka auðan.
                .dropDestination(for: URL.self) { urls, _ in handleTimeDrop(urls) }
        }
        .toolbar {
            // Ósýnilegt atriði sem heldur tækjastikunni í fullri hæð líka þar sem engir
            // hnappar eiga við (t.d. mælaborðið) — annars fellur hún saman í mjóa rönd
            // og litastiginn verður helmingi grennri en í hinum gluggunum.
            ToolbarItem(placement: .navigation) {
                Color.clear.frame(width: 1, height: 28)
            }
        }
        .toolbarBackground(Self.titlebarGradient, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }

    var body: some View {
        splitView
        .task {
            // Tryggja að a.m.k. eitt fyrirtæki sé til og að virkt fyrirtæki sé valið.
            let company = AppSettings.active(in: context, activeID: activeCompanyID)
            if activeCompanyID.isEmpty { activeCompanyID = company.id.uuidString }
            migrateOrphans(to: company)
            if !didNormalize {
                normalizeData()
                didNormalize = true
            }
            // Ræsa móttökur kostnaðarkvittana: beina tenginguna og póstvaktina.
            link?.start()
            mailWatcher?.startPolling(context: context) { [context] in
                // Lesið ferskt í hvert skipti svo fyrirtækjaskipti gildi líka.
                AppSettings.active(in: context,
                                   activeID: UserDefaults.standard.string(forKey: "activeCompanyID") ?? "")
            }
        }
        .onChange(of: link?.latestExpense) { _, expense in
            // Kvittun barst beint úr símanum — færa valið á nýju færsluna.
            guard let expense else { return }
            selection = .expenses
            selectedExpense = expense
        }
        .onChange(of: activeCompanyID) { _, _ in // Using two throwaway parameters to fix the deprecation warning
            selectedInvoice = nil   // gögn annars fyrirtækis eiga ekki að haldast valin
            selectedEstimate = nil
            selectedExpense = nil
            selectedContact = nil
            newContactID = nil
        }
        .onChange(of: selectedContact) { _, contact in
            // Boðið hverfur um leið og valið færist á annan viðskiptavin.
            if contact?.id != newContactID { newContactID = nil }
        }
        .onChange(of: inbox.pending) { _, payload in
            if let payload { importInvoice(payload) }
        }
        .task {
            // Reikningur sem barst um rukk:// áður en viðmótið var tilbúið.
            if let payload = inbox.pending { importInvoice(payload) }
        }
        .focusedSceneValue(\.newInvoice, createInvoice)
        .focusedSceneValue(\.newEstimate, createEstimate)
        .focusedSceneValue(\.importCustomers, beginCustomerImport)
        .focusedSceneValue(\.exportVSKSummary) { synaVskExport = true }
        .sheet(isPresented: $synaVskExport) {
            if let company = activeCompany {
                VskExportView(company: company)
            }
        }
        .customerImport(customerImport, company: activeCompany)
    }

    /// Dálkur 1: fyrirtækjaval, flipar og listi valins hluta — allt í einum
    /// samanbrjótanlegum dálki (áður var listinn í sérstökum miðjudálki).
    private var sidebar: some View {
        VStack(spacing: 0) {
            companySwitcher
            sectionPicker
            sidebarList
        }
        // Verkþáttur dreginn beint úr BLIZZ verður að nýjum reikningsdrögum.
        .dropDestination(for: URL.self) { urls, _ in handleSidebarDrop(urls) }
        .alert("Ekkert til að flytja inn",
               isPresented: Binding(get: { dropMessage != nil }, set: { if !$0 { dropMessage = nil } }),
               presenting: dropMessage) { _ in
            Button("Í lagi", role: .cancel) { dropMessage = nil }
        } message: { Text($0) }
    }

    /// Tekur við tímasendingu sem sleppt er á RUKK — verkþætti dregnum úr BLIZZ eða
    /// `.rukktime` skrá. Er reikningur opinn bætast línurnar á hann; annars verða til
    /// ný drög. Rukkuð vinna fylgir aldrei með.
    private func handleTimeDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: DroppedFile.isTimeExport),
              let payload = InvoiceImport.payload(from: url) else { return false }
        let lines = payload.unbilledLines
        guard !lines.isEmpty else {
            dropMessage = String(localized: "Öll vinnan í sendingunni er þegar rukkuð.")
            return false
        }
        if let open = openDocument, selection == .invoices || selection == .estimates {
            open.append(lines, in: context)
        } else {
            importInvoice(payload)
        }
        return true
    }

    private func handleSidebarDrop(_ urls: [URL]) -> Bool { handleTimeDrop(urls) }

    /// Listi valins hluta — eigin bygging svo þýðandinn ráði við tjáninguna.
    @ViewBuilder
    private var sidebarList: some View {
        if let company = activeCompany {
            switch selection {
            case .dashboard:
                // Mælaborðið á allan hægri dálkinn — dálkur 1 er auður á meðan.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .invoices:
                InvoiceListView(company: company, selection: $selectedInvoice)
                    .id(company.id)               // ný fyrirspurn þegar skipt er um fyrirtæki
            case .estimates:
                InvoiceListView(company: company, selection: $selectedEstimate, estimatesOnly: true)
                    .id(company.id)
            case .expenses:
                ExpenseListView(company: company, selection: $selectedExpense)
                    .id(company.id)
            case .contacts:
                ContactsView(company: company,
                             selection: $selectedContact,
                             onCreate: { newContactID = $0.id },
                             onDropFile: { customerImport.open($0) })
                    .id(company.id)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Innflutningur býðst aðeins þeim viðskiptavini sem var rétt í þessu stofnaður.
    private func importOffer(for contact: Contact) -> (() -> Void)? {
        guard contact.id == newContactID else { return nil }
        return beginCustomerImport
    }

    /// Dálkur 2: innihald valins hluta.
    @ViewBuilder
    private var detail: some View {
            switch selection {
            case .dashboard:
                if let company = activeCompany {
                    DashboardView(company: company) { invoice in
                        selectedInvoice = invoice
                        selection = .invoices
                    }
                    .id(company.id)
                } else {
                    ProgressView()
                }
            case .contacts:
                if let contact = selectedContact {
                    CustomerDetailView(
                        contact: contact,
                        openInvoice: { invoice in
                            selectedInvoice = invoice
                            selection = .invoices
                        },
                        onImport: importOffer(for: contact))
                } else {
                    ContentUnavailableView("Enginn viðskiptavinur valinn", systemImage: "person.2",
                                           description: Text("Veldu eða búðu til viðskiptavin."))
                }
            case .expenses:
                if let expense = selectedExpense {
                    ExpenseDetailView(expense: expense)
                } else {
                    ContentUnavailableView("Enginn kostnaður valinn", systemImage: "creditcard",
                                           description: Text("Veldu eða búðu til kostnaðarfærslu."))
                }
            default:
                if let document = openDocument {
                    InvoiceDetailView(invoice: document) { newInvoice in
                        // Kreditreikningur — og tilboð sem varð að reikningi — eiga
                        // heima í Reikninga-flipanum; færum valið þangað.
                        if selectedEstimate == newInvoice { selectedEstimate = nil }
                        selectedInvoice = newInvoice
                        selection = .invoices
                    }
                } else if selection == .estimates {
                    ContentUnavailableView("Ekkert tilboð valið", systemImage: "doc.append",
                                           description: Text("Veldu eða búðu til tilboð."))
                } else {
                    ContentUnavailableView("Ekkert valið", systemImage: "doc.text",
                                           description: Text("Veldu eða búðu til reikning."))
                }
            }
    }

    /// Flipar efst í dálki 1 — í stað gömlu hliðarstikunnar.
    private var sectionPicker: some View {
        Picker("Hluti", selection: $selection) {
            Image(systemName: "chart.bar.xaxis").tag(SidebarItem.dashboard)
                .help("Mælaborð")
            Image(systemName: "doc.text").tag(SidebarItem.invoices)
                .help("Reikningar")
            Image(systemName: "doc.append").tag(SidebarItem.estimates)
                .help("Tilboð")
            Image(systemName: "creditcard").tag(SidebarItem.expenses)
                .help("Kostnaður")
            Image(systemName: "person.2").tag(SidebarItem.contacts)
                .help("Viðskiptavinir")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .barHeader(horizontal: 10, vertical: 6)
    }

    /// Opnar skráaval fyrir innflutning viðskiptavina (fer fyrst á Viðskiptavinir-flipann).
    private func beginCustomerImport() {
        selection = .contacts
        customerImport.begin()
    }


    /// Eldri gögn án fyrirtæris eru færð á virkt fyrirtæki svo þau hverfi ekki.
    private func migrateOrphans(to company: AppSettings) {
        if let invoices = try? context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.issuer == nil })) {
            for inv in invoices { inv.issuer = company }
        }
        if let contacts = try? context.fetch(FetchDescriptor<Contact>(predicate: #Predicate { $0.owner == nil })) {
            for c in contacts { c.owner = company }
        }
        if let expenses = try? context.fetch(FetchDescriptor<Expense>(predicate: #Predicate { $0.company == nil })) {
            for e in expenses { e.company = company }
        }
    }

    /// Einskiptis-leiðrétting eldri gagna:
    /// 1) viðtakandi reiknings á alltaf að tilheyra útgáfufyrirtækinu (annars vantar hann í listann),
    /// 2) hvert fyrirtæki er endurnúmerað sjálfstætt 001, 002, … eftir stofndegi.
    private func normalizeData() {
        let allInvoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []

        // 1) Tryggja að viðtakandi tilheyri sama fyrirtæki og reikningurinn.
        for inv in allInvoices {
            guard let issuer = inv.issuer, let rec = inv.recipient else { continue }
            if rec.owner?.id != issuer.id {
                let issuerID = issuer.id
                let owned = (try? context.fetch(FetchDescriptor<Contact>(
                    predicate: #Predicate { $0.owner?.id == issuerID }))) ?? []
                if let match = owned.first(where: { $0.name == rec.name && $0.nationalID == rec.nationalID }) {
                    inv.recipient = match
                } else {
                    let copy = Contact(name: rec.name, company: rec.company, nationalID: rec.nationalID,
                                       email: rec.email, phone: rec.phone, address: rec.address)
                    copy.owner = issuer
                    context.insert(copy)
                    inv.recipient = copy
                }
            }
        }

        // 2) Endurnúmera hvert fyrirtæki sjálfstætt (tilboð eru undanskilin —
        //    þau eiga ekki í gatalausri reikningsröðinni).
        for company in AppSettings.all(in: context) {
            let cid = company.id
            let invs = (try? context.fetch(FetchDescriptor<Invoice>(
                predicate: #Predicate { $0.issuer?.id == cid && !$0.isEstimate },
                sortBy: [SortDescriptor(\.createdAt)]))) ?? []
            for (i, inv) in invs.enumerated() {
                inv.number = Invoice.formattedNumber(prefix: company.invoiceNumberPrefix, i + 1)
            }
            company.nextInvoiceNumber = invs.count + 1
        }
    }

    private func createInvoice() {
        let company = AppSettings.active(in: context, activeID: activeCompanyID)
        let invoice = Invoice.makeNext(in: context, company: company)
        selection = .invoices
        selectedInvoice = invoice
    }

    /// Býr til nýtt tilboð fyrir virkt fyrirtæki og opnar það í Tilboða-flipanum.
    private func createEstimate() {
        let company = AppSettings.active(in: context, activeID: activeCompanyID)
        let estimate = Invoice.makeEstimate(in: context, company: company)
        selection = .estimates
        selectedEstimate = estimate
    }

    /// Býr til drög-reikning — eða tilboð ef sendingin biður um það (`estimate: true`) —
    /// úr gögnum sem bárust utanfrá (`rukk://` slóð eða `.rukktime` skrá úr BLIZZ) og opnar þau.
    private func importInvoice(_ payload: InvoiceImportPayload) {
        let company = AppSettings.active(in: context, activeID: activeCompanyID)
        let isEstimate = payload.estimate == true
        let invoice = isEstimate
            ? Invoice.makeEstimate(in: context, company: company)
            : Invoice.makeNext(in: context, company: company)
        if let customer = payload.customer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customer.isEmpty {
            invoice.note = "Verkefni: \(customer)"
        }
        invoice.append(payload.unbilledLines, in: context)
        selection = isEstimate ? .estimates : .invoices
        if isEstimate { selectedEstimate = invoice } else { selectedInvoice = invoice }
        inbox.pending = nil
    }

    /// Skjalið sem dálkur 2 sýnir: tilboð í Tilboða-flipanum, annars reikningur.
    private var openDocument: Invoice? {
        selection == .estimates ? selectedEstimate : selectedInvoice
    }

    private var activeCompany: AppSettings? {
        companies.first { $0.id.uuidString == activeCompanyID } ?? companies.first
    }

    /// Litastigi gluggarandarinnar: dauft rautt → skært rautt → dauft rautt.
    /// Tónarnir eru teknir beint úr RUKK-merkinu (dýpsti og bjartasti rauði punktur þess).
    private static let titlebarGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: "#7A1600") ?? .red,    location: 0.0),
            .init(color: Color(hex: "#FF5400") ?? .orange, location: 0.5),
            .init(color: Color(hex: "#7A1600") ?? .red,    location: 1.0),
        ],
        startPoint: .leading, endPoint: .trailing)

    /// Merki fyrirtækja eru nær alltaf dökk á gagnsæjum grunni. Í dökku útliti fá þau
    /// ljósan flöt undir sig svo þau hverfi ekki ofan í bakgrunninn.
    private var logoBackdrop: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : .clear
    }

    /// Native fyrirtækjaval efst í hliðarstiku — popup með haki á virku fyrirtæki.
    /// Lógóið er FYRIR UTAN Menu-ið; macOS Menu-merkimiði virðir ekki stærð á mynd.
    private var companySwitcher: some View {
        HStack(spacing: 10) {
            if let data = activeCompany?.logoData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                    .padding(2)
                    .background(logoBackdrop, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: "building.2.crop.circle")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
            }
            Menu {
                Picker("Fyrirtæki", selection: $activeCompanyID) {
                    ForEach(companies) { c in
                        Text(c.displayName).tag(c.id.uuidString)
                    }
                }
                .pickerStyle(.inline)          // gefur haka á virku fyrirtæki
            } label: {
                HStack(spacing: 6) {
                    Text(activeCompany?.displayName ?? "Fyrirtæki")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
        }
        .barHeader(horizontal: 12, vertical: 8)
    }
}

#Preview {
    ContentView()
        .environment(ImportInbox())
        .modelContainer(for: [Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self, Expense.self], inMemory: true)
}

// MARK: - VSK-yfirlit fyrir VSKIL

/// Spjald sem lætur notanda velja ár og tveggja mánaða tímabil og flytur út
/// VSK-yfirlit (JSON) sem VSKIL les inn í virðisaukaskattsskýrsluna.
/// Upphæðir koma úr útgefnum reikningum (bókunardegi rænt) og kostnaði —
/// sjá `VskSummaryExporter`.
private struct VskExportView: View {
    let company: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var ar: Int
    @State private var timabilNr: Int
    @State private var synaStodu = false
    @State private var villa: String?

    /// Sjálfgefið val: tímabilið sem í dagurinn fellur í.
    init(company: AppSettings) {
        self.company = company
        let kal = Calendar.current
        let nu = Date()
        _ar = State(initialValue: kal.component(.year, from: nu))
        _timabilNr = State(initialValue: (kal.component(.month, from: nu) + 1) / 2)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("VSK-yfirlit fyrir VSKIL")
                .font(.headline)
            Text("\(company.displayName) — \(VskSummaryExporter.timabilHeiti(timabilNr: timabilNr)) \(ar) (tímabil \(VskSummaryExporter.rskNumer(timabilNr: timabilNr)))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Form {
                Picker("Ár", selection: $ar) {
                    ForEach((ar - 3)...(ar + 1), id: \.self) { a in
                        Text(String(a)).tag(a)
                    }
                }
                Picker("Tímabil", selection: $timabilNr) {
                    ForEach(1...6, id: \.self) { n in
                        Text("\(VskSummaryExporter.timabilHeiti(timabilNr: n)) — \(VskSummaryExporter.rskNumer(timabilNr: n))").tag(n)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: 320)

            if let villa {
                Label(villa, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
            }
            if synaStodu {
                Label("VSK-yfirlit vistað — opnaðu það í VSKIL („Hlaupa úr RUKK…“).",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            }

            HStack {
                Button("Hætta") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Flytja út…") { flytjaUt() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Reiknar yfirlit fyrir valið tímabil og býður upp á að vista sem
    /// `_vskil-<kennitala>-<ár>-<tímabil>.json`.
    private func flytjaUt() {
        villa = nil
        let invoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
        let expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
        let payload = VskSummaryExporter.payload(invoices: invoices, expenses: expenses,
                                                 company: company,
                                                 ar: ar, timabilNr: timabilNr,
                                                 kal: .current)
        let gogn: Data
        do {
            gogn = try VskSummaryExporter.gogn(payload)
        } catch {
            villa = String(localized: "Ekki tókst að kóða yfirlitið.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "_vskil-\(company.companyNationalID)-\(ar)-\(VskSummaryExporter.rskNumer(timabilNr: timabilNr)).json"
        panel.message = String(localized: "Veldu hvar VSK-yfirlitið skal vera vistað")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try gogn.write(to: url, options: .atomic)
            synaStodu = true
        } catch {
            villa = String(localized: "Ekki tókst að vista skrána.")
        }
    }
}
