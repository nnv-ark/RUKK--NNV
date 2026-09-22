import Foundation
import FyrirtaekiKit
import MultipeerConnectivity
import SwiftData
import SystemConfiguration
import os

private let linkLog = Logger(subsystem: "is.calmail.kula", category: "link")

/// Bein tenging RUKK ↔ Bill To Book án pósts og án nets: RUKK auglýsir sig á
/// staðarnetinu (Bonjour) og Bill To Book í símanum finnur Macinn sjálfkrafa.
/// Skannar berast dulkóðaðir beint milli tækjanna.
///
/// Sími þarf pörun: fyrsta boð frá óþekktu tæki bíður svars notandans og
/// auðkennið er munað eftir það. Hver móttekin kvittun fær staðfestingu til
/// baka svo síminn viti hvort hún komst — og geti fallið í póstinn ef ekki.
@Observable
@MainActor
final class RukkLinkService: NSObject {

    /// Bonjour-þjónustutegund — sama streng notar Bill To Book við leit.
    /// (Lágstafir, ≤ 15 stafir — kröfur MC-rammans.)
    static let serviceType = "rukk-link"

    /// Beiðni frá síma sem ekki hefur verið parað við áður.
    struct PairingRequest: Identifiable, Sendable {
        let id = UUID()
        let deviceID: String
        let label: String
    }

    /// Nafn tengds síma (nil = enginn tengdur). Sýnt í Kostnaðar-hausnum.
    private(set) var connectedPeerName: String?
    /// Síðasta færsla sem barst í gegnum tenginguna — ContentView fylgist með
    /// og færir valið á hana.
    private(set) var latestExpense: Expense?
    private(set) var lastError: String?
    /// Óafgreidd pörunarbeiðni — ContentView birtir staðfestingarglugga.
    private(set) var pendingRequest: PairingRequest?
    /// Paraðir símar: auðkenni → nafnið eins og það var þegar parað var.
    /// Lesið úr UserDefaults þegar `start()` keyrir.
    private(set) var pairedDevices: [String: String] = [:]

    private let container: ModelContainer
    private var myPeerID: MCPeerID?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var session: MCSession?
    /// Svarhak boðsins sem bíður notandans.
    private var pendingHandler: ((Bool, MCSession?) -> Void)?
    /// Kallað á aðalþræði — skilar virku fyrirtæki sem færslur falla á.
    private nonisolated let activeCompanyProvider: @MainActor () -> AppSettings?

    private static let pairedKey = "link.pairedDevices"

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
        pairedDevices = UserDefaults.standard.dictionary(forKey: Self.pairedKey) as? [String: String] ?? [:]
        guard advertiser == nil else { return }
        let peerID = MCPeerID(displayName: Self.macName())
        myPeerID = peerID
        let session = MCSession(peer: peerID, securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: ["app": "rukk",
                            "version": String(RukkProtocol.version),
                            "roles": RukkProtocol.roles],
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
        denyPendingRequest()
    }

    // MARK: - Pörun

    /// Boð frá síma: þekkt tæki fær já strax, óþekkt bíður notandans.
    private func handleInvitation(from peerName: String, info: RukkPeerInfo?,
                                  handler: @escaping (Bool, MCSession?) -> Void) {
        guard let session else {
            handler(false, nil)
            return
        }
        // Eldri sími sendir enga kynningu — nafnið verður þá auðkennið.
        let deviceID = info?.deviceID ?? peerName
        if pairedDevices[deviceID] != nil {
            handler(true, session)
            linkLog.info("RukkLink: þekkt tæki tengist (\(peerName, privacy: .public))")
            return
        }
        guard pendingRequest == nil else {
            // Ein beiðni í einu — hinni er hafnað og síminn má reyna aftur.
            handler(false, nil)
            return
        }
        pendingHandler = handler
        pendingRequest = PairingRequest(deviceID: deviceID, label: info?.label ?? peerName)
        linkLog.info("RukkLink: pörunarbeiðni frá \(peerName, privacy: .public)")
    }

    /// Notandinn samþykkti beiðnina — tækið er munað héðan í frá.
    func approvePendingRequest() {
        guard let request = pendingRequest, let handler = pendingHandler else { return }
        pairedDevices[request.deviceID] = request.label
        UserDefaults.standard.set(pairedDevices, forKey: Self.pairedKey)
        pendingRequest = nil
        pendingHandler = nil
        handler(true, session)
    }

    /// Notandinn hafnaði — eða glugganum var lokað.
    func denyPendingRequest() {
        guard let handler = pendingHandler else {
            pendingRequest = nil
            return
        }
        pendingRequest = nil
        pendingHandler = nil
        handler(false, nil)
    }

