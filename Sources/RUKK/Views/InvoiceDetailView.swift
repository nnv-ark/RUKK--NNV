import SwiftUI
import SwiftData

struct InvoiceDetailView: View {
    @Bindable var invoice: Invoice
    /// Opnar nýjan reikning (t.d. nýstofnaðan kreditreikning) í aðalvalinu.
    var onOpenInvoice: (Invoice) -> Void = { _ in }
    @Environment(\.modelContext) private var context
    @Query private var companyContacts: [Contact]
    @Query(sort: \AppSettings.companyName) private var companies: [AppSettings]
    /// Nýlegir reikningar útgáfufyrirtækisins — undirstaða „Nota fyrri línu…“.
    @Query private var recentInvoices: [Invoice]
    @AppStorage("activeCompanyID") private var activeCompanyID = ""

    /// Fyrirspurnirnar eru afmarkaðar við fyrirtæki reikningsins strax í gagnalaginu.
    /// Áður sótti sýnin sérhvern viðskiptavin og sérhvern reikning í gagnagrunninum
    /// og síaði í Swift — í hverri einustu umferð.
    init(invoice: Invoice, onOpenInvoice: @escaping (Invoice) -> Void = { _ in }) {
        _invoice = Bindable(wrappedValue: invoice)
        self.onOpenInvoice = onOpenInvoice

        let companyID = invoice.issuer?.id
        _companyContacts = Query(filter: #Predicate<Contact> { $0.owner?.id == companyID },
                                 sort: \Contact.name)

        var recent = FetchDescriptor<Invoice>(
            predicate: #Predicate<Invoice> { $0.issuer?.id == companyID },
            sortBy: [SortDescriptor(\Invoice.createdAt, order: .reverse)])
        // „Nota fyrri línu…“ sýnir í mesta lagi 15 ólíkar lýsingar; það þarf ekki
        // alla reikningssöguna til.
        recent.fetchLimit = 40
        _recentInvoices = Query(recent)
    }

    @State private var isShowingPreview = true
    @State private var previewZoom: PreviewZoom = .fit
    @State private var showingCalendarImport = false
    @State private var showingTymeImport = false
    @State private var showingBlizzImport = false
    /// Skrá sem var sleppt á reikninginn og bíður þess að vera lesin.
    @State private var droppedTymeFile: URL?
    @State private var dropError: String?

    /// Tómt fyrirtæki til vara — býr til EITT eintak fyrir allt forritið. Áður varð
    /// til nýtt `AppSettings`-líkan í hverri teikningu þegar keðjan hitti ekki.
    @MainActor private static let unconfiguredCompany = AppSettings()

    // Pure read: útgáfufyrirtæki reikningsins, annars virkt.
    // Aldrei breytt í context meðan á view-teikningu stendur.
    private var settings: AppSettings {
        invoice.issuer
            ?? companies.first(where: { $0.id.uuidString == activeCompanyID })
            ?? companies.first
            ?? Self.unconfiguredCompany
    }

    private var dueDateBinding: Binding<Date> {
        Binding(get: { invoice.dueDate ?? invoice.issueDate },
                set: { invoice.dueDate = $0 })
    }

    /// Eindagi — sjálfgefið gjalddagi + sjálfgildi fyrirtækis (5 dagar), sérstillanlegt.
    private var finalDueDateBinding: Binding<Date> {
        Binding(get: { invoice.effectiveFinalDueDate },
                set: { invoice.finalDueDate = $0 })
    }

    /// „Gildir til“ á tilboði — sjálfgefið útgáfudagur + 30 dagar, sérstillanlegt.
    private var validUntilBinding: Binding<Date> {
        Binding(get: { invoice.validUntil },
                set: { invoice.finalDueDate = $0 })
    }

    /// Næsta raðnúmer sem yrði úthlutað við útgáfu.
    private var nextNumberPreview: String {
        Invoice.formattedNumber(prefix: settings.invoiceNumberPrefix, settings.nextInvoiceNumber)
    }

    /// Byggð úr staka-orða brotum (ekki bein interpolation í Text) svo hún þýðist rétt —
    /// LocalizedStringKey-interpolation krefst nákvæms sniðs sem er of áhættusamt að handskrifa.
    private var issueFooterText: String {
        if invoice.number.isEmpty {
            return "\(String(localized: "Reikningurinn fær fast raðnúmer")) \(nextNumberPreview) \(String(localized: "og verður merktur „Sent“."))"
        } else {
            return "\(String(localized: "Festir númerið")) \(invoice.number) \(String(localized: "og merkir reikninginn „Sent“."))"
        }
    }

