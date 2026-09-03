import SwiftUI
import UniformTypeIdentifiers
import SwiftData

/// Yfirferð fyrir innflutning viðskiptavina: sýnir lesnar færslur, merkir þær sem
/// eru þegar til (eftir kennitölu) og setur valdar inn í virkt fyrirtæki.
struct CustomerImportView: View {
    let records: [CustomerRecord]
    let company: AppSettings
    var fileName: String = ""

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [Contact]

    @State private var selected: Set<UUID> = []
    @State private var strategy: DuplicateStrategy = .skip

    /// Hvernig á að meðhöndla viðskiptavini sem eru þegar til (sama kennitala).
    enum DuplicateStrategy: String, CaseIterable, Identifiable {
        case skip, update, addAll
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .skip:   return "Sleppa þeim sem eru til"
            case .update: return "Uppfæra þá sem eru til"
            case .addAll: return "Bæta öllum við"
            }
        }
    }

    init(records: [CustomerRecord], company: AppSettings, fileName: String = "") {
        self.records = records
        self.company = company
        self.fileName = fileName
        let cid = company.id
        _existing = Query(filter: #Predicate<Contact> { $0.owner?.id == cid })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .onAppear { selected = Set(records.map(\.id)) }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Flytja inn viðskiptavini").font(.headline)
                Spacer()
                if !fileName.isEmpty {
                    Text(fileName)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Text("\(records.count) \(String(localized: "í skrá"))  ·  \(duplicateCount) \(String(localized: "þegar til"))")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Ef viðskiptavinur er þegar til", selection: $strategy) {
                ForEach(DuplicateStrategy.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding()
    }

    private var list: some View {
        List {
            ForEach(records) { rec in
                Toggle(isOn: binding(for: rec.id)) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rec.displayName)
                            Text(subtitle(rec))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if isDuplicate(rec) {
                            Text("þegar til")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Hætta við") { dismiss() }
            Button(allSelected ? "Afvelja allt" : "Velja allt") { toggleAll() }
            Spacer()
            Button(importTitle) { performImport(); dismiss() }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
        }
        .padding()
    }

    // MARK: - Duplicates

    private var existingByKennitalaTrimmed: [String: Contact] {
        Dictionary(existing.compactMap { c in
            let kt = c.nationalID.trimmingCharacters(in: .whitespacesAndNewlines)
            return kt.isEmpty ? nil : (kt, c)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func match(for rec: CustomerRecord) -> Contact? {
        let kt = rec.nationalID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kt.isEmpty else { return nil }
        return existingByKennitalaTrimmed[kt]
    }

    private func isDuplicate(_ rec: CustomerRecord) -> Bool { match(for: rec) != nil }

    private var duplicateCount: Int { records.filter(isDuplicate).count }

    // MARK: - Import

    private func performImport() {
        for rec in records where selected.contains(rec.id) {
            if let existing = match(for: rec) {
                switch strategy {
                case .skip:   continue
                case .update: apply(rec, to: existing)
                case .addAll: insert(rec)
                }
            } else {
                insert(rec)
            }
        }
    }

    private func insert(_ rec: CustomerRecord) {
        let c = Contact()
        apply(rec, to: c)
        c.owner = company
        context.insert(c)
    }

    /// Skrifar reiti færslunnar á viðskiptavin (tómir reitir skrifa ekki yfir við uppfærslu).
    private func apply(_ rec: CustomerRecord, to c: Contact) {
        func set(_ value: String, _ keyPath: ReferenceWritableKeyPath<Contact, String>) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { c[keyPath: keyPath] = v }
        }
        set(rec.name, \.name)
        // Nafn sem endar á félagaformi (ehf./slf./hf. …) fyllir líka fyrirtækjareitinn.
        if CustomerImport.looksLikeCompany(rec.name) {
            c.company = rec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set(rec.nationalID, \.nationalID)
        set(rec.address, \.address)
        set(rec.postalCode, \.postalCode)
        set(rec.city, \.city)
        set(rec.country, \.country)
        set(rec.contactPerson, \.contactPerson)
        set(rec.extraInfo, \.extraInfo)
        set(rec.phone, \.phone)
        set(rec.email, \.email)
        set(rec.notes, \.notes)
        set(rec.defaultInvoiceNote, \.defaultInvoiceNote)
        c.sendElectronicInvoices = rec.sendElectronicInvoices
    }

    // MARK: - Selection

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selected.contains(id) },
                set: { if $0 { selected.insert(id) } else { selected.remove(id) } })
    }

    private var allSelected: Bool { !records.isEmpty && selected.count == records.count }

    private func toggleAll() {
        selected = allSelected ? [] : Set(records.map(\.id))
    }

    // MARK: - Formatting

    private func subtitle(_ rec: CustomerRecord) -> String {
        var parts: [String] = []
        if !rec.nationalID.isEmpty { parts.append(rec.nationalID) }
        if !rec.email.isEmpty { parts.append(rec.email) }
        let place = [rec.postalCode, rec.city].filter { !$0.isEmpty }.joined(separator: " ")
        if !place.isEmpty { parts.append(place) }
        return parts.joined(separator: "  ·  ")
    }

    private var importTitle: String {
        "\(String(localized: "Flytja inn")) \(selected.count)"
    }
}


// MARK: - Innflutningsferlið

/// Heldur utan um innflutning viðskiptavina: skráaval, yfirferð og villuskilaboð.
/// Býr hér frekar en í `ContentView` svo aðalsýnin þurfi hvorki að geyma fimm
/// stöðubreytur né þrjá kynningarhætti fyrir eitt ferli.
@MainActor
@Observable
final class CustomerImportFlow {
    var isChoosingFile = false
    var isReviewing = false
    var records: [CustomerRecord] = []
    var fileName = ""
    var error: String?

    var fileTypes: [UTType] { UTType.customerListTypes }

    func begin() {
        error = nil
        isChoosingFile = true
    }

    /// Les skrá sem notandi sleppti og opnar yfirferðina beint.
    @discardableResult
    func open(_ url: URL) -> Bool {
        error = nil
        do {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            records = try CustomerImport.records(from: url)
            fileName = url.lastPathComponent
            isReviewing = true
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func handle(_ result: Result<[URL], Error>) {
        error = nil
        do {
            guard let url = try result.get().first else { return }
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            records = try CustomerImport.records(from: url)
            fileName = url.lastPathComponent
            isReviewing = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension View {
    /// Tengir skráaval, yfirferðarspjald og villuskilaboð innflutningsins við sýnina.
    func customerImport(_ flow: CustomerImportFlow, company: AppSettings?) -> some View {
        modifier(CustomerImportModifier(flow: flow, company: company))
    }
}

private struct CustomerImportModifier: ViewModifier {
    @Bindable var flow: CustomerImportFlow
    let company: AppSettings?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $flow.isChoosingFile,
                          allowedContentTypes: flow.fileTypes,
                          allowsMultipleSelection: false) { flow.handle($0) }
            .sheet(isPresented: $flow.isReviewing) {
                if let company {
                    CustomerImportView(records: flow.records, company: company, fileName: flow.fileName)
                }
            }
            .alert("Innflutningur mistókst",
                   isPresented: Binding(get: { flow.error != nil },
                                        set: { if !$0 { flow.error = nil } }),
                   presenting: flow.error) { _ in
                Button("Í lagi", role: .cancel) { flow.error = nil }
            } message: { Text($0) }
    }
}
