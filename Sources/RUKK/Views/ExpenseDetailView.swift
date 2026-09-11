import SwiftUI
import SwiftData
import AppKit

/// Nánarsýn kostnaðarfærslu (dálkur 2): handskráning á öllum reitum og
/// kvittunarmynd sem má droppa inn — eða sem Bill To Book sendir með færslunni.
struct ExpenseDetailView: View {
    @Bindable var expense: Expense

    /// Algengir bókhaldsflokkar — tillögur við hlið frjálsa textans.
    private static let suggestedCategories: [String] = [
        "Skrifstofuvörur", "Veitingar og veislur", "Ferðakostnaður",
        "Bifreiðakostnaður", "Tæki og hugbúnaður", "Sími og fjarskipti",
        "Leiga", "Iðgjöld og þjónusta", "Annað"
    ]

    var body: some View {
        Form {
            Section("Færsla") {
                DatePicker("Dagsetning", selection: $expense.date, displayedComponents: .date)
                TextField("Seljandi", text: $expense.vendor,
                          prompt: Text("t.d. Bónus, Olís, Nova"))
                TextField("Lýsing", text: $expense.expenseDescription,
                          prompt: Text("hvað var keypt"))
                HStack {
                    TextField("Flokkur", text: $expense.category,
                              prompt: Text("t.d. Skrifstofuvörur"))
                    Menu {
                        ForEach(Self.suggestedCategories, id: \.self) { category in
                            Button(category) { expense.category = category }
                        }
                    } label: {
                        Image(systemName: "chevron.down.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Algengir flokkar")
                }
            }

            Section("Upphæð") {
                TextField("Upphæð með VSK", value: $expense.amount, format: .number)
                Picker("VSK", selection: $expense.taxRate) {
                    Text("24 %").tag(Decimal(24))
                    Text("11 %").tag(Decimal(11))
                    Text("0 %").tag(Decimal(0))
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("Þar af VSK")
                    Spacer()
                    Text(Money.format(expense.vatAmount, currencyCode: expense.currencyCode))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                TextField("Mynt", text: $expense.currencyCode)
            }

            Section("Athugasemd") {
                TextField("Athugasemd", text: $expense.note, axis: .vertical)
            }

            Section("Kvittun") {
                receiptWell
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420)
    }

    // MARK: - Kvittunarmynd

    @ViewBuilder
    private var receiptWell: some View {
        if let data = expense.receiptData, let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    if expense.source == .billToBook {
                        CapsuleTag("Frá Bill To Book", color: .purple)
                    }
                    Spacer()
                    Button("Opna í Preview") { openReceipt(data) }
                    Button("Fjarlægja mynd", role: .destructive) { expense.receiptData = nil }
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "doc.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Droppaðu kvittunarmynd hér")
                    .foregroundStyle(.secondary)
                Button("Velja mynd…") { pickReceipt() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url),
                      NSImage(data: data) != nil else { return false }
                expense.receiptData = data
                return true
            }
        }
    }

    /// Skráarveljari fyrir kvittunarmynd.
    private func pickReceipt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
        expense.receiptData = data
    }

    /// Opnar kvittunarmyndina í Preview (tímabundin skrá í /tmp).
    private func openReceipt(_ data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukk-kvittun-\(expense.createdAt.timeIntervalSince1970).png")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}
