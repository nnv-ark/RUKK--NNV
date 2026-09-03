import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case dashboard
    case invoices
    case estimates
    case contacts
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var colorScheme
    @Environment(ImportInbox.self) private var inbox
    @Query(sort: \AppSettings.companyName) private var companies: [AppSettings]
    @AppStorage("activeCompanyID") private var activeCompanyID = ""
    @AppStorage("kulaNormalizedV1") private var didNormalize = false
    @State private var selection: SidebarItem = .dashboard
    @State private var selectedInvoice: Invoice?
    @State private var selectedContact: Contact?
    /// Viðskiptavinur sem var rétt í þessu stofnaður — fær innflutningsvalkost í dálki 2.
    @State private var newContactID: PersistentIdentifier?

    // Innflutningur viðskiptavina (xlsx / CSV / XML) — í ContentView svo ⌘I virki alltaf.
    @State private var showingCustomerImporter = false
    @State private var customerImportRecords: [CustomerRecord] = []
    @State private var customerImportFileName = ""
    @State private var showingCustomerReview = false
    @State private var customerImportError: String?

    private var customerImportTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .xml]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        return types
    }

    /// Gluggamyndin sjálf. Aðskilin frá `body` svo hvorug keðjan verði of löng
    /// fyrir þýðandann (hann gefst upp á að tegundagreina eina risakeðju).
    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            detail
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

    /// Villuskilaboð innflutnings sem `alert` getur bundist.
    private var customerImportErrorBinding: Binding<Bool> {
        Binding(get: { customerImportError != nil },
                set: { if !$0 { customerImportError = nil } })
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
        }
        .onChange(of: activeCompanyID) { _, _ in // Using two throwaway parameters to fix the deprecation warning
            selectedInvoice = nil   // gögn annars fyrirtækis eiga ekki að haldast valin
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
        .fileImporter(isPresented: $showingCustomerImporter,
                      allowedContentTypes: customerImportTypes,
                      allowsMultipleSelection: false) { result in
            handleCustomerImport(result)
        }
        .sheet(isPresented: $showingCustomerReview) {
            if let company = activeCompany {
                CustomerImportView(records: customerImportRecords, company: company, fileName: customerImportFileName)
            }
        }
        .alert("Innflutningur mistókst",
               isPresented: customerImportErrorBinding,
               presenting: customerImportError) { _ in
            Button("Í lagi", role: .cancel) { customerImportError = nil }
        } message: { Text($0) }
    }

    /// Dálkur 1: fyrirtækjaval, flipar og listi valins hluta — allt í einum
    /// samanbrjótanlegum dálki (áður var listinn í sérstökum miðjudálki).
    private var sidebar: some View {
        VStack(spacing: 0) {
            companySwitcher
            sectionPicker
            sidebarList
        }
    }

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
                InvoiceListView(company: company, selection: $selectedInvoice, estimatesOnly: true)
                    .id(company.id)
            case .contacts:
                ContactsView(company: company, selection: $selectedContact) { created in
                    newContactID = created.id
                }
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
            default:
                if let invoice = selectedInvoice {
                    InvoiceDetailView(invoice: invoice) { newInvoice in
                        selectedInvoice = newInvoice
                    }
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
            Image(systemName: "person.2").tag(SidebarItem.contacts)
                .help("Viðskiptavinir")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Opnar skráaval fyrir innflutning viðskiptavina (fer fyrst á Viðskiptavinir-flipann).
    private func beginCustomerImport() {
        selection = .contacts
        showingCustomerImporter = true
    }


    /// Les valda skrá, býr til færslur og opnar yfirferð. Villur birtast í `alert`.
    private func handleCustomerImport(_ result: Result<[URL], Error>) {
        customerImportError = nil
        do {
            guard let url = try result.get().first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            let records = try CustomerImport.records(from: url)
            customerImportRecords = records
            customerImportFileName = url.lastPathComponent
            showingCustomerReview = true
        } catch {
            customerImportError = error.localizedDescription
        }
    }

    /// Eldri gögn án fyrirtæris eru færð á virkt fyrirtæki svo þau hverfi ekki.
    private func migrateOrphans(to company: AppSettings) {
        if let invoices = try? context.fetch(FetchDescriptor<Invoice>(predicate: #Predicate { $0.issuer == nil })) {
            for inv in invoices { inv.issuer = company }
        }
        if let contacts = try? context.fetch(FetchDescriptor<Contact>(predicate: #Predicate { $0.owner == nil })) {
            for c in contacts { c.owner = company }
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
        selectedInvoice = estimate
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
        for (i, line) in payload.lines.enumerated() {
            let item = LineItem(description: line.description,
                                quantity: line.quantity,
                                unitPrice: line.unitPrice,
                                taxRate: invoice.taxRate,
                                order: i)
            item.invoice = invoice
            invoice.lineItems.append(item)
            context.insert(item)
        }
        selection = isEstimate ? .estimates : .invoices
        selectedInvoice = invoice
        inbox.pending = nil
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

#Preview {
    ContentView()
        .environment(ImportInbox())
        .modelContainer(for: [Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self], inMemory: true)
}
