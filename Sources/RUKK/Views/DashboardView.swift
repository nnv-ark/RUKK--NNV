import SwiftUI
import SwiftData
import Charts

struct DashboardView: View {
    @Query private var invoices: [Invoice]
    var openInvoice: (Invoice) -> Void = { _ in }

    private let company: AppSettings

    init(company: AppSettings, openInvoice: @escaping (Invoice) -> Void = { _ in }) {
        self.company = company
        self.openInvoice = openInvoice
        let cid = company.id
        _invoices = Query(
            filter: #Predicate<Invoice> { $0.issuer?.id == cid },
            sort: [SortDescriptor(\Invoice.createdAt, order: .reverse)]
        )
    }

    private var currency: String { company.defaultCurrencyCode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Síðustu 12 mánuðir")
                    .font(.subheadline).foregroundStyle(.secondary)

                kpiGrid

                if !monthly.isEmpty {
                    card("Sala eftir mánuðum") {
                        salesChart.frame(height: 180)
                    }
                }

                card("Ógreiddir reikningar") {
                    unpaidList
                }
            }
            .padding(20)
        }
        .navigationTitle("Mælaborð")
    }

    // MARK: - KPI

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
            kpi("Heildarupphæð", Money.format(total12, currencyCode: currency), "sum")
            kpi("Innheimt", Money.format(collected12, currencyCode: currency), "checkmark.circle", .green)
            kpi("Útistandandi", Money.format(outstanding12, currencyCode: currency), "clock", outstanding12 > 0 ? .orange : .secondary)
            kpi("Gjaldfallið", Money.format(overdueTotal, currencyCode: currency), "exclamationmark.triangle", overdueTotal > 0 ? .red : .secondary)
            kpi("Innheimtuhlutfall", collectionRateText, "percent")
            kpi("Greiðsluhraði", avgPaymentText, "speedometer")
        }
    }

    private func kpi(_ title: LocalizedStringKey, _ value: String, _ icon: String, _ tint: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            Text(value).font(.title3).bold().foregroundStyle(tint)
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Chart

    private var salesChart: some View {
        Chart(monthly, id: \.key) { item in
            BarMark(x: .value(String(localized: "Mánuður"), item.label), y: .value(String(localized: "Sala"), item.totalDouble))
                .foregroundStyle(.tint)
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let d = value.as(Double.self) { Text(compact(d)) } }
            }
        }
    }

    // MARK: - Unpaid list

    @ViewBuilder
    private var unpaidList: some View {
        if unpaid.isEmpty {
            Text("Engir ógreiddir reikningar 🎉").foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(unpaid) { inv in
                    Button { openInvoice(inv) } label: {
                        HStack {
                            Text(inv.number).bold()
                            Text(inv.recipient?.name ?? "—").foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.format(inv.total, currencyCode: inv.currencyCode)).monospacedDigit()
                            dueTag(inv)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func dueTag(_ inv: Invoice) -> some View {
        if let due = inv.dueDate {
            let overdue = due < Date()
            Text(due.formatted(date: .numeric, time: .omitted))
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background((overdue ? Color.red : Color.orange).opacity(0.18), in: Capsule())
                .foregroundStyle(overdue ? .red : .orange)
        }
    }

    // MARK: - Metrics

    private var periodStart: Date {
        Calendar.current.date(byAdding: .month, value: -12, to: Date()) ?? .distantPast
    }
    private var period: [Invoice] {
        // Tilboð eru ekki sala — undanskilin öllum sölutölum mælaborðsins.
        invoices.filter { !$0.isEstimate && $0.issueDate >= periodStart && $0.status != .cancelled }
    }
    private var total12: Decimal { period.reduce(0) { $0 + $1.total } }
    private var collected12: Decimal { period.filter { $0.status == .paid }.reduce(0) { $0 + $1.total } }
    private var outstanding12: Decimal {
        period.filter { $0.status != .paid && $0.status != .refunded }.reduce(0) { $0 + $1.total }
    }
    private var overdueTotal: Decimal {
        let now = Date()
        return period.filter {
            $0.status != .paid && $0.status != .refunded && ($0.dueDate.map { $0 < now } ?? false)
        }.reduce(0) { $0 + $1.total }
    }
    private var collectionRateText: String {
        guard total12 > 0 else { return "—" }
        let rate = (collected12 / total12 * 100 as NSDecimalNumber).doubleValue
        return "\(Int(rate.rounded()))%"
    }
    private var avgPaymentText: String {
        let days = period.compactMap(\.paymentDays)
        guard !days.isEmpty else { return "—" }
        return "\(Int((Double(days.reduce(0, +)) / Double(days.count)).rounded())) \(String(localized: "dagar"))"
    }

    private var unpaid: [Invoice] {
        invoices.filter { !$0.isEstimate && $0.status != .paid && $0.status != .cancelled && $0.status != .refunded }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private struct MonthTotal { let key: Date; let label: String; let total: Decimal
        var totalDouble: Double { (total as NSDecimalNumber).doubleValue } }

    private var monthly: [MonthTotal] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.locale = AppLanguage.currentUI.locale
        fmt.dateFormat = "MMM"
        let grouped = Dictionary(grouping: period) { inv -> Date in
            let comps = cal.dateComponents([.year, .month], from: inv.issueDate)
            return cal.date(from: comps) ?? inv.issueDate
        }
        return grouped
            .map { MonthTotal(key: $0.key, label: fmt.string(from: $0.key),
                              total: $0.value.reduce(0) { $0 + $1.total }) }
            .sorted { $0.key < $1.key }
    }

    private func compact(_ d: Double) -> String {
        if d >= 1_000_000 { return "\((d / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M" }
        if d >= 1_000 { return "\(Int(d / 1_000))k" }
        return "\(Int(d))"
    }
}
