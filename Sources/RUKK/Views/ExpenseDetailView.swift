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
                Toggle("Sundurliða eftir VSK-þrepum", isOn: splitBinding)
                if expense.isVatSplit {
                    TextField("Hluti með 24 % VSK", value: $expense.splitGross24, format: .number)
                    TextField("Hluti með 11 % VSK", value: $expense.splitGross11, format: .number)
                    TextField("Hluti án VSK", value: $expense.splitGross0, format: .number)
                    if splitRemainder != 0 {
                        HStack {
                            Text("Óúthlutað")
                            Spacer()
                            Text(Money.format(splitRemainder, currencyCode: expense.currencyCode))
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                } else {
                    Picker("VSK", selection: $expense.taxRate) {
                        Text("24 %").tag(Decimal(24))
                        Text("11 %").tag(Decimal(11))
                        Text("0 %").tag(Decimal(0))
                    }
                    .pickerStyle(.segmented)
                }
                HStack {
                    Text("Þar af VSK")
                    Spacer()
                    Text(Money.format(expense.vatAmount, currencyCode: expense.currencyCode))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                TextField("Mynt", text: $expense.currencyCode)
            }

            Section {
                Toggle("Búið að yfirfara", isOn: $expense.reviewed)
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

    // MARK: - VSK-sundurliðun

    /// Hakk sem virkjar sundurliðun — fyllir þrepið sem samsvarar núverandi
    /// hlutfalli með allri upphæðinni svo summa þrepanna stemmi frá byrjun.
    private var splitBinding: Binding<Bool> {
        Binding(
            get: { expense.isVatSplit },
            set: { on in
                expense.isVatSplit = on
                if on, expense.splitGross24 + expense.splitGross11 + expense.splitGross0 == 0 {
                    switch expense.taxRate {
                    case 11: expense.splitGross11 = expense.amount
                    case 0:  expense.splitGross0 = expense.amount
                    default: expense.splitGross24 = expense.amount
                    }
                }
            }
        )
    }

    /// Upphæð sem er ekki úthlutuð á þrep — á að vera 0 þegar sundurliðun er tilbúin.
    private var splitRemainder: Decimal {
        expense.amount - expense.splitGross24 - expense.splitGross11 - expense.splitGross0
    }

    // MARK: - Kvittunarmynd

    @ViewBuilder
    private var receiptWell: some View {
        // ReceiptImage.render skilgreinir upplausn: PDF er rendrað í fullri
        // gæði (NSImage(data:) gefur bara lágupplýsta fyrstu-síðu birtingu).
        if let data = expense.receiptData, let image = ReceiptImage.render(data) {
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                HStack {
                    if expense.source == .billToBook {
                        CapsuleTag("Frá Bill To Book", color: .purple)
                    }
                    if ReceiptImage.isPDF(data) {
                        CapsuleTag("PDF", color: .gray)
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
                Text("Droppaðu kvittun hér (PDF, JPG eða PNG)")
                    .foregroundStyle(.secondary)
                Button("Velja skrá…") { pickReceipt() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first,
                      let data = try? Data(contentsOf: url),
                      ReceiptImage.isPDF(data) || NSImage(data: data) != nil else { return false }
                expense.receiptData = ReceiptImage.normalized(data)
                return true
            }
        }
    }

    /// Skráarveljari fyrir kvittun — PDF, JPEG og PNG.
    private func pickReceipt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              ReceiptImage.isPDF(data) || NSImage(data: data) != nil else { return }
        expense.receiptData = ReceiptImage.normalized(data)
    }

    /// Opnar kvittunarmyndina í Preview með réttri skráarendingu (pdf/jpg/png).
    private func openReceipt(_ data: Data) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rukk-kvittun-\(expense.createdAt.timeIntervalSince1970).\(ReceiptImage.fileExtension(for: data))")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}
