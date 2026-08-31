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
    @Environment(ImportInbox.self) private var inbox
    @Query(sort: \AppSettings.companyName) private var companies: [AppSettings]
    @AppStorage("activeCompanyID") private var activeCompanyID = ""
    @AppStorage("kulaNormalizedV1") private var didNormalize = false
    @State private var selection: SidebarItem? = .dashboard
    @State private var selectedInvoice: Invoice?
    @State private var selectedContact: Contact?

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

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Mælaborð", systemImage: "chart.bar.xaxis")
                    .tag(SidebarItem.dashboard)
                Section("Bókasafn") {
                    Label("Reikningar", systemImage: "doc.text")
                        .tag(SidebarItem.invoices)
                    Label("Tilboð", systemImage: "doc.append")
                        .tag(SidebarItem.estimates)
                    Label("Viðskiptavinir", systemImage: "person.2")
                        .tag(SidebarItem.contacts)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 220)
            // Dálkur 1 er aldrei samanbrjótanlegur: fjarlægjum hnappinn og föst lágmarksbreidd.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    brandHeader
                    companySwitcher
                }
            }
        } content: {
            if let company = activeCompany {
                switch selection {
                case .dashboard:
                    dashboardBranding(company)
                case .invoices, .none:
                    InvoiceListView(company: company, selection: $selectedInvoice)
                        .id(company.id)               // ný fyrirspurn þegar skipt er um fyrirtæki
                case .estimates:
                    InvoiceListView(company: company, selection: $selectedInvoice, estimatesOnly: true)
                        .id(company.id)
                case .contacts:
                    ContactsView(company: company, selection: $selectedContact, onImport: beginCustomerImport)
                        .id(company.id)
                }
            } else {
                ProgressView()
            }
        } detail: {
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
                    CustomerDetailView(contact: contact) { invoice in
                        selectedInvoice = invoice
                        selection = .invoices
                    }
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
               isPresented: Binding(get: { customerImportError != nil },
                                    set: { if !$0 { customerImportError = nil } }),
               presenting: customerImportError) { _ in
            Button("Í lagi", role: .cancel) { customerImportError = nil }
        } message: { Text($0) }
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

    /// Stórt fyrirtæktislógó í dálki 2 þegar mælaborð er valið
    /// (nafn fyrirtækis til vara ef ekkert lógó er sett).
    @ViewBuilder
    private func dashboardBranding(_ company: AppSettings) -> some View {
        VStack(spacing: 16) {
            Spacer()
            if let data = company.logoData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    // Aldrei stærra en lógóið á opnunarskjánum (96 px).
                    .frame(maxWidth: 96, maxHeight: 96)
                    .accessibilityLabel(Text(company.displayName))
            } else {
                Text(company.displayName.isEmpty ? "FYRIRTÆKI" : company.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// App-vörumerki efst í hliðarstiku — birtist aðeins einu sinni.
    private var brandHeader: some View {
        HStack(spacing: 8) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .clipShape(Circle())
            Text("RUKK")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    /// Native fyrirtækjaval efst í hliðarstiku — popup með haki á virku fyrirtæki.
    /// Lógóið er FYRIR UTAN Menu-ið; macOS Menu-merkimiði virðir ekki stærð á mynd.
    private var companySwitcher: some View {
        HStack(spacing: 10) {
            if let data = activeCompany?.logoData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(width: 30, height: 30)
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
