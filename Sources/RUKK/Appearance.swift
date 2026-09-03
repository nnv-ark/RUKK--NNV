import SwiftUI
import AppKit

/// Viðmótsham RUKK. Sjálfgefið fylgir forritið kerfinu, en notandi getur læst
/// því í ljóst eða dökkt óháð stillingum macOS.
enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .system: "Fylgja kerfinu"
        case .light:  "Ljóst"
        case .dark:   "Dökkt"
        }
    }

    /// `nil` = erfa útlit kerfisins.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }

    static func from(_ raw: String) -> AppAppearance { AppAppearance(rawValue: raw) ?? .system }
}

/// Setur útlitið á allt forritið — `NSApp.appearance` nær líka til valmynda,
/// spjalda og Stillingaglugga, sem `preferredColorScheme` gerir ekki á macOS.
private struct AppAppearanceModifier: ViewModifier {
    @AppStorage("appAppearance") private var raw = AppAppearance.system.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear(perform: apply)
            .onChange(of: raw) { _, _ in apply() }
    }

    private func apply() {
        NSApplication.shared.appearance = AppAppearance.from(raw).nsAppearance
    }
}

extension View {
    /// Fylgir valinu í Stillingar → Útlit.
    func appAppearance() -> some View { modifier(AppAppearanceModifier()) }
}
