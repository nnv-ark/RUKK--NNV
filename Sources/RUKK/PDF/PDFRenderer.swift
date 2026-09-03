import SwiftUI
import AppKit
import PDFKit
import os

private let pdfLog = Logger(subsystem: "is.calmail.kula", category: "pdf")

@MainActor
enum PDFRenderer {

    /// PDF-gögn reikningsins með völdu sniðmáti.
    static func pdfData(invoice: Invoice, settings: AppSettings) -> Data? {
        data(from: InvoiceRenderer.view(for: invoice, settings: settings))
    }

    // MARK: - Page Setup / Print / Preview

    /// Native Page Setup gluggi (NSPrintInfo.shared er notað í prentun).
    static func pageSetup() {
        let layout = NSPageLayout()
        layout.runModal(with: NSPrintInfo.shared)
    }

    /// Prentar reikninginn um native prentglugga.
    static func printInvoice(invoice: Invoice, settings: AppSettings) {
        guard let data = pdfData(invoice: invoice, settings: settings),
              let doc = PDFDocument(data: data) else { NSSound.beep(); return }

        // Afrit — annars stæði stillingin eftir í sameiginlegu NSPrintInfo og hefði
        // áhrif á Síðuuppsetningu og næstu prentun.
        let info = NSPrintInfo(dictionary: NSPrintInfo.shared.dictionary() as! [NSPrintInfo.AttributeKey: Any])
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        guard let op = doc.printOperation(for: info, scalingMode: .pageScaleToFit, autoRotate: false) else {
            NSSound.beep(); return
        }
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }

    /// Semur tölvupóst í Mail með PDF reikningsins sem viðhengi (notandi sendir sjálfur).
    static func emailInvoice(invoice: Invoice, settings: AppSettings) {
        guard let data = pdfData(invoice: invoice, settings: settings) else { NSSound.beep(); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(invoice.documentFileName).pdf")
        do {
            try data.write(to: url)
        } catch {
            pdfLog.error("Failed to write PDF for email: \(error, privacy: .public)")
            NSSound.beep(); return
        }

        guard let service = NSSharingService(named: .composeEmail) else {
            NSSound.beep(); return
        }
        // Notar sniðmátið úr Stillingum ({nafn}, {númer}, {fyrirtæki} útfyllt sjálfkrafa).
        // Tilboð fá sérstakan viðfangslínu-texta — þau eru ekki reikningar.
        let fields = settings.emailFields(for: invoice)
        service.subject = invoice.isEstimate
            ? "Tilboð \(invoice.estimateNumber) frá \(settings.displayName)"
            : fields.subject
        if let email = invoice.recipient?.email, !email.isEmpty {
            service.recipients = [email]
        }
        service.perform(withItems: [fields.body, url])
    }

    /// Semur vænlega áminningu í Mail vegna ógreidds, gjaldfallins reiknings — PDF fylgir.
    static func emailReminder(invoice: Invoice, settings: AppSettings) {
        guard let data = pdfData(invoice: invoice, settings: settings) else { NSSound.beep(); return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(invoice.documentFileName).pdf")
        do {
            try data.write(to: url)
        } catch {
            pdfLog.error("Failed to write PDF for reminder: \(error, privacy: .public)")
            NSSound.beep(); return
        }

        guard let service = NSSharingService(named: .composeEmail) else {
            NSSound.beep(); return
        }
        service.subject = "Áminning: Reikningur nr. \(invoice.number) frá \(settings.displayName)"
        if let email = invoice.recipient?.email, !email.isEmpty {
            service.recipients = [email]
        }
        let due = invoice.effectiveFinalDueDate.formatted(date: .numeric, time: .omitted)
        let body = """
        Kæri viðskiptavinur,

        Þetta er vinsamleg áminning vegna reiknings nr. \(invoice.number) sem gjaldféll \(due). Reikningurinn fylgir meðfylgjandi.

        Vinsamlegast hafið samband ef spurningar vakna.

        Kveðja,

        \(settings.displayName)
        """
        service.perform(withItems: [body, url])
    }

    /// Opnar reikninginn í sjálfgefnu PDF-forriti (Preview).
    static func openInPreview(invoice: Invoice, settings: AppSettings) {
        guard let data = pdfData(invoice: invoice, settings: settings) else { NSSound.beep(); return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(invoice.documentFileName).pdf")
        do {
            try data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            pdfLog.error("Failed to open preview: \(error, privacy: .public)")
            NSSound.beep()
        }
    }

    static func data<V: View>(from view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        // ImageRenderer.render's draw closure sets up the PDF coordinate system itself —
        // do NOT add manual translate/scale flips or the page comes out upside-down + mirrored.
        var result: Data?
        renderer.render { size, draw in
            let pageData = NSMutableData()
            guard let consumer = CGDataConsumer(data: pageData) else { return }
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            result = pageData as Data
        }
        return result
    }

    static func export(invoice: Invoice, settings: AppSettings) {
        guard let pdfData = pdfData(invoice: invoice, settings: settings) else {
            NSSound.beep(); return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(invoice.documentFileName).pdf"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try pdfData.write(to: url)
        } catch {
            pdfLog.error("Failed to write PDF to \(url, privacy: .public): \(error, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Tókst ekki að vista PDF")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
