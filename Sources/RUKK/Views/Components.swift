import SwiftUI
import Charts

// Sameiginlegir byggingarhlutar viðmótsins. Áður voru þeir afritaðir milli
// mælaborðsins, viðskiptavinaspjaldsins og reikningalistans.

/// Lykiltala með tákni og fyrirsögn — reiturinn efst á mælaborðunum.
struct KPITile: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            Text(value)
                .font(.title3).bold()
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Kassi með fyrirsögn utan um efnishluta mælaborðsins.
struct Card<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Lítið, litað merki — stöður reikninga og gjalddagar.
struct CapsuleTag: View {
    private let label: Text
    private let color: Color

    /// Þýddur texti (t.d. staða reiknings).
    init(_ title: LocalizedStringKey, color: Color) {
        self.label = Text(title)
        self.color = color
    }

    /// Tilbúinn texti sem á ekki að þýða (t.d. dagsetning).
    init(_ text: String, color: Color) {
        self.label = Text(text)
        self.color = color
    }

    var body: some View {
        label
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Stuttar fjárhæðir á ásum: 1.500.000 → „1,5M“, 12.000 → „12k“.
enum CompactNumber {
    static func string(_ d: Double) -> String {
        if d >= 1_000_000 {
            return "\((d / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
        }
        if d >= 1_000 { return "\(Int(d / 1_000))k" }
        return "\(Int(d))"
    }
}

extension View {
    /// Y-ás með stuttum fjárhæðum — sama útlit á öllum súluritum.
    func compactAmountAxis() -> some View {
        chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Double.self) { Text(CompactNumber.string(d)) }
                }
            }
        }
    }

    /// Verkfærarönd efst í dálki: efni á `.bar`-fleti með skilarönd undir.
    func barHeader(horizontal: CGFloat = 12, vertical: CGFloat = 7) -> some View {
        self
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}
