import SwiftUI
import SwiftData

struct ContactsView: View {
    @Environment(\.modelContext) private var context
    @Query private var contacts: [Contact]
    @Binding var selection: Contact?
    @State private var searchText = ""

    private let company: AppSettings
    /// Ræst þegar nýr viðskiptavinur verður til — dálkur 2 býður þá innflutning
    /// sem valkost við handvirka innslátt.
    private let onCreate: (Contact) -> Void
    /// Skrá með viðskiptavinum sem var sleppt á listann.
    private let onDropFile: (URL) -> Bool

    init(company: AppSettings,
         selection: Binding<Contact?>,
         onCreate: @escaping (Contact) -> Void = { _ in },
         onDropFile: @escaping (URL) -> Bool = { _ in false }) {
        self.company = company
        self.onCreate = onCreate
        self.onDropFile = onDropFile
        _selection = selection
        let cid = company.id
        _contacts = Query(filter: #Predicate<Contact> { $0.owner?.id == cid }, sort: \Contact.name)
    }

    private var filteredContacts: [Contact] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return contacts }
        return contacts.filter { c in
            [c.name, c.company, c.email, c.phone, c.nationalID]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    var body: some View {
        List(selection: $selection) {
            newCustomerRow
            ForEach(filteredContacts) { contact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name.isEmpty ? "(nafnlaus)" : contact.name).font(.headline)
                    if !contact.email.isEmpty {
                        Text(contact.email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(contact)
                .contextMenu {
                    Button("Afrita") {
                        let copy = Contact(name: contact.name + " afrit",
                                           company: contact.company,
                                           nationalID: contact.nationalID,
                                           email: contact.email,
                                           phone: contact.phone,
                                           address: contact.address)
                        copy.notes = contact.notes
                        copy.owner = company
                        context.insert(copy)
                        selection = copy
                    }
                    Divider()
                    Button("Eyða", role: .destructive) {
                        if selection == contact { selection = nil }
                        context.delete(contact)
                    }
                }
            }
            .onDelete { offsets in
                let items = filteredContacts
                for i in offsets {
                    let contact = items[i]
                    if selection == contact { selection = nil }
                    context.delete(contact)
                }
            }
        }
        .navigationTitle("Viðskiptavinir")
        // Sleppa Excel-, CSV- eða XML-skrá hvar sem er á listanum til að flytja inn.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: DroppedFile.isCustomerList) else { return false }
            return onDropFile(url)
        }
        // Leitin situr efst; „Nýr viðskiptavinur" er fyrsta færslan í listanum sjálfum.
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Leita að viðskiptavini", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .barHeader(horizontal: 10)
        }
    }

    /// Efsta færslan í listanum: lítur út eins og viðskiptavinur, en römmuð eins og hnappur.
    private var newCustomerRow: some View {
        Button(action: newCustomer) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.headline)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Nýr viðskiptavinur").font(.headline)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1)
        }
        .help("Nýr viðskiptavinur")
        .listRowSeparator(.hidden)
    }

    private func newCustomer() {
        let c = Contact(name: "Nýr viðskiptavinur")
        c.owner = company
        context.insert(c)
        selection = c
        onCreate(c)
    }
}