    var body: some View {
        HSplitView {
            form
                .frame(minWidth: 380, idealWidth: 460)

            if isShowingPreview {
                previewPane
                    .frame(minWidth: 340, idealWidth: 520)
            }
        }
        .navigationTitle(invoice.isEstimate
                         ? (invoice.estimateNumber.isEmpty ? "Nýtt tilboð" : "Tilboð \(invoice.estimateNumber)")
                         : (invoice.number.isEmpty ? "Nýr reikningur" : invoice.number))
        .toolbar {
            InvoiceToolbar(invoice: invoice, settings: settings, isShowingPreview: $isShowingPreview)
        }
        .focusedSceneValue(\.printInvoice) {
            PDFRenderer.printInvoice(invoice: invoice, settings: settings)
            invoice.printedAt = .now
        }
        .focusedSceneValue(\.exportPDF) {
            PDFRenderer.export(invoice: invoice, settings: settings)
            invoice.printedAt = .now
        }
        .focusedSceneValue(\.exportXML) {
            // Rafrænir reikningar (UBL / TS-136) eru aðeins fyrir lagalega reikninga.
            if !invoice.isEstimate {
                UBLInvoiceExporter.export(invoice: invoice, company: settings)
            }
        }
        .sheet(isPresented: $showingCalendarImport) {
            CalendarImportView(invoice: invoice)
        }
        .sheet(isPresented: $showingTymeImport) {
            TymeImportView(invoice: invoice, initialFile: droppedTymeFile)
        }
        .sheet(isPresented: $showingBlizzImport) {
            BlizzImportView(invoice: invoice)
        }
    }

