import SwiftUI
import SwiftData
import Charts

struct CustomerDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var contact: Contact
    var openInvoice: (Invoice) -> Void = { _ in }

    private var currency: String { contact.owner?.defaultCurrencyCode ?? "ISK" }
    private var invoices: [Invoice] { contact.invoices }
    /// Aðeins lagalegir reikningar — tilboð eru undanskilin sölutölum viðskiptavinar.
    private var billedInvoices: [Invoice] { invoices.filter { !$0.isEstimate } }

    var body: some View {
        Form {
            Section("Mælaborð") {
                kpiGrid
                if !yearly.isEmpty {
                    yearChart
                        .frame(height: 160)
                        .padding(.vertical, 4)
                }
            }

            Section("Reikningar") {
                Button(action: createInvoice) {
                    Label("Nýr reikningur", systemImage: "doc.badge.plus")
                }
                .disabled(contact.owner == nil)

                if invoices.isEmpty {
                    Text("Engir reikningar enn").foregroundStyle(.secondary)
                }
                ForEach(invoices.sorted { $0.createdAt > $1.createdAt }) { inv in
                    Button { openInvoice(inv) } label: {
                        HStack {
                            Text(inv.isEstimate
                                 ? (inv.estimateNumber.isEmpty ? "(tilboð)" : inv.estimateNumber)
                                 : (inv.number.isEmpty ? "(ekkert nr.)" : inv.number))
                            Text(inv.issueDate.formatted(date: .numeric, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.format(inv.total, currencyCode: inv.currencyCode))
                                .monospacedDigit()
                            StatusBadge(status: inv.status)
                            Image(systemName: "chevron.right")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Viðskiptavinur") {
                TextField("Nafn", text: $contact.name)
                TextField("Fyrirtæki", text: $contact.company)
                TextField("Kennitala", text: $contact.nationalID)
                TextField("Tengiliður", text: $contact.contactPerson)
                TextField("Netfang", text: $contact.email)
                TextField("Sími", text: $contact.phone)
                TextField("Heimilisfang", text: $contact.address, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    TextField("Póstnúmer", text: $contact.postalCode)
                        .frame(width: 90)
                    TextField("Staður", text: $contact.city)
                }
                TextField("Land", text: $contact.country)
                Toggle("Senda rafræna reikninga", isOn: $contact.sendElectronicInvoices)
            }

            Section("Athugasemdir") {
                TextField("Sjálfgefin athugasemd á reikningum", text: $contact.defaultInvoiceNote, axis: .vertical)
                    .lineLimit(1...3)
                TextField("Aukaupplýsingar", text: $contact.extraInfo, axis: .vertical)
                    .lineLimit(1...3)
                TextEditor(text: $contact.notes)
                    .frame(minHeight: 90)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(contact.name.isEmpty ? "Viðskiptavinur" : contact.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createInvoice) {
                    Label("Nýr reikningur", systemImage: "doc.badge.plus")
                }
                .disabled(contact.owner == nil)
                .help("\(String(localized: "Nýr reikningur fyrir")) \(contact.name.isEmpty ? String(localized: "þennan viðskiptavin") : contact.name)")
            }
        }
    }

    /// Býr til nýjan reikning fyrir þennan viðskiptavin og opnar hann.
    private func createInvoice() {
        guard let company = contact.owner else { return }
        let invoice = Invoice.makeNext(in: context, company: company)
        invoice.recipient = contact
        openInvoice(invoice)
    }

    // MARK: - KPI

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            kpi("Reikningar", "\(billedInvoices.count)", "doc.text")
            kpi("Heildarupphæð", Money.format(totalAll, currencyCode: currency), "sum")
            kpi("Greitt", Money.format(paidTotal, currencyCode: currency), "checkmark.circle", .green)
            kpi("Útistandandi", Money.format(outstanding, currencyCode: currency), "clock", outstanding > 0 ? .orange : .secondary)
            kpi("Greiðsluhraði", avgPaymentText, "speedometer")
            kpi("Gjaldfallið", "\(overdueCount)", "exclamationmark.triangle", overdueCount > 0 ? .red : .secondary)
        }
        .padding(.vertical, 4)
    }

    private func kpi(_ title: LocalizedStringKey, _ value: String, _ icon: String, _ tint: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3).bold()
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Yearly chart

    private var yearChart: some View {
        Chart(yearly, id: \.year) { item in
            BarMark(
                x: .value(String(localized: "Ár"), String(item.year)),
                y: .value(String(localized: "Upphæð"), item.totalDouble)
            )
            .foregroundStyle(.tint)
            .annotation(position: .top) {
                Text(Money.format(item.total, currencyCode: currency))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(compact(d))
                    }
                }
            }
        }
    }

    // MARK: - Metrics

    private var totalAll: Decimal { billedInvoices.reduce(0) { $0 + $1.total } }

    private var paidTotal: Decimal {
        billedInvoices.filter { $0.status == .paid }.reduce(0) { $0 + $1.total }
    }

    private var outstanding: Decimal {
        billedInvoices.filter { $0.status != .paid && $0.status != .cancelled && $0.status != .refunded }
            .reduce(0) { $0 + $1.total }
    }

    private var overdueCount: Int {
        let now = Date()
        return billedInvoices.filter {
            $0.status != .paid && $0.status != .cancelled && $0.status != .refunded
                && ($0.dueDate.map { $0 < now } ?? false)
        }.count
    }

    private var avgPaymentText: String {
        let days = billedInvoices.compactMap(\.paymentDays)
        guard !days.isEmpty else { return "—" }
        let avg = Double(days.reduce(0, +)) / Double(days.count)
        return "\(Int(avg.rounded())) \(String(localized: "dagar"))"
    }

    private struct YearTotal { let year: Int; let total: Decimal; var totalDouble: Double { (total as NSDecimalNumber).doubleValue } }

    private var yearly: [YearTotal] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: billedInvoices) { cal.component(.year, from: $0.issueDate) }
        return grouped
            .map { YearTotal(year: $0.key, total: $0.value.reduce(0) { $0 + $1.total }) }
            .sorted { $0.year < $1.year }
    }

    private func compact(_ d: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        if d >= 1_000_000 { return "\((d / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M" }
        if d >= 1_000 { return "\(Int(d / 1_000))k" }
        return f.string(from: d as NSNumber) ?? "\(Int(d))"
    }
}
