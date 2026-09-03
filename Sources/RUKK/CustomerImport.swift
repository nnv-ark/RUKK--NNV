import Foundation

/// Ein færsla úr innfluttri skrá — óháð sniði (xlsx / CSV / XML).
struct CustomerRecord: Identifiable, Equatable {
    let id = UUID()
    var nationalID = ""            // Kennitala
    var name = ""                  // Nafn
    var address = ""               // Heimilisfang
    var postalCode = ""            // Póstnúmer
    var city = ""                  // Staður
    var country = ""               // Land
    var extraInfo = ""             // Aukaupplýsingar
    var contactPerson = ""         // Tengiliður
    var phone = ""                 // Sími
    var email = ""                 // Netfang
    var notes = ""                 // Athugasemd
    var defaultInvoiceNote = ""    // Sjálfgefin athugasemd á reikningum
    var sendElectronicInvoices = false // Senda rafræna reikninga

    /// Færsla telst tóm ef ekkert af lykilreitum er útfyllt.
    var isEmpty: Bool {
        [nationalID, name, email, phone, address, contactPerson]
            .allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Birtingarnafn í yfirliti.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { return n }
        let c = contactPerson.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? String(localized: "(nafnlaus)") : c
    }
}

/// Les viðskiptavinalista úr xlsx-, CSV- eða XML-skrá.
/// Sniðið er greint eftir skráarendingu; dálkar eru kortlagðir eftir hausum
/// (röð dálka skiptir ekki máli).
enum CustomerImport {

    enum Format { case csv, xml, xlsx }

