import Foundation
import AppKit
import os

private let batchLog = Logger(subsystem: "is.calmail.kula", category: "batch")

/// Flytur út marga reikninga í einu (PDF + XML) í valda möppu.
@MainActor
enum BatchExporter {

    enum Format { case pdf, xml, both }

    static func exportAll(_ all: [Invoice], company: AppSettings, format: Format = .both) {
        // Tilboð eru ekki lagaleg skjöl — sleppa þeim í magnútflutningi.
        let invoices = all.filter { !$0.isEstimate }
        guard !invoices.isEmpty else { NSSound.beep(); return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Flytja út")
        panel.message = "\(String(localized: "Veldu möppu fyrir reikningsskrár")) (\(invoices.count) \(String(localized: "reikningar")))"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var written = 0
        var failed = 0

        for invoice in invoices {
            let issuer = invoice.issuer ?? company
            let base = safeName(for: invoice)

            if format == .pdf || format == .both {
                if let data = PDFRenderer.pdfData(invoice: invoice, settings: issuer) {
                    if write(data, to: dir.appendingPathComponent("\(base).pdf")) { written += 1 } else { failed += 1 }
                } else {
                    failed += 1
                }
            }
            if format == .xml || format == .both {
                let xml = UBLInvoiceExporter.xml(for: invoice, company: issuer)
                if let data = xml.data(using: .utf8),
                   write(data, to: dir.appendingPathComponent("\(base).xml")) { written += 1 } else { failed += 1 }
            }
        }

        showSummary(written: written, failed: failed, folder: dir)
    }

    // MARK: - Helpers

    private static func safeName(for invoice: Invoice) -> String {
        let raw = invoice.number.isEmpty ? "reikningur" : invoice.number
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw.components(separatedBy: invalid).joined(separator: "-")
    }

    private static func write(_ data: Data, to url: URL) -> Bool {
        do {
            try data.write(to: url)
            return true
        } catch {
            batchLog.error("Failed to write \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }

    private static func showSummary(written: Int, failed: Int, folder: URL) {
        let alert = NSAlert()
        alert.alertStyle = failed == 0 ? .informational : .warning
        alert.messageText = failed == 0
            ? String(localized: "Útflutningur tókst")
            : String(localized: "Útflutningi lokið með villum")
        var info = "\(String(localized: "Skrifaðar skrár:")) \(written)"
        if failed > 0 { info += "\n\(String(localized: "Mistókust:")) \(failed)" }
        alert.informativeText = info
        alert.addButton(withTitle: String(localized: "Opna möppu"))
        alert.addButton(withTitle: String(localized: "Í lagi"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(folder)
        }
    }
}
