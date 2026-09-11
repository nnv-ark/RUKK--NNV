import Foundation
import SwiftData
import os

private let watchLog = Logger(subsystem: "is.calmail.kula", category: "mailwatch")

/// Póstvakt: les vaktaða tölvupóstfang með IMAP og breytir viðhengdum
/// kvittunum (PDF/myndir) í kostnaðarfærslur. Svipað og payday.is — Bill To
/// Book sendir skannið í pósti á fangið og RUKK sækir það sjálfkrafa.
@Observable
@MainActor
final class ExpenseMailWatcher {

    enum State: Equatable {
        case idle
        case checking
        case ok(String)          // síðasta niðurstaða, t.d. „1 kvittun sótt"
        case failed(String)

        /// Stutt stöðulýsing fyrir hjálpartexta hnapps.
        var helpText: String {
            switch self {
            case .idle: String(localized: "Sækja ólesnar kvittanir af póstfangi")
            case .checking: String(localized: "Sæki póst…")
            case .ok(let msg): msg
            case .failed(let msg): String(localized: "Villa: \(msg)")
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    let settings = MailboxSettings()
    private var pollTask: Task<Void, Never>?

    nonisolated init() {}
    /// Regluleg athugun á ~3 mínútna fresti á meðan appið er opið.
    func startPolling(context: ModelContext, activeCompany: @escaping () -> AppSettings?) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.settings.isEnabled && self.settings.isConfigured {
                    await self.checkNow(context: context, activeCompany: activeCompany)
                }
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    func stopPolling() { pollTask?.cancel(); pollTask = nil }

    /// Sækir ólesin skilaboð strax („Sækja póst" hnappur / regluleg vakt).
    func checkNow(context: ModelContext, activeCompany: () -> AppSettings?) async {
        guard state != .checking else { return }
        guard settings.isConfigured else {
            watchLog.warning("Póstvakt: ekki stillt (host/username/lykilorð vantar) — sleppi")
            state = .failed(String(localized: "Póstvakt er ekki stillt — sjá Stillingar → Póstvakt."))
            return
        }
        state = .checking
        watchLog.info("Póstvakt: sæki ólesin skilaboð af \(self.settings.host, privacy: .public)/\(self.settings.mailbox, privacy: .public)")
        defer { lastChecked = .now }
        do {
            let fetched = try await fetchUnseen(context: context, activeCompany: activeCompany)
            watchLog.info("Póstvakt: \(fetched) kvittun sótt")
            state = .ok(fetched == 0
                        ? String(localized: "Engin ný kvittun")
                        : String(localized: "\(fetched) kvittun sótt"))
        } catch {
            watchLog.error("Póstvakt mistókst: \(error.localizedDescription, privacy: .public)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Innri ferlið

    private func fetchUnseen(context: ModelContext,
                             activeCompany: () -> AppSettings?) async throws -> Int {
        guard let password = settings.password() else {
            throw IMAPError.unexpected("lykilorð vantar")
        }
        let client = IMAPClient(host: settings.host, port: UInt16(settings.port))
        try await client.connect()
        try await client.login(username: settings.username, password: password)
        try await client.select(mailbox: settings.mailbox)
        defer { Task { await client.logout() } }

        let uids = try await client.searchUnseen().filter { $0 > settings.lastSeenUID }
        var fetched = 0
        for uid in uids {
            guard let company = activeCompany() else { break }
            let raw = try await client.fetchMessage(uid: uid)
            if let message = MIMEMessage.parse(raw),
               let attachment = message.attachments.first(where: {
                   $0.mimeType == "application/pdf" || $0.mimeType.hasPrefix("image/")
               }) {
                // Sending úr Bill To Book: fyrirsögn „Receipt #0012 · 2026-09-11“ og
                // meginmál með „Company: …“. Aðrir póstar fá fyrirsögn sem athugasemd.
                let meta = BillToBookMeta(from: message)
                ExpenseIntake.intake(
                    receipt: attachment.data,
                    source: meta.isBillToBook ? .billToBook : .manual,
                    companyName: meta.company,
                    receiptNumber: meta.receiptNumber,
                    date: meta.date,
                    note: meta.isBillToBook ? "" : String(localized: "Úr tölvupósti: \(message.subject)"),
                    in: context,
                    fallbackCompany: company
                )
                fetched += 1
            }
            try await client.markSeen(uid: uid)
            settings.lastSeenUID = max(settings.lastSeenUID, uid)
        }
        if fetched > 0 { try? context.save() }
        return fetched
    }
}

/// Lýsigögn úr pósti frá Bill To Book (fyrirsögn + meginmál).
private struct BillToBookMeta {
    let isBillToBook: Bool
    let company: String?
    let receiptNumber: Int?
    let date: Date?

    init(from message: MIMEMessage) {
        isBillToBook = message.bodyText.contains("Made with Bill To Book")
            || message.subject.hasPrefix("Receipt #")
        company = Self.field("Company", in: message.bodyText)
        receiptNumber = Self.field("Receipt", in: message.bodyText)
            .flatMap { Int($0.replacingOccurrences(of: "#", with: "")) }
        date = Self.field("Date", in: message.bodyText).flatMap {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: $0)
        }
    }

    /// Les „Lykil:  gildi“ línu úr meginmáli.
    private static func field(_ key: String, in body: String) -> String? {
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            let value = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
