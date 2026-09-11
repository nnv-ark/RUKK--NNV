import Foundation
import MultipeerConnectivity
import SwiftData
import SystemConfiguration
import os

private let linkLog = Logger(subsystem: "is.calmail.kula", category: "link")

/// Bein tenging RUKK ↔ Bill To Book án pósts og án nets: RUKK auglýsir sig á
/// staðarnetinu (Bonjour) og Bill To Book í símanum finnur Macinn sjálfkrafa.
/// Skannar berast dulkritaðir beint milli tækjanna.
@Observable
@MainActor
final class RukkLinkService: NSObject {

    /// Bonjour-þjónustutegund — sömu streng notar Bill To Book við leit.
    /// (Lágstafir, ≤ 15 stafir — kröfur MC-rammans.)
    static let serviceType = "rukk-link"

    /// Nafn tengds síma (nil = enginn tengdur). Sýnt í Kostnaðar-hausnum.
    private(set) var connectedPeerName: String?
    /// Síðasta færsla sem barst í gegnum tenginguna — ContentView fylgist með
    /// og færir valið á hana.
    private(set) var latestExpense: Expense?
    private(set) var lastError: String?

    private let container: ModelContainer
    private var myPeerID: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?
    /// Kallað á aðalþræði — skilar virku fyrirtæki sem færslur falla á.
    private nonisolated let activeCompanyProvider: @MainActor () -> AppSettings?

    nonisolated init(container: ModelContainer, activeCompany: @escaping @MainActor () -> AppSettings?) {
        self.container = container
        self.activeCompanyProvider = activeCompany
        super.init()
    }

    /// Nafn Macsins eins og Bill To Book sýnir það („RUKK · <nafn>"). Í sandbox
    /// gefur Host.current().localizedName nafnlausan tilfallastreng — ComputerName
    /// úr SystemConfiguration er raunverulega heitið sem notandinn þekkir.
    private static func macName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty {
            return name
        }
        return ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "RUKK"
    }

    /// Hefur auglýsingu á staðarnetinu. Kallað við ræsingu — öruggt að kalla aftur.
    func start() {
        guard advertiser == nil else { return }
        let peerID = MCPeerID(displayName: Self.macName())
        myPeerID = peerID
        let session = MCSession(peer: peerID, securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["app": "rukk", "version": "1"],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser
        linkLog.info("RukkLink: advertising as \(peerID.displayName, privacy: .public)")
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        connectedPeerName = nil
    }

    // MARK: - Móttaka

    /// Kallað á aðalþræði með fulla sendingu úr Bill To Book.
    private func handleReceived(_ data: Data) {
        do {
            let envelope = try RukkEnvelope.decode(data)
            guard let company = activeCompanyProvider() else {
                linkLog.error("RukkLink: ekkert virkt fyrirtæki — sendingu hafnað")
                return
            }
            let context = container.mainContext
            let date = DateFormatter.rukkDay.date(from: envelope.header.date)
            let expense = ExpenseIntake.intake(
                receipt: envelope.payload,
                source: .billToBook,
                companyName: envelope.header.company,
                receiptNumber: envelope.header.receiptNumber,
                date: date,
                in: context,
                fallbackCompany: company
            )
            try? context.save()
            latestExpense = expense
            linkLog.info("RukkLink: kvittun #\(envelope.header.receiptNumber) móttekin (\(envelope.payload.count) bæti)")
        } catch {
            lastError = error.localizedDescription
            linkLog.error("RukkLink: ógild sending — \(error.localizedDescription, privacy: .public)")
        }
    }
}

private extension DateFormatter {
    static let rukkDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// Brú fyrir Objective-C endikalla sem ekki eru Sendable-merkt í SDK-inu.
/// Öruggt hér: MC-skýmerramminn keyrir þá samrunalaust og við köllum aðeins
/// þau einu sinni, á aðalþræði.
private struct UnsafeSendable<T>: @unchecked Sendable { let value: T }

// MARK: - MultipeerConnectivity (bakgrunnsþráður)

extension RukkLinkService: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Persónuleg tenging milli eigin tækja — boðum er svarað já.
        let handler = UnsafeSendable(value: invitationHandler)
        Task { @MainActor in
            handler.value(true, self.session)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
            self.advertiser = nil
        }
    }
}

extension RukkLinkService: MCSessionDelegate {

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID,
                             didChange state: MCSessionState) {
        let name = peerID.displayName   // String er Sendable — lesið fyrir hoppið
        Task { @MainActor in
            switch state {
            case .connected:    self.connectedPeerName = name
            case .notConnected: self.connectedPeerName = nil
            case .connecting:   break
            @unknown default:   break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data,
                             fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            self.handleReceived(data)
        }
    }

    // Straumar, auðlindir og vottorð eru ónotuð — sendingar fara sem Data.
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?,
                             fromPeer peerID: MCPeerID,
                             certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}
