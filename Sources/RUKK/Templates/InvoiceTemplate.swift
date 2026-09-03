import SwiftUI

/// Velur reikningssnið eftir `invoice.templateName` ("icelandic" sjálfgefið, "universal" valkvætt).
enum InvoiceRenderer {
    @MainActor @ViewBuilder
    static func view(for invoice: Invoice, settings: AppSettings) -> some View {
        switch invoice.templateName {
        case "universal": UniversalTemplate(invoice: invoice, settings: settings)
        default: IcelandicTemplate(invoice: invoice, settings: settings)
        }
    }

    /// Pappírsstærð í punktum (72 dpi) — sameiginleg öllum reikningssniðum,
    /// svo forskoðun geti reiknað mælikvarða án þess að þekkja sniðið.
    static func pageSize(_ paper: String) -> CGSize {
        switch paper {
        case "letter": CGSize(width: 612, height: 792)
        default:       CGSize(width: 595.28, height: 841.89)   // A4
        }
    }
}
