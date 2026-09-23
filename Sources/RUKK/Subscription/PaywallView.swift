import SwiftUI
import StoreKit
import AppKit

/// Áskriftarskjár — sýndur þegar engin virk áskrift er. Lokar á allt appið.
struct PaywallView: View {
    let store: SubscriptionStore
    @State private var isWorking = false
    /// DEBUG-only: sami lykill og RootView les til að sleppa paywall við prófun.
    @AppStorage("debugUnlocked") private var debugUnlocked = false

    /// Útgáfunúmer + útgefandi, til að sýna smátt neðst.
    private var versionLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(String(localized: "Útgáfa")) \(version) (\(build))  ·  © 2026 NNV.ehf"
    }

    /// Merkið kemur beint úr forritinu sjálfu, ekki úr afriti í Assets — þá
    /// fylgir það sjálfkrafa hverri endurnýjun á tákninu og getur ekki orðið
    /// eftir gamalt eins og „Logo" gerði.
    private var merki: Image {
        if let icon = NSApplication.shared.applicationIconImage {
            return Image(nsImage: icon)
        }
        return Image("Logo")
    }

    /// Daufur bleikur stigull — sami húsalitur og glugginn ber.
    private var bakgrunnur: some View {
        LinearGradient(colors: [.rukkBlushTop, .rukkWindow],
                       startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }

    private let features: [(icon: String, text: LocalizedStringKey)] = [
        ("building.2", "Mörg fyrirtæki? Ekkert mál! Auðvelt að skipta á milli — og kostar ekki aukalega."),
        ("chart.bar.xaxis", "Mælaborð: sala, innheimt, útistandandi og greiðsluhraði — meiri upplýsingar á leiðinni."),
        ("arrow.up.doc", "XML-stuðningur og auðvelt að flytja allt út í einu.")
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            merki
                .resizable().scaledToFit()
                .frame(width: 112, height: 112)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            Text("RUKK")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .padding(.top, 14)
            Text("Reikningagerð fyrir íslensk fyrirtæki og verktaka")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(features, id: \.icon) { feature in
                    Label {
                        Text(feature.text)
                    } icon: {
                        Image(systemName: feature.icon)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                    }
                    .font(.body)
                }
            }
            .padding(20)
            .frame(maxWidth: 440, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06))
            )
            .padding(.vertical, 26)

            Spacer(minLength: 12)

            purchaseSection
                .frame(maxWidth: 420)

            Spacer(minLength: 16)

            #if DEBUG
            Button("Halda áfram án áskriftar (DEBUG)") { debugUnlocked = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.bottom, 2)
            #endif

            Text(versionLine)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bakgrunnur)
    }

    @ViewBuilder
    private var purchaseSection: some View {
        if store.isLoading {
            ProgressView().controlSize(.large)
        } else if let product = store.product {
            let trial = store.trialEligible && hasFreeTrial(product)
            buySection(showTrial: trial, disclosure: disclosure(for: product, showTrial: trial))
        } else {
            #if DEBUG
            if Demo.showPaywall {
                buySection(showTrial: true, disclosure: "\(String(localized: "Ókeypis í 1 viku, svo")) 1.490 kr. \(String(localized: "á ári. Endurnýjast sjálfkrafa þar til þú segir upp í App Store. Hægt að segja upp hvenær sem er."))")
            } else {
                errorSection
            }
            #else
            errorSection
            #endif
        }
    }

    private func buySection(showTrial: Bool, disclosure: String) -> some View {
        VStack(spacing: 12) {
            Button {
                Task { isWorking = true; await store.purchase(); isWorking = false }
            } label: {
                VStack(spacing: 2) {
                    Text("KAUPA")
                        .font(.headline)
                    if showTrial {
                        Text("prófa frítt í eina viku")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking)

            Text(disclosure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Button("Endurheimta kaup") { Task { await store.restore() } }
                    .disabled(isWorking)
                Link("Persónuvernd", destination: URL(string: "https://github.com/nnv-ark/kula-invoicing/blob/main/PRIVACY.md")!)
                Link("Skilmálar", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            .font(.caption)
        }
    }

    private var errorSection: some View {
        VStack(spacing: 10) {
            Text("Tókst ekki að sækja áskriftina.")
                .foregroundStyle(.secondary)
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.secondary)
            }
            Button("Reyna aftur") { Task { await store.load() } }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - Texti

    private func disclosure(for product: Product, showTrial: Bool) -> String {
        let price = product.displayPrice
        let perYear = String(localized: "á ári. Endurnýjast sjálfkrafa þar til þú segir upp í App Store. Hægt að segja upp hvenær sem er.")
        if showTrial {
            return "\(String(localized: "Ókeypis í 1 viku, svo")) \(price) \(perYear)"
        }
        return "\(price) \(perYear)"
    }

    private func hasFreeTrial(_ product: Product) -> Bool {
        product.subscription?.introductoryOffer?.paymentMode == .freeTrial
    }
}
