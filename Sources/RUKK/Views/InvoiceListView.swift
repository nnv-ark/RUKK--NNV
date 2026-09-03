import SwiftUI
import SwiftData

struct InvoiceListView: View {
    @Environment(\.modelContext) private var context
    @Query private var invoices: [Invoice]
    @Binding var selection: Invoice?

    private let company: AppSettings
    /// Sýnir tilboð (isEstimate) í stað reikninga — sama viðmót, annar gagnahópur.
    private let estimatesOnly: Bool

    init(company: AppSettings, selection: Binding<Invoice?>, estimatesOnly: Bool = false) {
        self.company = company
        self.estimatesOnly = estimatesOnly
        _selection = selection
        let cid = company.id
        _invoices = Query(
            filter: #Predicate<Invoice> { $0.issuer?.id == cid && $0.isEstimate == estimatesOnly },
            sort: [SortDescriptor(\Invoice.createdAt, order: .reverse)]
        )
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(invoices) { invoice in
                InvoiceRow(invoice: invoice)
                    .tag(invoice)
                    .contextMenu {
                        if invoice.isEstimate {
                            Button("Breyta í reikning") { invoice.convertToInvoice() }
                            Divider()
                        }
                        Button("Prenta…") {
                            PDFRenderer.printInvoice(invoice: invoice, settings: invoice.issuer ?? company)
                            invoice.printedAt = .now
                        }
                        Button("Senda í tölvupósti…") {
                            PDFRenderer.emailInvoice(invoice: invoice, settings: invoice.issuer ?? company)
                            invoice.printedAt = .now
                        }
                        if invoice.isOverdue {
                            Button("Senda áminningu…") {
                                PDFRenderer.emailReminder(invoice: invoice, settings: invoice.issuer ?? company)
                            }
                        }
                        Button("Opna í Preview") {
                            PDFRenderer.openInPreview(invoice: invoice, settings: invoice.issuer ?? company)
                        }
                        Button("Síðuuppsetning…") { PDFRenderer.pageSetup() }
                        Divider()
                        Button("Afrita") { duplicate(invoice) }
                        Menu("Setja stöðu") {
                            ForEach(InvoiceStatus.allCases) { st in
                                Button(st.label) { invoice.status = st }
                            }
                        }
                        if invoice.isPrinted {
                            Button("Merkja sem óprentað") { invoice.printedAt = nil }
                        }
                        Divider()
                        Button("Flytja út PDF…") {
                            PDFRenderer.export(invoice: invoice, settings: invoice.issuer ?? company)
                            invoice.printedAt = .now
                        }
                        if !invoice.isEstimate {
                            Button("Flytja út XML (TS-136)…") {
                                UBLInvoiceExporter.export(invoice: invoice, company: invoice.issuer ?? company)
                            }
                        }
                        Divider()
                        Button("Eyða", role: .destructive) { context.delete(invoice) }
                    }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle(estimatesOnly ? "Tilboð" : "Reikningar")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                Button(action: createInvoice) {
                    Label(estimatesOnly ? "Nýtt tilboð" : "Nýr reikningur", systemImage: "plus")
                        .lineLimit(1)
                }
                .fixedSize()
                .help(estimatesOnly ? "Nýtt tilboð" : "Nýr reikningur")

                Spacer()

                if !estimatesOnly {
                    Menu {
                        Button("PDF + XML…") { BatchExporter.exportAll(invoices, company: company, format: .both) }
                        Button("Aðeins PDF…") { BatchExporter.exportAll(invoices, company: company, format: .pdf) }
                        Button("Aðeins XML…") { BatchExporter.exportAll(invoices, company: company, format: .xml) }
                    } label: {
                        Label("Flytja út alla", systemImage: "square.and.arrow.up.on.square")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Flytja út alla reikninga")
                    .disabled(invoices.isEmpty)
                }
            }
            .buttonStyle(.borderless)
            .barHeader()
        }
    }

    private func createInvoice() {
        let invoice = estimatesOnly
            ? Invoice.makeEstimate(in: context, company: company)
            : Invoice.makeNext(in: context, company: company)
        selection = invoice
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { context.delete(invoices[i]) }
    }

    private func duplicate(_ src: Invoice) {
        let s = company
        let copy = Invoice(number: src.isEstimate ? "" : Invoice.formattedNumber(prefix: s.invoiceNumberPrefix, s.nextInvoiceNumber),
                           currencyCode: src.currencyCode,
                           taxRate: src.taxRate)
        copy.issuer = src.issuer ?? s
        copy.recipient = src.recipient
        copy.note = src.note
        copy.templateName = src.templateName
        copy.discountAmount = src.discountAmount
        copy.isTaxInclusive = src.isTaxInclusive
        copy.paymentTermDays = src.paymentTermDays
        if src.isEstimate {
            // Afrit tilboðs: nýtt T-númer og nýr 30 daga gildistími.
            copy.isEstimate = true
            copy.estimateNumber = Invoice.formattedNumber(prefix: s.invoiceNumberPrefix + "T", s.nextEstimateNumber)
            s.nextEstimateNumber += 1
            copy.finalDueDate = Calendar.current.date(byAdding: .day, value: 30, to: copy.issueDate)
        } else if let term = copy.paymentTermDays {
            copy.dueDate = Calendar.current.date(byAdding: .day, value: term, to: copy.issueDate)
        }
        context.insert(copy)
        for item in src.orderedItems {
            let li = LineItem(description: item.itemDescription,
                              quantity: item.quantity,
                              unitPrice: item.unitPrice,
                              taxRate: item.taxRate,
                              order: item.order)
            li.invoice = copy
            copy.lineItems.append(li)
            context.insert(li)
        }
        if !src.isEstimate { s.nextInvoiceNumber += 1 }
        selection = copy
    }
}

private struct InvoiceRow: View {
    let invoice: Invoice

    var body: some View {
        HStack {
            Circle()
                .fill(invoice.isPrinted ? Color.green : Color.clear)
                .frame(width: 8, height: 8)
                .help(invoice.isPrinted ? "Prentaður" : "")
            VStack(alignment: .leading, spacing: 2) {
                Text(invoice.displayNumber)
                    .font(.headline)
                Text(invoice.recipient?.name ?? "Enginn móttakandi")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(invoice.total, currencyCode: invoice.currencyCode))
                    .monospacedDigit()
                StatusMenu(invoice: invoice)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Smellanlegt stöðumerki — velur stöðu reikningsins.
struct StatusMenu: View {
    @Bindable var invoice: Invoice

    var body: some View {
        Menu {
            Picker("Staða", selection: $invoice.status) {
                ForEach(InvoiceStatus.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            StatusBadge(status: invoice.status)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct StatusBadge: View {
    let status: InvoiceStatus

    var body: some View {
        CapsuleTag(status.label, color: color)
    }

    private var color: Color {
        switch status {
        case .draft: .secondary
        case .sent: .blue
        case .paid: .green
        case .overdue: .red
        case .refunded: .orange
        case .cancelled: .gray
        }
    }
}
