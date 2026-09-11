import SwiftUI
import SwiftData

/// Kostnaðarlistinn (dálkur 1) — færslur virks fyrirtækis, nýjustu efst.
struct ExpenseListView: View {
    @Environment(\.modelContext) private var context
    @Environment(RukkLinkService.self) private var link: RukkLinkService?
    @Environment(ExpenseMailWatcher.self) private var mailWatcher: ExpenseMailWatcher?
    @Query private var expenses: [Expense]
    @Binding var selection: Expense?

    private let company: AppSettings

    init(company: AppSettings, selection: Binding<Expense?>) {
        self.company = company
        _selection = selection
        let cid = company.id
        _expenses = Query(
            filter: #Predicate<Expense> { $0.company?.id == cid },
            sort: [SortDescriptor(\Expense.date, order: .reverse)]
        )
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(expenses) { expense in
                ExpenseRow(expense: expense)
                    .tag(expense)
                    .contextMenu {
                        Button("Afrita") { duplicate(expense) }
                        Divider()
                        Button("Eyða", role: .destructive) {
                            if selection == expense { selection = nil }
                            context.delete(expense)
                        }
                    }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Kostnaður")
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: createExpense) {
                        Label("Nýr kostnaður", systemImage: "plus")
                            .lineLimit(1)
                    }
                    .fixedSize()
                    .help("Nýr kostnaður")
                    Spacer()
                    mailButton
                }
                .buttonStyle(.borderless)
                .barHeader()
                linkStatus
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !expenses.isEmpty {
                HStack {
                    Text("Samtals")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Money.format(total, currencyCode: company.defaultCurrencyCode))
                        .monospacedDigit()
                        .bold()
                }
                .font(.callout)
                .barHeader()
            }
        }
    }

    /// Heildarkostnaður (með VSK) allra færslna fyrirtækisins.
    private var total: Decimal {
        expenses.reduce(0) { $0 + $1.amount }
    }

    /// Staða beinnar tengingar við Bill To Book — grænt þegar síminn er tengdur.
    @ViewBuilder
    private var linkStatus: some View {
        if let link {
            HStack(spacing: 6) {
                Circle()
                    .fill(link.connectedPeerName != nil ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(link.connectedPeerName.map { String(localized: "Bill To Book tengt: \($0)") }
                     ?? String(localized: "Bill To Book — að bíða eftir síma"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    /// Handvirk póstsókn — birtist þegar póstvakt er stillt í Stillingum.
    @ViewBuilder
    private var mailButton: some View {
        if let watcher = mailWatcher, watcher.settings.isConfigured {
            Button {
                Task {
                    await watcher.checkNow(context: context) {
                        AppSettings.active(in: context,
                                           activeID: UserDefaults.standard.string(forKey: "activeCompanyID") ?? "")
                    }
                }
            } label: {
                switch watcher.state {
                case .checking:
                    ProgressView().controlSize(.small)
                default:
                    Label("Sækja póst", systemImage: "envelope.arrow.triangle.branch")
                        .labelStyle(.iconOnly)
                }
            }
            .fixedSize()
            .help(watcher.state.helpText)
        }
    }

    private func createExpense() {
        selection = Expense.makeNext(in: context, company: company)
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets {
            if selection == expenses[i] { selection = nil }
            context.delete(expenses[i])
        }
    }

    private func duplicate(_ src: Expense) {
        let copy = Expense(date: src.date, vendor: src.vendor, amount: src.amount)
        copy.company = company
        copy.expenseDescription = src.expenseDescription
        copy.category = src.category
        copy.taxRate = src.taxRate
        copy.currencyCode = src.currencyCode
        copy.note = src.note
        copy.receiptData = src.receiptData
        copy.source = src.source
        context.insert(copy)
        selection = copy
    }
}

private struct ExpenseRow: View {
    let expense: Expense

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(expense.vendor.isEmpty
                     ? String(localized: "(enginn seljandi)")
                     : expense.vendor)
                    .font(.headline)
                Text(expense.expenseDescription.isEmpty
                     ? expense.date.formatted(date: .abbreviated, time: .omitted)
                     : expense.expenseDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(expense.amount, currencyCode: expense.currencyCode))
                    .monospacedDigit()
                HStack(spacing: 4) {
                    if expense.reviewed {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .help("Búið að yfirfara")
                    }
                    if expense.receiptData != nil {
                        Image(systemName: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Kvittun fylgir")
                    }
                    if expense.source == .billToBook {
                        CapsuleTag("Bill To Book", color: .purple)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