    enum ImportError: LocalizedError {
        case unsupportedFormat
        case noColumnsRecognized
        case empty
        case underlying(Error)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return String(localized: "Óstutt skráarsnið. Notaðu Excel (.xlsx), CSV eða XML.")
            case .noColumnsRecognized:
                return String(localized: "Engir þekktir dálkar fundust. Fyrsta röðin á að innihalda hausa (t.d. Kennitala, Nafn, Netfang).")
            case .empty:
                return String(localized: "Engir viðskiptavinir fundust í skránni.")
            case .underlying(let e):
                return e.localizedDescription
            }
        }
    }

    static func format(for url: URL) -> Format? {
        switch url.pathExtension.lowercased() {
        case "xlsx":               return .xlsx
        case "xml":                return .xml
        case "csv", "tsv", "txt":  return .csv
        default:                   return nil
        }
    }

    /// Meginaðgerð: les skrá og skilar færslum (henni hefur þegar verið hleypt í gegn um
    /// öryggis-scope í kallandanum).
    static func records(from url: URL) throws -> [CustomerRecord] {
        guard let format = format(for: url) else { throw ImportError.unsupportedFormat }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ImportError.underlying(error) }

        let records: [CustomerRecord]
        switch format {
        case .csv:
            let text = decodeText(data)
            records = try recordsFromRows(parseCSV(text))
        case .xlsx:
            do { records = try recordsFromRows(XLSXReader.rows(from: data)) }
            catch let e as ImportError { throw e }
            catch { throw ImportError.underlying(error) }
        case .xml:
            records = try parseXML(data)
        }

        let cleaned = records.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw ImportError.empty }
        return cleaned
    }

    // MARK: - Raðir → færslur (xlsx / CSV)

    private static func recordsFromRows(_ rows: [[String]]) throws -> [CustomerRecord] {
        // Fyrsta röð sem inniheldur einhvern texta er hausalínan.
        guard let headerIndex = rows.firstIndex(where: { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }) else {
            throw ImportError.empty
        }
        let header = rows[headerIndex]
        let mapping: [Int: WritableKeyPath<CustomerRecord, String>] = header.enumerated().reduce(into: [:]) { dict, pair in
            if let field = Field.string(forHeader: pair.element) { dict[pair.offset] = field }
        }
        let boolColumns: [Int] = header.enumerated().compactMap { Field.isElectronicInvoiceHeader($0.element) ? $0.offset : nil }

        guard !mapping.isEmpty || !boolColumns.isEmpty else { throw ImportError.noColumnsRecognized }

        var result: [CustomerRecord] = []
        for row in rows[(headerIndex + 1)...] {
            var rec = CustomerRecord()
            for (col, keyPath) in mapping where col < row.count {
                rec[keyPath: keyPath] = row[col].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for col in boolColumns where col < row.count {
                rec.sendElectronicInvoices = parseBool(row[col])
            }
            result.append(rec)
        }
        return result
    }

    // MARK: - CSV

    /// Les CSV með sjálfvirkri aðgreiningu (`;`, `,` eða tab) og RFC 4180 gæsalöppum.
    static func parseCSV(_ raw: String) -> [[String]] {
        var text = raw
        if text.first == "\u{FEFF}" { text.removeFirst() }           // BOM
        let delimiter = detectDelimiter(text)

        var rows: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false; i += 1
                } else { field.append(ch); i += 1 }
            } else {
                switch ch {
                case "\"":
                    inQuotes = true; i += 1
                case delimiter:
                    record.append(field); field = ""; i += 1
                case "\n", "\r":
                    if ch == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                    record.append(field); field = ""
                    rows.append(record); record = []
                    i += 1
                default:
                    field.append(ch); i += 1
                }
            }
        }
        record.append(field)
        // Sleppa aftasta „gervi“-raðinni ef skrá endar á línuskilum.
        if !(record.count == 1 && record[0].isEmpty) { rows.append(record) }
        return rows
    }

    private static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r" }
        let candidates: [Character] = [";", ",", "\t"]
        let counts = candidates.map { c in (c, firstLine.filter { $0 == c }.count) }
        guard let best = counts.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return "," }
        return best.0
    }

    // MARK: - XML

    private static func parseXML(_ data: Data) throws -> [CustomerRecord] {
        let delegate = CustomerXMLDelegate()
        let parser = XMLParser(data: data)
        // Skrár með namespace-forskeyti (<ns:vidskiptavinur>) eiga líka að lesast.
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw ImportError.underlying(parser.parserError ?? ImportError.empty)
        }
        return delegate.records
    }

    // MARK: - Hjálp

    /// Excel skrifar „Unicode Text" sem UTF-16 með BOM. Latin-1 tekur við hvaða bætum
    /// sem er án þess að falla, svo BOM-ið verður að ráða áður en fallið er á það —
    /// annars flyst hver einasta lína inn sem stafarugl.
    private static func decodeText(_ data: Data) -> String {
        let bom = [UInt8](data.prefix(3))
        if bom.count >= 2 {
            if bom[0] == 0xFF, bom[1] == 0xFE,
               let s = String(data: data, encoding: .utf16LittleEndian) {
                return String(s.dropFirst())          // BOM-stafurinn sjálfur
            }
            if bom[0] == 0xFE, bom[1] == 0xFF,
               let s = String(data: data, encoding: .utf16BigEndian) {
                return String(s.dropFirst())
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseBool(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["já", "ja", "yes", "y", "true", "1", "x", "satt", "✓"].contains(v)
    }

    /// Íslensk félagaform-viðskeyti. Nafn sem endar á einu þeirra telst fyrirtækjanafn.
    private static let companySuffixes: Set<String> = [
        "ehf", "hf", "slf", "slhf", "ohf", "ses", "sf", "bs", "svf",
        "ltd", "inc", "llc", "gmbh", "as", "ab", "oy"
    ]

    /// Endar nafnið á félagaformi (t.d. „… ehf.“, „… slf.“, „… hf.“)?
    static func looksLikeCompany(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).last else { return false }
        let token = String(last).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        return companySuffixes.contains(token)
    }
}

// MARK: - Hausakortlagning

/// Kortleggur hausatexta á reit í `CustomerRecord`, óháð há-/lágstöfum, bili,
/// greinamerkjum og íslenskum broddstöfum. Íslensk og ensk samheiti studd.
enum Field {
    /// Fletir haus: lágstafir, án broddstafa/greinamerkja/bila. Íslensku sérstafirnir
    /// ð/þ/æ/ö eru ekki „broddstafir“ og því umritaðir sérstaklega (ð→d, þ→th, æ→ae, ö→o)
    /// áður en broddar (á/í/ú/ó/é/ý) eru fjarlægðir.
    static func normalize(_ header: String) -> String {
        var transliterated = ""
        for ch in header.lowercased() {
            switch ch {
            case "ð": transliterated += "d"
            case "þ": transliterated += "th"
            case "æ": transliterated += "ae"
            case "ö", "ø": transliterated += "o"
            case "å": transliterated += "a"
            default:  transliterated.append(ch)
            }
        }
        let folded = transliterated.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
        return folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func string(forHeader header: String) -> WritableKeyPath<CustomerRecord, String>? {
        switch normalize(header) {
        case "kennitala", "kt", "ssn", "nationalid", "id", "vidskiptanumer", "customernumber":
            return \.nationalID
        case "nafn", "name", "vidskiptavinur", "customer", "fyrirtaeki", "company", "fullname":
            return \.name
        case "heimilisfang", "address", "gata", "street", "adress":
            return \.address
        case "postnumer", "postnr", "postalcode", "zip", "zipcode", "postcode":
            return \.postalCode
        case "stadur", "borg", "city", "place", "town":
            return \.city
        case "land", "country":
            return \.country
        case "aukaupplysingar", "extrainfo", "extra", "additionalinfo":
            return \.extraInfo
        case "tengilidur", "contact", "contactperson", "attn", "attention":
            return \.contactPerson
        case "simi", "phone", "tel", "telephone", "phonenumber":
            return \.phone
        case "netfang", "email", "epost", "tolvupostur", "emailaddress":
            return \.email
        case "athugasemd", "note", "notes", "comment", "comments", "remark":
            return \.notes
        case "sjalfgefinathugasemdareikningum", "sjalfgefinathugasemd", "defaultinvoicenote", "invoicenote":
            return \.defaultInvoiceNote
        default:
            return nil
        }
    }

    static func isElectronicInvoiceHeader(_ header: String) -> Bool {
        switch normalize(header) {
        case "sendarafraenareikninga", "sendarafraenareikning",
             "rafraenirreikningar", "rafraenreikningur", "rafraennreikningur",
             "rafraenireikningur", "ereikningar", "ereikningur",
             "electronicinvoice", "electronicinvoices", "einvoice", "sendeinvoice":
            return true
        default:
            return false
        }
    }
}

// MARK: - XML delegate

/// Sveigjanlegur XML-lesari: hvert „viðskiptavinur/customer/contact“ stak verður að
/// færslu. Reitir mega koma sem undirstök (`<netfang>…</netfang>`) EÐA sem eigindi
/// (`<customer email="…">`).
private final class CustomerXMLDelegate: NSObject, XMLParserDelegate {
    var records: [CustomerRecord] = []

    private var current: CustomerRecord?
    private var elementBuffer = ""
    private var currentField: WritableKeyPath<CustomerRecord, String>?
    private var currentIsBoolField = false

    private func isCustomerElement(_ name: String) -> Bool {
        let n = Field.normalize(name)
        return ["vidskiptavinur", "customer", "contact", "client", "kunni"].contains(n)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if isCustomerElement(name) {
            var rec = CustomerRecord()
            // Eigindi (attribute-stíll).
            for (key, value) in attributes {
                if let field = Field.string(forHeader: key) {
                    rec[keyPath: field] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if Field.isElectronicInvoiceHeader(key) {
                    rec.sendElectronicInvoices = CustomerImport.parseBool(value)
                }
            }
            current = rec
            currentField = nil
            currentIsBoolField = false
            return
        }
        // Undirstak-reitur innan viðskiptavinar.
        guard current != nil else { return }
        elementBuffer = ""
        currentField = Field.string(forHeader: name)
        currentIsBoolField = Field.isElectronicInvoiceHeader(name)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentField != nil || currentIsBoolField { elementBuffer += string }
    }

    /// <netfang><![CDATA[a@b.is]]></netfang> — annars týnist gildið.
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard currentField != nil || currentIsBoolField else { return }
        elementBuffer += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if isCustomerElement(name) {
            if let rec = current { records.append(rec) }
            current = nil
            currentField = nil
            currentIsBoolField = false
            return
        }
        guard current != nil else { return }
        let text = elementBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let field = currentField {
            current?[keyPath: field] = text
        } else if currentIsBoolField {
            current?.sendElectronicInvoices = CustomerImport.parseBool(text)
        }
        currentField = nil
        currentIsBoolField = false
        elementBuffer = ""
    }
}
