import Foundation

/// Lágmarks RFC822/MIME-lesari fyrir póstvaktina: hausar, meginmál og
/// viðhengi (PDF/myndir). Nóg fyrir sendingar úr Bill To Book (Mail.app á
/// iPhone sendir multipart/mixed með einu PDF-viðhengi).
struct MIMEMessage: Sendable {

    struct Attachment: Sendable {
        let fileName: String
        let mimeType: String
        let data: Data
    }

    let subject: String
    let bodyText: String
    let attachments: [Attachment]

    static func parse(_ raw: Data) -> MIMEMessage? {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8))
                ?? raw.range(of: Data("\n\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: 0 ..< headerEnd.lowerBound)
        let body = raw.subdata(in: headerEnd.upperBound ..< raw.count)
        let headers = parseHeaders(headerData)

        let contentType = headers["content-type"] ?? "text/plain"
        let subject = decodeWords(headers["subject"] ?? "")

        var parts: [(headers: [String: String], content: Data)] = []
        if contentType.lowercased().hasPrefix("multipart/"),
           let boundary = parameter("boundary", in: contentType) {
            parts = splitMultipart(body, boundary: boundary)
        } else {
            parts = [(headers, body)]
        }

        var attachments: [Attachment] = []
        var bodyText = ""
        for part in parts {
            let type = (part.headers["content-type"] ?? "text/plain").lowercased()
            let disposition = (part.headers["content-disposition"] ?? "").lowercased()
            let encoding = (part.headers["content-transfer-encoding"] ?? "").lowercased()
            let decoded = decodeTransfer(part.content, encoding: encoding)

            let isAttachment = disposition.contains("attachment")
                || type.hasPrefix("application/pdf")
                || type.hasPrefix("image/")
            if isAttachment {
                let name = parameter("filename", in: part.headers["content-disposition"] ?? "")
                    ?? parameter("name", in: part.headers["content-type"] ?? "")
                    ?? "viðhengi"
                attachments.append(Attachment(fileName: decodeWords(name),
                                              mimeType: type.components(separatedBy: ";").first ?? type,
                                              data: decoded))
            } else if type.hasPrefix("text/plain"), bodyText.isEmpty {
                bodyText = String(data: decoded, encoding: .utf8) ?? ""
            }
        }
        return MIMEMessage(subject: subject, bodyText: bodyText, attachments: attachments)
    }

    // MARK: - Úrvinnsla

    /// Hausar sem orðabók (lyklar lágstafaðir). Faldnar línur (whitespace-fylgi) eru liðaðar.
    private static func parseHeaders(_ data: Data) -> [String: String] {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        var headers: [String: String] = [:]
        var currentKey: String?
        for line in text.components(separatedBy: .newlines) where line != "\r" && !line.isEmpty {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let key = currentKey {
                headers[key] = (headers[key] ?? "") + " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[key] = value
                currentKey = key
            }
        }
        return headers
    }

    /// Skiptir multipart-meginmáli á landamærum. Óþarfa krúnulínur færðar frá.
    private static func splitMultipart(_ body: Data, boundary: String) -> [([String: String], Data)] {
        guard let text = String(data: body, encoding: .utf8) else { return [] }
        let delimiter = "--" + boundary
        var parts: [([String: String], Data)] = []
        for chunk in text.components(separatedBy: delimiter) {
            var piece = chunk
            // „\r\n“ er EINN stafaklasi í Swift (count == 1) — removeFirst(1) er rétt.
            while piece.hasPrefix("\r\n") || piece.hasPrefix("\n") || piece.hasPrefix("\r") {
                piece.removeFirst(1)
            }
            if piece.hasSuffix("--") || piece.hasSuffix("--\r\n") { continue }
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = piece.data(using: .utf8),
                  let split = data.range(of: Data("\r\n\r\n".utf8))
                      ?? data.range(of: Data("\n\n".utf8)) else { continue }
            let h = parseHeaders(data.subdata(in: 0 ..< split.lowerBound))
            var content = data.subdata(in: split.upperBound ..< data.count)
            // Lokakryppa á landamærabilinu (trailing CRLF) heyrir ekki hlutnum.
            if content.suffix(2) == Data("\r\n".utf8) { content.removeLast(2) }
            parts.append((h, content))
        }
        return parts
    }

    private static func decodeTransfer(_ data: Data, encoding: String) -> Data {
        if encoding.contains("base64") {
            let cleaned = data.filter { !" \r\n\t".utf8.contains($0) }
            return Data(base64Encoded: cleaned) ?? data
        }
        if encoding.contains("quoted-printable") {
            return decodeQuotedPrintable(data)
        }
        return data
    }

    /// Quoted-printable afkóðun á bætastigi (innihald er ASCII með =XX-undankomum).
    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        let eq = UInt8(ascii: "=")
        while i < data.endIndex {
            if data[i] == eq, i + 1 < data.endIndex {
                let n1 = data[i + 1]
                if n1 == UInt8(ascii: "\r") || n1 == UInt8(ascii: "\n") {
                    // Mjúk línuskipting — sleppt.
                    i += (n1 == UInt8(ascii: "\r") && i + 2 < data.endIndex
                          && data[i + 2] == UInt8(ascii: "\n")) ? 3 : 2
                    continue
                }
                if i + 2 < data.endIndex,
                   let byte = UInt8(String(decoding: data[(i + 1) ... (i + 2)], as: UTF8.self), radix: 16) {
                    out.append(contentsOf: [byte])
                    i += 3
                    continue
                }
            }
            out.append(contentsOf: [data[i]])
            i += 1
        }
        return out
    }

    /// viðureignar í hausum: =?UTF-8?B?...?= eða =?UTF-8?Q?...?=
    private static func decodeWords(_ s: String) -> String {
        guard s.contains("=?") else { return s.trimmingCharacters(in: .whitespaces) }
        var result = s
        let pattern = #"=\?([^?]+)\?([BQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return s }
        let matches = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
        for m in matches {
            guard let full = Range(m.range, in: s),
                  let encRange = Range(m.range(at: 2), in: s),
                  let bodyRange = Range(m.range(at: 3), in: s) else { continue }
            let enc = s[encRange].uppercased()
            let body = String(s[bodyRange])
            let decoded: String?
            if enc == "B" {
                decoded = Data(base64Encoded: body).flatMap { String(data: $0, encoding: .utf8) }
            } else {
                let qp = body.replacingOccurrences(of: "_", with: " ")
                decoded = String(data: decodeQuotedPrintable(Data(qp.utf8)), encoding: .utf8)
            }
            if let decoded { result.replaceSubrange(full, with: decoded) }
        }
        return result
    }

    /// Les gildi stika úr hauslínu, t.d. boundary="..." úr Content-Type.
    private static func parameter(_ name: String, in header: String) -> String? {
        let pattern = "\(name)=\"?([^\";]+)\"?"
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let r = Range(m.range(at: 1), in: header) else { return nil }
        return String(header[r]).trimmingCharacters(in: .whitespaces)
    }
}
