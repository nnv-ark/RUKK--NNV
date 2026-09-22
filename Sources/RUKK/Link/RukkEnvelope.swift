import Foundation

/// Sendingarsnið milli RUKK (Mac) og Bill To Book (iPhone) yfir
/// MultipeerConnectivity. Rammi hvers skeytis:
///
///   [4 bæti big-endian: lengd hausar][haus sem JSON][gögn (PDF/mynd)]
///
/// Sama snið er útfært í Bill To Book — breytingar þurfa að fara í bæði forrit.
/// Útgáfa 2 bætti við staðfestingu til baka (`RukkAck`) og pörun (`RukkPeerInfo`).
enum RukkProtocol {
    /// Hækkar þegar sniðið breytist. Auglýst í `discoveryInfo["version"]` svo
    /// síminn viti hvort þessi Mac svarar staðfestingu (≥ 2).
    /// Útgáfa 3 bætti við FELAG-skránni (`felag.pull` / `felag.publish`).
    static let version = 3

    /// Hlutverkin sem þessi Mac býður — auglýst í `discoveryInfo["roles"]`.
    /// `felag` ber fyrirtækjaskrána fram, `receipts` tekur við kvittunum.
    /// Forrit sem aðeins bera skrána fram (VSKIL, LAUNA, BLIZZ) auglýsa `felag`.
    static let roles = "felag,receipts"
}

/// Rammi utan um öll skeyti: lengdarforskeyti, haus og gögn.
enum RukkFrame {

    enum FrameError: Error { case tooShort }

    static func pack(header: Data, payload: Data) -> Data {
        var length = UInt32(header.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(header)
        out.append(payload)
        return out
    }

    /// Klýfur ramma í haus og gögn. `loadUnaligned` því bætin koma beint úr
    /// netinu og eru ekki tryggilega á fjögurra bæta mörkum; hlutarnir eru
    /// afritaðir svo þeir byrji í núlli óháð upphafsvísi `Data`-sneiðar.
    static func unpack(_ data: Data) throws -> (header: Data, payload: Data) {
        guard data.count >= 4 else { throw FrameError.tooShort }
        let length = Int(data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian
        })
        guard length > 0, data.count >= 4 + length else { throw FrameError.tooShort }
        let start = data.startIndex
        let header = Data(data[start + 4 ..< start + 4 + length])
        let payload = Data(data[start + 4 + length ..< data.endIndex])
        return (header, payload)
    }

    /// Les aðeins `kind` úr hausnum svo móttakan viti hvaða skeyti þetta er.
    static func kind(ofHeader header: Data) -> String? {
        struct Probe: Decodable { let kind: String }
        return (try? JSONDecoder().decode(Probe.self, from: header))?.kind
    }
}

/// Kvittun á leið í RUKK.
struct RukkEnvelope: Sendable {

    struct Header: Codable, Sendable {
        /// Tegund sendingar — "receipt".
        var kind: String = "receipt"
        /// Heiti fyrirtækis í Bill To Book — notað þegar kennitölu vantar.
        var company: String
        /// Kennitala fyrirtækisins úr FELAG-skránni (snið 3). Þegar hún fylgir
        /// parar RUKK nákvæmlega í stað þess að bera saman nöfn.
        var kennitala: String? = nil
        /// Kvittunarnúmer úr teljara Bill To Book.
        var receiptNumber: Int
        /// Dagsetning skanns, yyyy-MM-dd.
        var date: String
        /// MIME-gerð gagna: "application/pdf" eða "image/jpeg".
        var mime: String
        var fileName: String
    }

    let header: Header
    let payload: Data

    enum EnvelopeError: Error {
        case tooShort
        case badHeader
    }

    func encoded() throws -> Data {
        let head = try JSONEncoder().encode(header)
        return RukkFrame.pack(header: head, payload: payload)
    }

    static func decode(_ data: Data) throws -> RukkEnvelope {
        let frame = try RukkFrame.unpack(data)
        let head = try JSONDecoder().decode(Header.self, from: frame.header)
        guard head.kind == "receipt" else { throw EnvelopeError.badHeader }
        return RukkEnvelope(header: head, payload: frame.payload)
    }
}

/// Staðfesting til baka í símann (útgáfa 2). Bill To Book telur kvittunina
/// ekki senda fyrr en þessi berst — annars fer hún í póstinn eins og áður.
struct RukkAck: Codable, Sendable {

    enum Status: String, Codable, Sendable {
        /// Ný færsla stofnuð.
        case stored
        /// Sama kvittun var þegar til — ekkert nýtt stofnað, sendingin telst komin.
        case duplicate
        /// RUKK gat ekki tekið við (t.d. ekkert virkt fyrirtæki).
        case rejected
    }

    var kind: String = "ack"
    var receiptNumber: Int
    var status: Status
    /// Skýring þegar `status == .rejected`.
    var reason: String?

    func encoded() throws -> Data {
        let head = try JSONEncoder().encode(self)
        return RukkFrame.pack(header: head, payload: Data())
    }

    static func decode(_ data: Data) throws -> RukkAck {
        let frame = try RukkFrame.unpack(data)
        let ack = try JSONDecoder().decode(RukkAck.self, from: frame.header)
        guard ack.kind == "ack" else { throw RukkEnvelope.EnvelopeError.badHeader }
        return ack
    }
}

/// Beiðni símans um fyrirtækjaskrána: „ég á raðnúmer N — áttu nýrra?"
/// Svarað með `RukkFelagPublish` ef sameignin er nýrri, annars engu.
struct RukkFelagPull: Codable, Sendable {

    var kind: String = "felag.pull"
    /// Raðnúmerið sem síminn á fyrir (0 = ekkert).
    var serial: Int

    func encoded() throws -> Data {
        let head = try JSONEncoder().encode(self)
        return RukkFrame.pack(header: head, payload: Data())
    }

    static func decode(_ data: Data) throws -> RukkFelagPull {
        let frame = try RukkFrame.unpack(data)
        let pull = try JSONDecoder().decode(RukkFelagPull.self, from: frame.header)
        guard pull.kind == "felag.pull" else { throw RukkEnvelope.EnvelopeError.badHeader }
        return pull
    }
}

/// Útgáfa fyrirtækjaskrárinnar á leið í símann. Hausinn ber raðnúmerið,
/// gögnin eru `FelagSkeyti` sem JSON — einstefna, síminn svarar engu.
struct RukkFelagPublish: Codable, Sendable {

    var kind: String = "felag.publish"
    var serial: Int

    /// Rammar hausinn utan um skeytið sjálft.
    static func encoded(serial: Int, payload: Data) throws -> Data {
        let head = try JSONEncoder().encode(RukkFelagPublish(serial: serial))
        return RukkFrame.pack(header: head, payload: payload)
    }
}

/// Kynning símans, send með boði um tengingu (`withContext`). RUKK notar hana
/// til að þekkja símann aftur og til að spyrja notandann í fyrsta sinn.
struct RukkPeerInfo: Codable, Sendable {

    var app: String = "billtobook"
    var protocolVersion: Int = RukkProtocol.version
    /// Fast auðkenni símans — helst þótt tækið sé endurnefnt.
    var deviceID: String
    var deviceName: String
    var company: String?

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data) throws -> RukkPeerInfo {
        try JSONDecoder().decode(RukkPeerInfo.self, from: data)
    }

    /// Nafnið sem notandinn sér í pörunarbeiðni: „iPhone · NNV ehf.“
    var label: String {
        if let company, !company.isEmpty { return "\(deviceName) · \(company)" }
        return deviceName
    }
}
