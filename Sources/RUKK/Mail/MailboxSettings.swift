import Foundation
import Security

/// Stillingar póstvaktar (Kostnaður ← tölvupóstur). Pósthúsfæði og notandanafn
/// í UserDefaults; lykilorð/umbóðskóði í Keychain (aldrei í UserDefaults).
/// Ekki MainActor-útlistað — UserDefaults og Keychain eru þráðaörugg.
@Observable
final class MailboxSettings {

    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.enabled) } }
    var host: String { didSet { defaults.set(host, forKey: Key.host) } }
    var port: Int { didSet { defaults.set(port, forKey: Key.port) } }
    var username: String { didSet { defaults.set(username, forKey: Key.username) } }
    var mailbox: String { didSet { defaults.set(mailbox, forKey: Key.mailbox) } }

    /// Hæsta síða UID sem hefur verið afgreitt — kemur í veg fyrir endurtekningar.
    var lastSeenUID: Int {
        get { defaults.integer(forKey: Key.lastUID) }
        set { defaults.set(newValue, forKey: Key.lastUID) }
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let enabled = "mailWatch.enabled"
        static let host = "mailWatch.host"
        static let port = "mailWatch.port"
        static let username = "mailWatch.username"
        static let mailbox = "mailWatch.mailbox"
        static let lastUID = "mailWatch.lastUID"
    }

    /// True þegar nóg er stillt til að reyna tengingu.
    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && password() != nil
    }

    init() {
        isEnabled = defaults.bool(forKey: Key.enabled)
        host = defaults.string(forKey: Key.host) ?? ""
        port = defaults.integer(forKey: Key.port) == 0 ? 993 : defaults.integer(forKey: Key.port)
        username = defaults.string(forKey: Key.username) ?? ""
        mailbox = defaults.string(forKey: Key.mailbox) ?? "INBOX"
    }

    // MARK: - Keychain

    private var service: String { "is.calmail.kula.imap" }
    private var account: String { "\(username)@\(host)" }

    func password() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String) {
        let data = Data(password.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)   // einfalt: skrifa alltaf yfir
        var attrs = base
        attrs[kSecValueData as String] = data
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
