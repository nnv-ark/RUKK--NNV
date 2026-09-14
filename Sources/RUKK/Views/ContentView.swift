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
    /// Tenging við FELAG — sameiginleg fyrirtækjaskráin (companies.xml).
    @Environment(FelagAgent.self) private var felag
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
    /// Skipulag eins og VSKIL: lóðrétt táknastika lengst til vinstri,
    /// fyrirtækjahaus efst í innihaldinu.
    private var splitView: some View {
        HStack(spacing: 0) {
            sectionStrip
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
            } detail: {
                VStack(spacing: 0) {
                    companySwitcher
                        // Spannar alla breidd dálksins — slík hausrönd og VSKIL
                        // sýnir (merki vinstra megin, skilrönd tvær yfir).
                        .frame(maxWidth: .infinity, alignment: .leading)
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
    }

    /// Lóðrétt táknastika lengst til vinstri — sama mynstur og VSKIL notar.
    /// Aðeins tákn; heitið birtist sem vísbending (help).
    private var sectionStrip: some View {
        VStack(spacing: 4) {
            stripButton(.dashboard, takn: "chart.bar.xaxis", heiti: String(localized: "Mælaborð"))
            stripButton(.invoices, takn: "doc.text", heiti: String(localized: "Reikningar"))
            stripButton(.estimates, takn: "doc.append", heiti: String(localized: "Tilboð"))
            stripButton(.expenses, takn: "creditcard", heiti: String(localized: "Kostnaður"))
            stripButton(.contacts, takn: "person.2", heiti: String(localized: "Viðskiptavinir"))
            Spacer()
        }
        .padding(.top, 14)
        .padding(.horizontal, 8)
        .frame(width: 56)
        .background(.bar)
        .overlay(alignment: .trailing) { Divider() }
    }

    private func stripButton(_ item: SidebarItem, takn: String, heiti: String) -> some View {
        Button { selection = item } label: {
            Image(systemName: takn)
                .font(.system(size: 17))
                .foregroundStyle(selection == item ? Color.primary : Color.secondary)
                .frame(width: 40, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(selection == item ? 0.12 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(heiti)
    }

    var body: some View {
        splitView
        .task {
            // Samstilla fyrirtækjaskrána við FELAG áður en virkt fyrirtæki er valið.
            felag.samræma(context: context)
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // FELAG hefur kannski breytt companies.xml meðan forritið beið.
            felag.endurhlaða()
            felag.samræma(context: context)
        }
        .onChange(of: link?.latestExpense) { _, expense in
            // Kvittun barst beint úr símanum — færa valið á nýju færsluna.
            guard let expense else { return }
            selection = .expenses
            selectedExpense = expense
        }
        .onChange(of: mailWatcher?.latestExpense) { _, expense in
            // Kvittun barst í gegnum póstvaktina — sama hegðun: sýna hana strax.
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

    /// Dálkur 1: listi valins hluta. Fyrirtækjavalið er fært efst í
    /// innihaldsdálkinn og fliparnir í lóðréttu stikuna — eins og í VSKIL.
    private var sidebar: some View {
        sidebarList
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
        // Breiðröðin fyllir dálkinn áður en `.barHeader` leggur flöt og
        // skilrönd undir — annars verður röndin ekki lengri en textinn.
        .frame(maxWidth: .infinity, alignment: .leading)
        .barHeader(horizontal: 12, vertical: 8)
    }
}

#Preview {
    ContentView()
        .environment(ImportInbox())
        .modelContainer(for: [Invoice.self, LineItem.self, Contact.self, AppSettings.self, CustomStatus.self, Expense.self], inMemory: true)
}

// MARK: - VSK-yfirlit fyrir VSKIL

/// Spjald með lista yfir öll VSK-tímabil (nýjustu efst) — hvert tímabil
/// fyrir sig, líka gömlu — með yfirlits-tölum fyrir sölu og innkaup.
/// Valið tímabil er flutt út sem `_vskil-<kt>-<ár>-<tímabil>.json`
/// (VSKIL les það inn í virðisaukaskattsskýrsluna). Sjá `VskSummaryExporter`.
private struct VskExportView: View {
    let company: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// Eitt tveggja mánaða tímabil á tilteknu ári.
    struct TimabilStak: Identifiable, Hashable {
        let ar: Int
        let timabilNr: Int
        var id: String { "\(ar)-\(timabilNr)" }
    }

    @State private var timabilin: [TimabilStak] = []
    @State private var val: TimabilStak?
    @State private var invoices: [Invoice] = []
    @State private var expenses: [Expense] = []
    @State private var synaStodu = false
    @State private var villa: String?

    /// Yfirlit yfir valið tímabil (reiknað þegar val breytist).
    @State private var payload: VskYfirlitPayload?

    var body: some View {
        VStack(spacing: 12) {
            Text("VSK-yfirlit fyrir VSKIL — \(company.displayName)")
                .font(.headline)

            HStack(spacing: 0) {
                // Tímabilin — öll frá fyrsta gögna-ári til nú, nýjustu efst.
                List(timabilin, selection: $val) { t in
                    timabilRow(t)
                        .tag(t)
                }
                .frame(minWidth: 230)

                Divider()

                // Nánarsýn valins tímabils.
                VStack(alignment: .leading, spacing: 10) {
                    if let val, let payload {
                        Text("\(VskSummaryExporter.timabilHeiti(timabilNr: val.timabilNr)) \(String(val.ar))")
                            .font(.title3.weight(.semibold))
                        Text("Tímabil \(VskSummaryExporter.rskNumer(timabilNr: val.timabilNr)) hjá Skattinum · \(payload.dagsFra) – \(payload.dagsTil)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Divider()
                        LabeledContent("Reikningar (sala)", value: "\(payload.sala.count)")
                        LabeledContent("Útskattur 24%", value: kr(payload.samtala.utskattur24))
                        LabeledContent("Útskattur 11%", value: kr(payload.samtala.utskattur11))
                        Divider()
                        LabeledContent("Kostnaður (innkaup)", value: "\(payload.innkaup.count)")
                        LabeledContent("Innskattur 24%", value: kr(payload.samtala.innskattur24))
                        LabeledContent("Innskattur 11%", value: kr(payload.samtala.innskattur11))
                        Divider()
                        let adgreining = payload.samtala.utskattur24 + payload.samtala.utskattur11
                                       - payload.samtala.innskattur24 - payload.samtala.innskattur11
                        LabeledContent("Aðgreining", value: kr(adgreining))
                            .font(.callout.weight(.semibold))
                        Spacer()
                    } else {
                        Text("Veldu tímabil úr listanum.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(14)
                .frame(minWidth: 280)
            }

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
                    .disabled(payload == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .task { hlaupa() }
        .onChange(of: val) { _, _ in reikna() }
    }

    /// Lína í tímabilslistanum: heiti, RSK-númer og stutt samantekt.
    private func timabilRow(_ t: TimabilStak) -> some View {
        let bil = VskSummaryExporter.timabilBil(ar: t.ar, timabilNr: t.timabilNr, kal: .current)
        let fjoldiReikninga = invoices.filter {
            $0.isIssued && !$0.isEstimate && $0.currencyCode == "ISK"
                && $0.issuer?.id == company.id
                && bil.contains($0.bookingDate ?? $0.issueDate)
        }.count
        let fjoldiFaerslna = expenses.filter {
            $0.currencyCode == "ISK" && $0.company?.id == company.id
                && bil.contains($0.date) && $0.amount != 0
        }.count
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(VskSummaryExporter.timabilHeiti(timabilNr: t.timabilNr)) \(String(t.ar))")
                    .font(.callout.weight(.medium))
                let g = VskSummaryExporter.gjalddagi(ar: t.ar, timabilNr: t.timabilNr, kal: .current)
                Text("Gjalddagi: \(gjalddagaTexti(g.dags))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if g.faerdur {
                    Label("Færður vegna helgi", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if fjoldiReikninga + fjoldiFaerslna > 0 {
                Text("\(fjoldiReikninga) r. · \(fjoldiFaerslna) f.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    /// „miðvikudagur, 5. ágúst 2026" — alltaf á íslensku, sama snið og VSKIL.
    private func gjalddagaTexti(_ dags: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "is_IS")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "EEEE, d. MMMM yyyy"
        return f.string(from: dags)
    }

    /// Hleður gögnum og byggir tímabilslistann: frá fyrsta ári með gögn
    /// til núverandi árs. Sjálfgefið val: tímabilið sem í dagurinn fellur í.
    private func hlaupa() {
        invoices = (try? context.fetch(FetchDescriptor<Invoice>())) ?? []
            .filter { $0.issuer?.id == company.id }
        expenses = (try? context.fetch(FetchDescriptor<Expense>())) ?? []
            .filter { $0.company?.id == company.id }

        let kal = Calendar.current
        let nu = Date()
        let arNu = kal.component(.year, from: nu)
        let elsta = ([arNu] + invoices.map { kal.component(.year, from: $0.bookingDate ?? $0.issueDate) }
                               + expenses.map { kal.component(.year, from: $0.date) }).min() ?? arNu
        var list: [TimabilStak] = []
        for a in elsta...arNu {
            for n in 1...6 { list.append(TimabilStak(ar: a, timabilNr: n)) }
        }
        timabilin = list.reversed()
        val = TimabilStak(ar: arNu, timabilNr: (kal.component(.month, from: nu) + 1) / 2)
        reikna()
    }

    /// Reiknar yfirlitið fyrir valið tímabil.
    private func reikna() {
        guard let val else { payload = nil; return }
        payload = VskSummaryExporter.payload(invoices: invoices, expenses: expenses,
                                             company: company, ar: val.ar,
                                             timabilNr: val.timabilNr, kal: .current)
        synaStodu = false
        villa = nil
    }

    private func kr(_ d: Decimal) -> String {
        Money.format(d, currencyCode: "ISK")
    }

    /// Skrifar yfirlit valins tímabils sem `_vskil-<kt>-<ár>-<tímabil>.json`.
    private func flytjaUt() {
        guard let val, let payload else { return }
        villa = nil
        let gogn: Data
        do {
            gogn = try VskSummaryExporter.gogn(payload)
        } catch {
            villa = String(localized: "Ekki tókst að kóða yfirlitið.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "_vskil-\(company.companyNationalID)-\(val.ar)-\(VskSummaryExporter.rskNumer(timabilNr: val.timabilNr)).json"
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
