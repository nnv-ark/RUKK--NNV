import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Les Tyme-JSON útflutning sem notandinn velur og bætir völdum tímafærslum við
/// reikninginn sem línur (lýsing = athugasemd, magn = klst., einingarverð = taxti úr Tyme).
struct TymeImportView: View {
    @Bindable var invoice: Invoice
    /// Skrá sem var sleppt á reikninginn — lesin um leið og glugginn opnast.
    var initialFile: URL?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [TymeEntry] = []
    @State private var selected: Set<String> = []
    @State private var onlyUnbilled = true
    @State private var showingPicker = false
    @State private var fileName = ""
    @State private var error: String?

    private var visible: [TymeEntry] {
        onlyUnbilled ? entries.filter(\.isUnbilled) : entries
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 600)
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { load(url) }
            case .failure(let e):    error = e.localizedDescription
            }
        }
        .task {
            if let initialFile { load(initialFile) }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sækja tíma úr Tyme").font(.headline)
            HStack(spacing: 12) {
                Button("Velja Tyme-skrá…") { showingPicker = true }
                if !fileName.isEmpty {
                    Text(fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if !entries.isEmpty {
                    Toggle("Aðeins órukkað", isOn: $onlyUnbilled)
                        .toggleStyle(.checkbox)
                        .onChange(of: onlyUnbilled) { _, _ in pruneSelection() }
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            ContentUnavailableView {
                Label("Engin Tyme-skrá", systemImage: "clock.badge")
            } description: {
                Text("Flyttu út tímafærslur úr Tyme sem JSON og veldu skrána hér.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView("Engar færslur",
                                   systemImage: "clock",
                                   description: Text("Engar órukkaðar færslur í skránni."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(visible) { e in
                    Toggle(isOn: binding(for: e.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.lineDescription)
                            Text(subtitle(e))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Hætta við") { dismiss() }
            if !visible.isEmpty {
                Button(allSelected ? "Afvelja allt" : "Velja allt") { toggleAll() }
            }
            Spacer()
            Text(totalLabel).font(.caption).foregroundStyle(.secondary)
            Button(addButtonTitle) { addSelected(); dismiss() }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
        }
        .padding()
    }

    // MARK: - Logic

    private func load(_ url: URL) {
        error = nil
        do {
            guard let data = DroppedFile.data(at: url) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let parsed = TymeImporter.parse(data)
            guard !parsed.isEmpty else {
                error = String(localized: "Engar tímafærslur fundust í skránni.")
                entries = []; selected = []; fileName = url.lastPathComponent
                return
            }
            entries = parsed
            fileName = url.lastPathComponent
            selected = Set(parsed.filter(\.isUnbilled).map(\.id))
        } catch {
            self.error = "\(String(localized: "Gat ekki lesið skrána:")) \(error.localizedDescription)"
        }
    }

    private func addSelected() {
        let chosen = entries.filter { selected.contains($0.id) }
        var order = (invoice.lineItems.map(\.order).max() ?? -1) + 1
        for e in chosen {
            let li = LineItem(description: e.lineDescription,
                              quantity: e.hours,
                              unitPrice: e.rate,
                              taxRate: invoice.taxRate,
                              order: order)
            li.invoice = invoice
            invoice.lineItems.append(li)
            context.insert(li)
            order += 1
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private var allSelected: Bool {
        !visible.isEmpty && visible.allSatisfy { selected.contains($0.id) }
    }

    private func toggleAll() {
        if allSelected {
            for e in visible { selected.remove(e.id) }
        } else {
            for e in visible { selected.insert(e.id) }
        }
    }

    /// Heldur aðeins vali sem er enn sýnilegt þegar síu er breytt.
    private func pruneSelection() {
        let ids = Set(visible.map(\.id))
        selected.formIntersection(ids)
    }

    // MARK: - Formatting

    private func subtitle(_ e: TymeEntry) -> String {
        var parts: [String] = []
        if let start = e.start {
            parts.append(start.formatted(date: .abbreviated, time: .omitted))
        }
        let klst = String(localized: "klst")
        parts.append("\(hoursString(e.hours)) \(klst)")
        parts.append("\(amountString(e.rate))/\(klst)")
        if !e.project.isEmpty { parts.append(e.project) }
        if !e.isUnbilled { parts.append(e.billing.capitalized) }
        return parts.joined(separator: "  ·  ")
    }

    private var totalLabel: String {
        guard !selected.isEmpty else { return "" }
        let chosen = entries.filter { selected.contains($0.id) }
        let hours = chosen.reduce(Decimal(0)) { $0 + $1.hours }
        let amount = chosen.reduce(Decimal(0)) { $0 + $1.hours * $1.rate }
        return "\(String(localized: "Samtals")) \(hoursString(hours)) \(String(localized: "klst"))  ·  \(amountString(amount))"
    }

    private var addButtonTitle: String {
        "\(String(localized: "Bæta")) \(selected.count) \(String(localized: "við reikning"))"
    }

    private func hoursString(_ h: Decimal) -> String {
        (h as NSDecimalNumber).doubleValue.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func amountString(_ a: Decimal) -> String {
        (a as NSDecimalNumber).doubleValue
            .formatted(.currency(code: "ISK").precision(.fractionLength(0)))
    }
}