    /// Tekur við tímaskrám sem sleppt er á reikninginn: Tyme-JSON opnar valgluggann
    /// með skrána tilbúna, BLIZZ-sending (.rukktime) bætir línunum sínum beint við.
    private func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: DroppedFile.isTimeExport) else { return false }
        if url.pathExtension.lowercased() == "rukktime" {
            guard let payload = InvoiceImport.payload(from: url) else {
                dropError = String(localized: "Skráin inniheldur engar línur sem RUKK skilur.")
                return false
            }
            let lines = payload.unbilledLines
            guard !lines.isEmpty else {
                dropError = String(localized: "Öll vinnan í sendingunni er þegar rukkuð.")
                return false
            }
            invoice.append(lines, in: context)
            return true
        }
        droppedTymeFile = url
        showingTymeImport = true
        return true
    }

    /// Ein rönd af táknum neðst í „Línur“ — bæta við línu, fyrirsögn, fyrri línu,
    /// dagatali, Tyme, BLIZZ. Áður tók hver aðgerð heila breiða röð.
    private var lineTools: some View {
        HStack(spacing: 14) {
            Button { addLine() } label: { Image(systemName: "plus") }
                .help("Bæta við línu")

            Button { addHeading() } label: { Image(systemName: "text.alignleft") }
                .help("Bæta við fyrirsögn — skiptir reikningnum í kafla, telur ekki með í upphæðum")

            if !lineHistory.isEmpty {
                Menu {
                    ForEach(lineHistory, id: \.self) { entry in
                        Button(entry.description) { insertLine(from: entry) }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Nota fyrri línu úr eldri reikningum")
            }

            Divider().frame(height: 16)

            Button { showingCalendarImport = true } label: { Image(systemName: "calendar") }
                .help("Sækja úr dagatali")

            Button { showingTymeImport = true } label: { Image(systemName: "clock") }
                .help("Sækja úr Tyme")

            Button { showingBlizzImport = true } label: { Image(systemName: "snowflake") }
                .help("Sækja úr BLIZZ")

            Spacer()
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.vertical, 2)
    }

    private func addLine() {
        let item = LineItem(taxRate: invoice.taxRate, order: nextLineOrder)
        item.invoice = invoice
        invoice.lineItems.append(item)
        context.insert(item)
    }

    private func addHeading() {
        let heading = LineItem.heading("", order: nextLineOrder)
        heading.invoice = invoice
        invoice.lineItems.append(heading)
        context.insert(heading)
    }

    private var nextLineOrder: Int { (invoice.lineItems.map(\.order).max() ?? -1) + 1 }

    private var form: some View {
        Form {
            Section(invoice.isEstimate ? "Tilboð" : "Reikningur") {
                if invoice.isEstimate {
                    // Tilboð fá T-númer við stofnun — ekki breytilegt, engin læsing.
                    LabeledContent("Númer", value: invoice.estimateNumber)
                    DatePicker("Útgáfudagur", selection: $invoice.issueDate, displayedComponents: .date)
                    DatePicker("Gildir til", selection: validUntilBinding, displayedComponents: .date)
                } else {
                    HStack {
                        TextField("Númer", text: $invoice.number, prompt: Text("úthlutað við útgáfu"))
                            .disabled(invoice.isNumberLocked)
                            .foregroundStyle(invoice.isNumberLocked ? .secondary : .primary)
                        if !invoice.number.isEmpty {
                            Button {
                                invoice.isNumberLocked.toggle()
                            } label: {
                                Image(systemName: invoice.isNumberLocked ? "lock.fill" : "lock.open")
                            }
                            .buttonStyle(.borderless)
                            .help(invoice.isNumberLocked ? "Aflæsa númeri" : "Festa númer")
                        }
                    }
                    DatePicker("Útgáfudagur", selection: $invoice.issueDate, displayedComponents: .date)
                        .disabled(invoice.isNumberLocked)
                    DatePicker("Gjalddagi", selection: dueDateBinding, displayedComponents: .date)
                        .disabled(invoice.isNumberLocked)
                    DatePicker("Eindagi", selection: finalDueDateBinding, displayedComponents: .date)
                        .disabled(invoice.isNumberLocked)
                }
                Picker("Staða", selection: $invoice.status) {
                    ForEach(InvoiceStatus.allCases) { Text($0.label).tag($0) }
                }
                Picker("Reikningssnið", selection: $invoice.templateName) {
                    Text("Íslenskt (reglug. 505/2013)").tag("icelandic")
                    Text("Universal (enska)").tag("universal")
                }
                .disabled(invoice.isNumberLocked)
                if !invoice.isEstimate {
                    if invoice.status == .paid {
                        DatePicker("Greitt þann",
                                   selection: Binding(
                                    get: { invoice.paidAt ?? invoice.issueDate },
                                    set: { invoice.paidAt = $0 }),
                                   displayedComponents: .date)
                    } else {
                        Button("Merkja sem greitt") { invoice.status = .paid }
                    }
                }
            }

            if invoice.isEstimate {
                Section {
                    Button {
                        invoice.convertToInvoice()
                    } label: {
                        Label("Breyta í reikning", systemImage: "arrow.right.doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } footer: {
                    Text("Viðskiptavinur samþykkti? Tilboðið verður að venjulegum reikningadrögum — raðnúmer fæst við útgáfu.")
                }
            } else if !invoice.isIssued {
                Section {
                    Button {
                        invoice.issue()
                    } label: {
                        Label("Gefa út reikning", systemImage: "checkmark.seal.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } footer: {
                    Text(issueFooterText)
                }
            }

            if invoice.isIssued && !invoice.isCreditNote {
                Section {
                    Button {
                        let credit = Invoice.makeCreditNote(for: invoice, in: context)
                        onOpenInvoice(credit)
                    } label: {
                        Label("Búa til kreditreikning", systemImage: "arrow.uturn.backward.square")
                    }
                } footer: {
                    Text("Útgefnum reikningi má ekki breyta (reglug. 505/2013, 15. gr.). Leiðréttu með kreditreikningi — eða aflæstu númerinu hér að ofan til að breyta.")
                }
            }

            Section {
                Picker("Viðskiptavinur", selection: $invoice.recipient) {
                    Text("Velja").tag(Optional<Contact>.none)
                    ForEach(companyContacts) { Text($0.name).tag(Optional($0)) }
                }
                // Viðskiptanúmerið prentast á reikninginn; það á líka að sjást hér.
                // Breyting hér uppfærir kennitölu viðskiptavinarins sjálfs.
                if let recipient = invoice.recipient {
                    TextField("Viðskiptanúmer",
                              text: Binding(get: { recipient.nationalID },
                                            set: { recipient.nationalID = $0 }))
                }
            }
            .disabled(invoice.isNumberLocked)

            Section("Línur") {
                ForEach(Array(invoice.orderedItems.enumerated()), id: \.element.persistentModelID) { index, item in
                    LineItemRow(item: item)
                        // Draga línu upp eða niður; valmyndin er áfram til vara.
                        .draggable(LineItemDrag(index: index)) {
                            Text(item.itemDescription.isEmpty
                                 ? String(localized: "Lína") : item.itemDescription)
                        }
                        .dropDestination(for: LineItemDrag.self) { dragged, _ in
                            guard let from = dragged.first?.index else { return false }
                            return invoice.moveItem(from: from, to: index)
                        }
                        .contextMenu {
                            Button("Afrita") {
                                let next = (invoice.lineItems.map(\.order).max() ?? -1) + 1
                                let copy = LineItem(description: item.itemDescription,
                                                    quantity: item.quantity,
                                                    unitPrice: item.unitPrice,
                                                    taxRate: item.taxRate,
                                                    order: next)
                                copy.invoice = invoice
                                invoice.lineItems.append(copy)
                                context.insert(copy)
                            }
                            Button("Færa upp", systemImage: "arrow.up") { move(item: item, by: -1) }
                            Button("Færa niður", systemImage: "arrow.down") { move(item: item, by: 1) }
                            Divider()
                            Button("Eyða", role: .destructive) { context.delete(item) }
                        }
                }
                .onDelete(perform: deleteItems)

                lineTools
            }
            .disabled(invoice.isNumberLocked)

            Section("Leiðréttingar") {
                HStack {
                    TextField("Afsláttur", value: $invoice.discountAmount, format: .number)
                    Text("%")
                }
                HStack {
                    TextField("Sjálfgefið VSK% fyrir nýjar línur", value: $invoice.taxRate, format: .number)
                    Text("%")
                }
                TextField("Innh.máti", text: $invoice.collectionMethod)
                TextField("Mynt", text: $invoice.currencyCode)
            }
            .disabled(invoice.isNumberLocked)

            Section("Athugasemd") {
                TextEditor(text: $invoice.note).frame(minHeight: 80)
            }
            .disabled(invoice.isNumberLocked)

            Section("Samtölur") {
                LabeledContent("Undirsamtals", value: Money.format(invoice.subtotal, currencyCode: invoice.currencyCode))
                LabeledContent("Afsláttur", value: Money.format(invoice.discountValue, currencyCode: invoice.currencyCode))
                LabeledContent("VSK", value: Money.format(invoice.taxValue, currencyCode: invoice.currencyCode))
                LabeledContent("Samtals", value: Money.format(invoice.total, currencyCode: invoice.currencyCode))
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) }
        .alert("Innflutningur mistókst",
               isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } }),
               presenting: dropError) { _ in
            Button("Í lagi", role: .cancel) { dropError = nil }
        } message: { Text($0) }
    }

    /// Stækkun forskoðunar. „Passa" skalar síðuna eftir breidd dálksins svo hún
    /// sjáist alltaf í heild — fast pappírsmál klipptist áður af í þröngum dálki.
    private enum PreviewZoom: Hashable, CaseIterable, Identifiable {
        case fit, actual, large
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .fit:    "Passa"
            case .actual: "100%"
            case .large:  "150%"
            }
        }
        /// Fast hlutfall, eða `nil` þegar skala á eftir breidd.
        var factor: CGFloat? {
            switch self {
            case .fit:    nil
            case .actual: 1
            case .large:  1.5
            }
        }
    }

    private var previewPane: some View {
        let page = InvoiceRenderer.pageSize(settings.paperSize)
        let inset: CGFloat = 16

        return GeometryReader { geo in
            // Passa: fyllir breidd dálksins (en stækkar ekki úr hófi fram).
            let fitted = min(max(geo.size.width - inset * 2, 1) / page.width, 1.5)
            let scale = previewZoom.factor ?? fitted

            ScrollView(previewZoom == .fit ? .vertical : [.horizontal, .vertical]) {
                InvoiceRenderer.view(for: invoice, settings: settings)
                    .frame(width: page.width, height: page.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    // Skölun ein og sér breytir ekki plássinu sem sýnin tekur —
                    // ytri ramminn segir uppsetningunni raunstærð síðunnar.
                    .frame(width: page.width * scale, height: page.height * scale,
                           alignment: .topLeading)
                    .border(Color(white: 0.85))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    .padding(inset)
                    .frame(maxWidth: previewZoom == .fit ? .infinity : nil)   // miðjuð
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            Picker("Stækkun", selection: $previewZoom) {
                ForEach(PreviewZoom.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .padding(10)
        }
    }

    private func deleteItems(at offsets: IndexSet) {
        let items = invoice.orderedItems
        for i in offsets { context.delete(items[i]) }
    }

    /// Ein eldri lína úr reikningssögu fyrirtækisins — fyrir „Nota fyrri línu…“.
    private struct HistoricLine: Hashable {
        let description: String
        let unitPrice: Decimal
        let taxRate: Decimal
    }

    /// Nýjustu ólíkar línulýsingar fyrirtækisins (nýjustu fyrst, hámark 15).
    private var lineHistory: [HistoricLine] {
        var seen = Set<String>()
        var result: [HistoricLine] = []
        for inv in recentInvoices where inv !== invoice {
            for item in inv.orderedItems {
                let d = item.itemDescription.trimmingCharacters(in: .whitespaces)
                guard !d.isEmpty, seen.insert(d).inserted else { continue }
                result.append(HistoricLine(description: d, unitPrice: item.unitPrice, taxRate: item.taxRate))
                if result.count == 15 { return result }
            }
        }
        return result
    }

    private func insertLine(from entry: HistoricLine) {
        let item = LineItem(description: entry.description, quantity: 1,
                            unitPrice: entry.unitPrice, taxRate: entry.taxRate,
                            order: nextLineOrder)
        item.invoice = invoice
        invoice.lineItems.append(item)
        context.insert(item)
    }

    private func move(item: LineItem, by delta: Int) {
        guard let idx = invoice.orderedItems.firstIndex(of: item) else { return }
        invoice.moveItem(from: idx, to: idx + delta)
    }
}

private struct LineItemRow: View {
    @Bindable var item: LineItem

    var body: some View {
        if item.isHeading { headingRow } else { amountRow }
    }

    /// Kaflaskil: aðeins heitið, engar tölur.
    private var headingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.alignleft")
                .foregroundStyle(.secondary)
                .help("Fyrirsögn — telur ekki með í upphæðum")
            TextField("Fyrirsögn", text: $item.itemDescription)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.headline)
        }
    }

    private var amountRow: some View {
        HStack(spacing: 8) {
            TextField("Lýsing", text: $item.itemDescription)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
            TextField("Magn", value: $item.quantity, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            TextField("Verð", value: $item.unitPrice, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
            HStack(spacing: 2) {
                TextField("VSK", value: $item.taxRate, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                Text("%").foregroundStyle(.secondary)
            }
            Text(Money.format(item.subtotalIncTax, currencyCode: item.invoice?.currencyCode ?? "ISK"))
                .monospacedDigit()
                .frame(width: 110, alignment: .trailing)
        }
    }
}

/// Tækjastika reikningsspjaldsins. Eigin gerð svo `InvoiceDetailView.body` haldist
/// læsileg — og innan þess sem þýðandinn ræður við að tegundagreina.
private struct InvoiceToolbar: ToolbarContent {
    @Bindable var invoice: Invoice
    let settings: AppSettings
    @Binding var isShowingPreview: Bool

    /// Útgefinn reikningur (eða tilboð) má prenta, senda og flytja út — drög ekki.
    private var isExportable: Bool { invoice.isEstimate || !invoice.number.isEmpty }

    private var notIssuedHelp: String {
        String(localized: "Gefðu reikninginn út áður en hann er fluttur út")
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $isShowingPreview) {
                Label("Forskoðun", systemImage: "eye")
            }

            if invoice.isOverdue {
                Button {
                    PDFRenderer.emailReminder(invoice: invoice, settings: settings)
                } label: {
                    Label("Senda áminningu", systemImage: "bell")
                }
                .help("Semja áminningu í Mail vegna gjaldfallins reiknings")
            }

            Button {
                PDFRenderer.printInvoice(invoice: invoice, settings: settings)
                invoice.printedAt = .now
            } label: {
                Label("Prenta…", systemImage: "printer")
            }
            .disabled(!isExportable)
            .help(isExportable ? "" : String(localized: "Gefðu reikninginn út áður en hann er prentaður"))

            Button {
                PDFRenderer.emailInvoice(invoice: invoice, settings: settings)
                invoice.printedAt = .now
            } label: {
                Label("Senda í tölvupósti", systemImage: "envelope")
            }
            .disabled(!isExportable)
            .help(isExportable
                  ? String(localized: "Senda í tölvupósti með PDF")
                  : String(localized: "Gefðu reikninginn út áður en hann er sendur"))

            Menu {
                Button("Opna í Preview") {
                    PDFRenderer.openInPreview(invoice: invoice, settings: settings)
                }
                Button("Flytja út PDF…") {
                    PDFRenderer.export(invoice: invoice, settings: settings)
                    invoice.printedAt = .now
                }
                if !invoice.isEstimate {
                    Button("Rafrænn reikningur (UBL / TS-136)…") {
                        UBLInvoiceExporter.export(invoice: invoice, company: settings)
                    }
                }
                Divider()
                Button("Síðuuppsetning…") {
                    PDFRenderer.pageSetup()
                }
                if invoice.isPrinted {
                    Divider()
                    Button("Merkja sem óprentað") { invoice.printedAt = nil }
                }
            } label: {
                Label("Flytja út", systemImage: "square.and.arrow.up")
            }
            .disabled(!isExportable)
            .help(isExportable ? "" : notIssuedHelp)
        }
    }
}
