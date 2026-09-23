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

    /// Leggur bleikan blæ á gluggann sjálfan (rönd, titilsvæði og allt sem
    /// innihaldið málar ekki yfir).
    func rukkWindowTint() -> some View { background(WindowTint()) }
}

// MARK: - Bleikur blær

extension Color {
    /// Húsalitur RUKK-gluggans. Daufur með vilja — hann á að sjást í
    /// jaðrinum en ekki keppa við innihaldið. Vilji maður sterkari eða
    /// daufari blæ er það þessi eini staður.
    static let rukkWindow = Color(nsColor: .rukkWindow)
    /// Bakgrunnur áskriftarskjásins efst í stiglinum.
    static let rukkBlushTop = Color(nsColor: .rukkBlushTop)
}

extension NSColor {
    static let rukkWindow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.137, green: 0.106, blue: 0.122, alpha: 1)   // #231B1F
            : NSColor(srgbRed: 0.992, green: 0.961, blue: 0.973, alpha: 1)   // #FDF5F8
    }

    static let rukkBlushTop = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.200, green: 0.137, blue: 0.169, alpha: 1)   // #33232B
            : NSColor(srgbRed: 0.976, green: 0.902, blue: 0.929, alpha: 1)   // #F9E6ED
    }
}

/// Setur litinn beint á NSWindow — SwiftUI-bakgrunnur nær ekki yfir
/// titilröndina, svo glugginn verður annars tvílitur.
private struct WindowTint: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { apply(to: nsView) }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            view.window?.backgroundColor = .rukkWindow
        }
    }
}
