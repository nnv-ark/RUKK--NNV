import Foundation

/// Tímafærsla úr BLIZZ-speglinum (`BLIZZ Data/_rukk.json`) sem hægt er að breyta í reikningslínu.
/// BLIZZ skrifar skrána sjálfkrafa í tengda gagnamöppu (~2 sek. eftir hverja breytingu).
struct BlizzEntry: Identifiable {
    let id: String
    let client: String
    let project: String
    let task: String
    let note: String
    let durationMinutes: Int
    let rate: Decimal          // tímakaup
    let billed: Bool
    let paid: Bool
    let start: Date?

    /// Lengd í klukkustundum (t.d. 0,5).
    var hours: Decimal { Decimal(durationMinutes) / 60 }

    var isUnbilled: Bool { !billed }

    /// „Viðskiptavinur — Verkefni“ (eða bara verkefnið ef enginn viðskiptavinur er skráður).
    var projectLabel: String { client.isEmpty ? project : "\(client) — \(project)" }

    /// Lýsing fyrir reikningslínu: athugasemd, annars verkþáttur, annars verkefni.
    var lineDescription: String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? project : t
    }
}

/// Les BLIZZ-spegilskrána `_rukk.json` úr gagnamöppu sem notandinn tengir einu sinni.
/// Mappan er geymd sem security-scoped bókamerki svo aðgangur þrífist milli ræsinga
/// í sandkassanum (sama mynstur og BLIZZ notar sjálft). Óundirritaðar þróunarbyggingar
/// falla til baka á hreina slóð.
enum BlizzImporter {

    enum ImportError: LocalizedError {
        /// Mappan er tengd en `_rukk.json` finnst ekki (spegill ekki virkur í BLIZZ).
        case fileMissing

        var errorDescription: String? {
            switch self {
            case .fileMissing:
                return String(localized: "Fann ekki _rukk.json í BLIZZ-gagnamöppunni. Kveiktu á gagnamöppu í BLIZZ (Stillingar) og reyndu aftur.")
            }
        }
    }

    static let folderKey = "blizzFolder.path"
    static let bookmarkKey = "blizzFolder.bookmark"

    /// Slóðin á tengdu möppunni, til sýnis í viðmóti (tóm = engin mappa tengd).
    static var folderPath: String { UserDefaults.standard.string(forKey: folderKey) ?? "" }
    static var isConnected: Bool { !folderPath.isEmpty }

    /// Tengir notandavalda möppu: geymir slóð (til sýnis) og security-scoped bókamerki.
    static func setFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: folderKey)
        if let bm = try? url.bookmarkData(options: .withSecurityScope,
                                          includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bm, forKey: bookmarkKey)
        } else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    /// Aftengir möppuna alveg.
    static func clearFolder() {
        UserDefaults.standard.removeObject(forKey: folderKey)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Keyrir `body` með tengdu möppunni uppleystri og security-scoped aðgangi haldnum
    /// á meðan. Skilar `nil` þegar engin mappa er tengd.
    @discardableResult
    static func withFolderAccess<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard isConnected else { return nil }
        if let bm = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bm, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                return try body(url)
            }
        }
        return try body(URL(fileURLWithPath: folderPath))
    }

    /// Hleður öllum færslum úr tengdri möppu. Notandinn má bæði velja möppuna sem
    /// inniheldur „BLIZZ Data“ eða „BLIZZ Data“ möppuna sjálfa.
    /// Kastar `ImportError.fileMissing` ef skráin finnst ekki.
    static func loadEntries() throws -> [BlizzEntry] {
        guard let result = try withFolderAccess({ base -> [BlizzEntry] in
            let direct = base.appendingPathComponent("_rukk.json")
            let nested = base.appendingPathComponent("BLIZZ Data").appendingPathComponent("_rukk.json")
            let url = FileManager.default.fileExists(atPath: direct.path) ? direct : nested
            guard FileManager.default.fileExists(atPath: url.path) else { throw ImportError.fileMissing }
            return parse(try Data(contentsOf: url))
        }) else { throw ImportError.fileMissing }
        return result
    }

    /// Les `_rukk.json` skrá og skilar færslum, elstar fyrst.
    static func parse(_ data: Data) -> [BlizzEntry] {
        struct Raw: Decodable {
            let id: String
            let client: String?
            let project: String?
            let task: String?
            let note: String?
            let durationMinutes: Int?
            let rate: Decimal?
            let billed: Bool?
            let paid: Bool?
            let start: Date?
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let raw = try? dec.decode([Raw].self, from: data) else { return [] }
        return raw.map { r in
            BlizzEntry(id: r.id,
                       client: r.client ?? "",
                       project: r.project ?? "",
                       task: r.task ?? "",
                       note: r.note ?? "",
                       durationMinutes: r.durationMinutes ?? 0,
                       rate: r.rate ?? 0,
                       billed: r.billed ?? false,
                       paid: r.paid ?? false,
                       start: r.start)
        }
        .sorted { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }
    }
}
