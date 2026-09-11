import Foundation

/// Sendingarákomlag á milli RUKK (Mac) og Bill To Book (iPhone) yfir
/// MultipeerConnectivity. Bygging skilaboða:
///
///   [4 bæti big-endian: lengd hausar][haus sem JSON][gögn (PDF/mynd)]
///
/// Sama snið er útfært í Bill To Book — breytingar þurfa að fara í bæði forrit.
struct RukkEnvelope: Sendable {

    struct Header: Codable, Sendable {
        /// Tegund sendingar — eina gildið í dag er "receipt".
        var kind: String
        /// Heiti fyrirtækis í Bill To Book — parað við fyrirtæki í RUKK eftir nafni.
        var company: String
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
        var length = UInt32(head.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(head)
        out.append(payload)
        return out
    }

    static func decode(_ data: Data) throws -> RukkEnvelope {
        guard data.count >= 4 else { throw EnvelopeError.tooShort }
        let length = Int(data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
        guard length > 0, data.count >= 4 + length else { throw EnvelopeError.tooShort }
        let head = try JSONDecoder().decode(Header.self, from: data[4 ..< 4 + length])
        guard head.kind == "receipt" else { throw EnvelopeError.badHeader }
        return RukkEnvelope(header: head, payload: data.subdata(in: 4 + length ..< data.count))
    }
}