    /// Gleymir öllum pöruðum símum og byrjar upp á nýtt — næsta boð spyr aftur.
    func forgetPairings() {
        pairedDevices = [:]
        UserDefaults.standard.removeObject(forKey: Self.pairedKey)
        stop()
        start()
    }

    // MARK: - Móttaka

    /// Kallað á aðalþræði með fulla sendingu úr Bill To Book.
    private func handleReceived(_ data: Data, from peer: MCPeerID) {
        do {
            let frame = try RukkFrame.unpack(data)
            switch RukkFrame.kind(ofHeader: frame.header) {
            case "receipt":
                break
            case "felag.pull":
                let pull = try JSONDecoder().decode(RukkFelagPull.self, from: frame.header)
                sendFelag(nyrraEn: pull.serial, to: peer)
                return
            default:
                // Staðfestingar berast aðeins í hina áttina; annað er hunsað.
                return
            }
            let header = try JSONDecoder().decode(RukkEnvelope.Header.self, from: frame.header)
            let envelope = RukkEnvelope(header: header, payload: frame.payload)
            let number = envelope.header.receiptNumber
            guard let company = activeCompanyProvider() else {
                linkLog.error("RukkLink: ekkert virkt fyrirtæki — sendingu hafnað")
                lastError = String(localized: "Kvittun barst en ekkert fyrirtæki er virkt.")
                send(RukkAck(receiptNumber: number, status: .rejected,
                             reason: "no-active-company"), to: peer)
                return
            }
            let context = container.mainContext
            let date = DateFormatter.rukkDay.date(from: envelope.header.date)
            let result = ExpenseIntake.intake(
                receipt: envelope.payload,
                source: .billToBook,
                companyName: envelope.header.company,
                kennitala: envelope.header.kennitala,
                receiptNumber: number,
                date: date,
                in: context,
                fallbackCompany: company
            )
            try? context.save()
            if result.isDuplicate {
                linkLog.info("RukkLink: kvittun #\(number) barst aftur — sama færsla stendur")
            } else {
                latestExpense = result.expense
                linkLog.info("RukkLink: kvittun #\(number) móttekin (\(envelope.payload.count) bæti)")
            }
            send(RukkAck(receiptNumber: number,
                         status: result.isDuplicate ? .duplicate : .stored), to: peer)
        } catch {
            lastError = error.localizedDescription
            linkLog.error("RukkLink: ógild sending — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fyrirtækjaskráin úr sameigninni, ef hún er nýrri en sú sem síminn á.
    /// RUKK ritstýrir henni ekki — FELAG gerir það — heldur ber hana aðeins
    /// fram, svo FELAG þurfi ekki að vera í gangi.
    private func sendFelag(nyrraEn serial: Int, to peer: MCPeerID) {
        guard let session, session.connectedPeers.contains(peer) else { return }
        guard let skeyti = FelagUtgefandi.skeyti(nyrraEn: serial) else {
            linkLog.info("RukkLink: FELAG-skráin er óbreytt (raðnúmer \(serial)) — ekkert sent")
            return
        }
        do {
            let gogn = try RukkFelagPublish.encoded(serial: skeyti.serial,
                                                    payload: try skeyti.jsonEncoded())
            try session.send(gogn, toPeers: [peer], with: .reliable)
            linkLog.info("RukkLink: FELAG-skrá send (raðnúmer \(skeyti.serial), \(skeyti.companies.count) fyrirtæki)")
        } catch {
            linkLog.error("RukkLink: FELAG-skrá komst ekki til skila — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Staðfesting til baka á símann sem sendi.
    private func send(_ ack: RukkAck, to peer: MCPeerID) {
        guard let session, session.connectedPeers.contains(peer) else { return }
        do {
            let data = try ack.encoded()
            try session.send(data, toPeers: [peer], with: .reliable)
        } catch {
            linkLog.error("RukkLink: staðfesting komst ekki til skila — \(error.localizedDescription, privacy: .public)")
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
/// Öruggt hér: MC-ramminn keyrir þá samrunalaust og við köllum aðeins
/// þau einu sinni, á aðalþræði.
private struct UnsafeSendable<T>: @unchecked Sendable { let value: T }

// MARK: - MultipeerConnectivity (bakgrunnsþráður)

extension RukkLinkService: MCNearbyServiceAdvertiserDelegate {

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Kynning símans fylgir boðinu (útgáfa 2). Eldri sími sendir ekkert.
        let info = context.flatMap { try? RukkPeerInfo.decode($0) }
        let name = peerID.displayName
        let handler = UnsafeSendable(value: invitationHandler)
        Task { @MainActor in
            self.handleInvitation(from: name, info: info, handler: handler.value)
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
        let peer = UnsafeSendable(value: peerID)
        Task { @MainActor in
            self.handleReceived(data, from: peer.value)
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
