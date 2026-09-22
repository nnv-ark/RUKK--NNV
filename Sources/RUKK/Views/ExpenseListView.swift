import SwiftUI
import SwiftData

/// Kostnaðarlistinn (dálkur 1) — færslur virks fyrirtækis, nýjustu efst.
struct ExpenseListView: View {
    @Environment(\.modelContext) private var context
    @Environment(RukkLinkService.self) private var link: RukkLinkService?
    @Environment(ExpenseMailWatcher.self) private var mailWatcher: ExpenseMailWatcher?
    @Query private var expenses: [Expense]
    @Binding var selection: Expense?
    @Environment(\.locale) private var locale
    /// Mánuðir sem notandinn hefur lagt saman, geymt milli keyrslna.
    /// Lyklar eru ár*100+mánuður (202609) aðgreindir með kommu.
    @AppStorage("expenseLokadirManudir") private var lokadirRaw = ""

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
            ForEach(manudir) { manudur in
                Section {
                    if erOpinn(manudur) {
                        ForEach(manudur.faerslur) { expense in
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
                        .onDelete { eyða($0, í: manudur.faerslur) }
                    }
                } header: {
                    manadarHaus(manudur)
                }
            }
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
                mailStatus
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
    /// Hægri smellur býður að gleyma pöruðum símum (næsta boð spyr þá aftur).
    @ViewBuilder
    private var linkStatus: some View {
        if let link {
            HStack(spacing: 6) {
                Circle()
                    .fill(link.connectedPeerName != nil ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(linkStatusText(link))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
            .contextMenu {
                if !link.pairedDevices.isEmpty {
                    Button("Gleyma pöruðum símum") { link.forgetPairings() }
                }
            }
        }
    }

    /// Tengdur sími > paraður sími sem ekki sést > enginn sími enn.
    private func linkStatusText(_ link: RukkLinkService) -> String {
        if let name = link.connectedPeerName {
            return String(localized: "Bill To Book tengt: \(name)")
        }
        if let paired = link.pairedDevices.values.sorted().first {
            return String(localized: "Bill To Book — bíð eftir \(paired)")
        }
        return String(localized: "Bill To Book — að bíða eftir síma")
    }

    /// Handvirk póstsókn — birtist þegar póstvakt er stillt í Stillingum.
    /// Textalýsing (ekki bara tákn) svo takkinn sé auðfundinn.
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
                        .lineLimit(1)
                }
            }
            .fixedSize()
            .help(watcher.state.helpText)
        }
    }

    /// Staða póstvaktar — niðurstaða síðustu sóknar og hvenær hún var.
    /// Gefur svarið „kom eitthvað inn?" án þess að þurfa að giska.
    @ViewBuilder
    private var mailStatus: some View {
        if let watcher = mailWatcher, watcher.settings.isConfigured {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(for: watcher.state))
                    .frame(width: 6, height: 6)
                Text(statusText(for: watcher))
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

    private func statusColor(for state: ExpenseMailWatcher.State) -> Color {
        switch state {
        case .idle, .checking: .secondary.opacity(0.5)
        case .ok:              .green
        case .failed:          .red
        }
    }

    private func statusText(for watcher: ExpenseMailWatcher) -> String {
        switch watcher.state {
        case .idle:
            return String(localized: "Póstvakt virk — athugar sjálfkrafa")
        case .checking:
            return String(localized: "Sæki póst…")
        case .ok(let msg), .failed(let msg):
            if let when = watcher.lastChecked {
                return "\(msg) · \(when.formatted(date: .omitted, time: .shortened))"
            }
            return msg
        }
    }

    // MARK: - Mánuðir

    /// Einn mánuður í listanum.
    private struct Manudur: Identifiable {
        /// ár*100 + mánuður, t.d. 202609 — raðast rétt sem tala.
        let id: Int
        let heiti: String
        let faerslur: [Expense]
        var samtals: Decimal { faerslur.reduce(0) { $0 + $1.amount } }
    }

    /// Færslurnar flokkaðar á mánuði, nýjasti mánuður efst. Fyrirspurnin
    /// skilar þeim þegar í dagsetningarröð, svo röðin innan mánaðar helst.
    private var manudir: [Manudur] {
        let dagatal = Calendar.current
        let snið = DateFormatter()
        snið.locale = locale
        snið.setLocalizedDateFormatFromTemplate("MMMM yyyy")

        var röð: [Int] = []
        var hópar: [Int: [Expense]] = [:]
        for expense in expenses {
            let hlutar = dagatal.dateComponents([.year, .month], from: expense.date)
            let lykill = (hlutar.year ?? 0) * 100 + (hlutar.month ?? 0)
            if hópar[lykill] == nil { röð.append(lykill) }
            hópar[lykill, default: []].append(expense)
        }
        return röð.compactMap { lykill in
            guard let faerslur = hópar[lykill], let fyrsta = faerslur.first else { return nil }
            return Manudur(id: lykill,
                           heiti: snið.string(from: fyrsta.date),
                           faerslur: faerslur)
        }
    }

    /// Haus mánaðar: nafn, fjöldi og samtala — allur hausinn leggur saman.
    private func manadarHaus(_ manudur: Manudur) -> some View {
        Button {
            leggjaSamanEðaOpna(manudur)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: erOpinn(manudur) ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(manudur.heiti)
                Spacer(minLength: 8)
                Text("\(manudur.faerslur.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(Money.format(manudur.samtals, currencyCode: company.defaultCurrencyCode))
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(erOpinn(manudur) ? "Leggja mánuðinn saman" : "Opna mánuðinn")
    }

    private var lokadir: Set<Int> {
        Set(lokadirRaw.split(separator: ",").compactMap { Int($0) })
    }

    private func erOpinn(_ manudur: Manudur) -> Bool {
        !lokadir.contains(manudur.id)
    }

    private func leggjaSamanEðaOpna(_ manudur: Manudur) {
        var nýtt = lokadir
        if nýtt.contains(manudur.id) {
            nýtt.remove(manudur.id)
        } else {
            nýtt.insert(manudur.id)
        }
        lokadirRaw = nýtt.sorted().map(String.init).joined(separator: ",")
    }

    private func createExpense() {
        selection = Expense.makeNext(in: context, company: company)
    }

    private func eyða(_ offsets: IndexSet, í faerslur: [Expense]) {
        for i in offsets where faerslur.indices.contains(i) {
            if selection == faerslur[i] { selection = nil }
            context.delete(faerslur[i])
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
        copy.isVatSplit = src.isVatSplit
        copy.splitGross24 = src.splitGross24
        copy.splitGross11 = src.splitGross11
        copy.splitGross0 = src.splitGross0
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
