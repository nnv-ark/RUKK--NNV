import Foundation
import Network
import os

private let imapLog = Logger(subsystem: "is.calmail.kula", category: "imap")

enum IMAPError: LocalizedError {
    case server(String)
    case unexpected(String)

    var errorDescription: String? {
        switch self {
        case .server(let msg): "Póstþjónn svaraði: \(msg)"
        case .unexpected(let msg): "Óvænt svar: \(msg)"
        }
    }
}

/// Lágmarks IMAP4-klient (TLS) fyrir póstvaktina: tengist, skráir inn, les
/// ólesin skilaboð og merkir þau lesin. Nóg fyrir sendingar úr Bill To Book.
actor IMAPClient {

    private var connection: NWConnection?
    private var buffer = Data()
    private var tagNumber = 0

    private let host: String
    private let port: UInt16

    init(host: String, port: UInt16 = 993) {
        self.host = host
        self.port = port
    }

    deinit { connection?.cancel() }

    // MARK: - Opinber aðgerðir

    func connect() async throws {
        let tls = NWParameters(tls: NWProtocolTLS.Options())
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 993
        )
        let connection = NWConnection(to: endpoint, using: tls)
        self.connection = connection
        try await waitUntilReady(connection)
        _ = try await readUntilTaggedOrGreeting()   // "* OK ..." kveðja
    }

    func login(username: String, password: String) async throws {
        let quotedPass = "\"\(password.replacingOccurrences(of: "\"", with: "\\\""))\""
        let lines = try await command("LOGIN \"\(username)\" \(quotedPass)")
        try requireOK(lines)
    }

    func select(mailbox: String) async throws {
        let lines = try await command("SELECT \"\(mailbox)\"")
        try requireOK(lines)
    }

    /// UID-númer ólesinna skilaboða í völdu pósthólfi.
    func searchUnseen() async throws -> [Int] {
        let lines = try await command("UID SEARCH UNSEEN")
        try requireOK(lines)
        for line in lines {
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("* SEARCH") {
                return text.dropFirst("* SEARCH".count)
                    .split(separator: " ")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
        }
        return []
    }

    /// Sækir heil skilaboð (RFC822) án þess að merkja þau lesin (BODY.PEEK).
    func fetchMessage(uid: Int) async throws -> Data {
        let chunks = try await commandCollectingLiterals("UID FETCH \(uid) BODY.PEEK[]")
        try requireOK(chunks.map { $0.line })
        // Skilaboðin sjálf eru bókstafslumpinn (literal) í FETCH-svarinu.
        guard let message = chunks.compactMap(\.literal).first(where: { !$0.isEmpty }) else {
            throw IMAPError.unexpected("engin skilaboð fyrir UID \(uid)")
        }
        return message
    }

    func markSeen(uid: Int) async throws {
        let lines = try await command("UID STORE \(uid) +FLAGS (\\Seen)")
        try requireOK(lines)
    }

    func logout() async {
        if connection != nil { _ = try? await command("LOGOUT") }
        connection?.cancel()
        connection = nil
    }

    // MARK: - Samskipulag

    private struct Chunk {
        let line: Data            // textalína (án bókstafslumpa)
        let literal: Data?        // {n}-bókstafslumpur ef einhver
    }

    @discardableResult
    private func command(_ text: String) async throws -> [Data] {
        try await commandCollectingLiterals(text).map(\.line)
    }

    /// Sendir skipun og les þar til merkt svar (a1 OK/NO/BAD) berst.
    /// Bókstafslumpum ({n} bæti) er safnað með línum sínum.
    private func commandCollectingLiterals(_ text: String) async throws -> [Chunk] {
        guard let connection else { throw IMAPError.unexpected("ekki tengt") }
        tagNumber += 1
        let tag = "a\(tagNumber)"
        connection.send(content: Data("\(tag) \(text)\r\n".utf8), completion: .idempotent)
        var chunks: [Chunk] = []
        while true {
            var line = try await readLine()
            var literal: Data?
            // Lína sem endar á {n} boðar n bæta bókstafslump á næstu línu
            // (IMAP-línur eru ASCII svo texta- og bætalengdir falla saman).
            let text = String(decoding: line, as: UTF8.self)
            if let range = text.range(of: #"\{(\d+)\}$"#, options: .regularExpression),
               let n = Int(text[range].dropLast().dropFirst()) {
                literal = try await readBytes(n)
                line = Data(text.dropLast(text[range].count).utf8)
            }
            chunks.append(Chunk(line: line, literal: literal))
            let prefix = Data("\(tag) ".utf8)
            if line.starts(with: prefix) { break }
        }
        return chunks
    }

    private func readUntilTaggedOrGreeting() async throws -> [Data] {
        var lines: [Data] = []
        while true {
            let line = try await readLine()
            lines.append(line)
            let text = String(decoding: line, as: UTF8.self)
            if text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH") { return lines }
            if text.hasPrefix("* BYE") { throw IMAPError.server(text) }
            if lines.count > 10 { throw IMAPError.unexpected("engin kveðja frá þjóni") }
        }
    }

    private func requireOK(_ lines: [Data]) throws {
        guard let last = lines.last else { throw IMAPError.unexpected("tómt svar") }
        let text = String(decoding: last, as: UTF8.self)
        guard text.contains(" OK") else {
            throw IMAPError.server(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: - Lestur af streymi

    private func readLine() async throws -> Data {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: 0 ..< range.lowerBound)
                buffer.removeSubrange(0 ..< range.upperBound)
                return line
            }
            try await receiveMore()
        }
    }

    private func readBytes(_ n: Int) async throws -> Data {
        while buffer.count < n { try await receiveMore() }
        let out = buffer.prefix(n)
        buffer.removeFirst(n)
        // Eftir literal kemur afgangslína — hún er lesin af readLine() í næstu lotu.
        return out
    }

    private func receiveMore() async throws {
        guard let connection else { throw IMAPError.unexpected("ekki tengt") }
        let data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error); return }
                if isComplete && data == nil {
                    cont.resume(throwing: IMAPError.server("þjónn lokaði tengingu"))
                    return
                }
                cont.resume(returning: data)
            }
        }
        guard let data, !data.isEmpty else { throw IMAPError.server("þjónn lokaði tengingu") }
        buffer.append(data)
    }

    private func waitUntilReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                case .waiting(let error):
                    connection.stateUpdateHandler = nil
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}
