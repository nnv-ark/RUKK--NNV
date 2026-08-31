import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Sækir tímafærslur beint úr BLIZZ-speglinum (`BLIZZ Data/_rukk.json`) og bætir völdum
/// færslum við reikninginn sem línur (lýsing = athugasemd, magn = klst., einingaverð = taxti).
/// Gagnamappan er tengd einu sinni og geymd sem bókamerki — engin skráargluggi þar á eftir.
struct BlizzImportView: View {
    @Bindable var invoice: Invoice
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [BlizzEntry] = []
    @State private var selected: Set<String> = []
    @State private var onlyUnbilled = true
    @State private var projectFilter = ""        // "" = öll verkefni
    @State private var showingFolderPicker = false
    @State private var connected = BlizzImporter.isConnected
    @State private var error: String?

    /// Verkefnalýsingar („Viðskiptavinur — Verkefni“) sem eru í boði, stafrófsröð.
    private var projects: [String] {
        Array(Set(entries.map(\.projectLabel))).sorted()
    }

    private var visible: [BlizzEntry] {
        entries.filter { e in
            (!onlyUnbilled || e.isUnbilled) && (projectFilter.isEmpty || e.projectLabel == projectFilter)
        }
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
        .fileImporter(isPresented: $showingFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                BlizzImporter.setFolder(url)
                connected = true
                reload()
            }
        }
        .onAppear {
            if connected { reload() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sækja tíma úr BLIZZ").font(.headline)
            HStack(spacing: 12) {
                if connected {
                    Button { reload() } label: {
                        Label("Endurlesa", systemImage: "arrow.clockwise")
                    }
                    .help("Les _rukk.json aftur úr BLIZZ-gagnamöppunni")
                    Text(URL(fileURLWithPath: BlizzImporter.folderPath).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Button("Velja BLIZZ-möppu…") { showingFolderPicker = true }
                }
                Spacer()
                if !entries.isEmpty {
                    Toggle("Aðeins órukkað", isOn: $onlyUnbilled)
                        .toggleStyle(.checkbox)
                        .onChange(of: onlyUnbilled) { _, _ in pruneSelection() }
                }
            }
            if !projects.isEmpty {
                HStack(spacing: 8) {
                    Text("Verkefni:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $projectFilter) {
                        Text("Öll verkefni").tag("")
                        ForEach(projects, id: \.self) { p in
                            Text(p).tag(p)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: projectFilter) { _, _ in pruneSelection() }
                    if connected {
                        Spacer()
                        Button("Velja aðra möppu…") { showingFolderPicker = true }
                            .font(.caption)
                    }
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
        if !connected {
            ContentUnavailableView {
                Label("Engin BLIZZ-mappa tengd", systemImage: "snowflake")
            } description: {
                Text("BLIZZ skrifar tímafærslur í gagnamöppu („BLIZZ Data“). Veldu hana hér — aðeins í fyrsta skipti.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "Engar færslur",
                systemImage: "clock",
                description: Text(error ?? "Engar gjaldfærðar færslur fundust í BLIZZ-speglinum."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            ContentUnavailableView("Engar færslur",
                                   systemImage: "clock",
                                   description: Text("Engar færslur passa við síuna."))
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

    /// Les færslur úr tengdri möppu og endurstillir val (órukkað sjálfgefið valið).
    private func reload() {
        error = nil
        do {
            let parsed = try BlizzImporter.loadEntries()
            entries = parsed
            selected = Set(parsed.filter(\.isUnbilled).map(\.id))
            if !projectFilter.isEmpty && !Set(parsed.map(\.projectLabel)).contains(projectFilter) {
                projectFilter = ""
            }
        } catch {
            entries = []
            selected = []
            self.error = error.localizedDescription
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

    private func subtitle(_ e: BlizzEntry) -> String {
        var parts: [String] = []
        if let start = e.start {
            parts.append(start.formatted(date: .abbreviated, time: .omitted))
        }
        let klst = String(localized: "klst")
        parts.append("\(hoursString(e.hours)) \(klst)")
        parts.append("\(amountString(e.rate))/\(klst)")
        if projectFilter.isEmpty && !e.projectLabel.isEmpty { parts.append(e.projectLabel) }
        if e.billed { parts.append(String(localized: "Rukkað")) }
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
