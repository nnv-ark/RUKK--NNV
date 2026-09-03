import SwiftUI
import UniformTypeIdentifiers

// Dráttur og sleppa. Gerðirnar sem færast milli staða í RUKK — og út úr því — eiga
// heima hér, svo sýnirnar sjálfar innihaldi aðeins það sem þær teikna.

extension UTType {
    /// Innanhússgerð: ein reikningslína á leið á nýjan stað í sama reikningi.
    /// Skráð í Info.plist (UTExportedTypeDeclarations).
    static let rukkLineItem = UTType(exportedAs: "is.calmail.kula.lineitem")

    /// `.rukktime` — tímafærslur sendar úr BLIZZ.
    static let rukkTime = UTType(exportedAs: "is.calmail.kula.rukktime")

    /// Skráargerðir sem innflutningur viðskiptavina ræður við.
    static var customerListTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .xml]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        return types
    }
}

/// Reikningslína sem verið er að draga til. Aðeins staðan í listanum flyst —
/// línan sjálf er þegar í minni, svo ekkert þarf að afrita.
struct LineItemDrag: Codable, Transferable {
    let index: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .rukkLineItem)
    }
}

/// Reikningur á leið út úr RUKK sem PDF — í Finder, Mail eða hvað sem tekur við skrám.
/// PDF-ið er teiknað þegar dráttur hefst, ekki þegar listinn er teiknaður.
struct InvoicePDFDrag: Transferable {
    let fileName: String
    let data: Data

    @MainActor
    init(invoice: Invoice, settings: AppSettings) {
        fileName = invoice.documentFileName + ".pdf"
        data = PDFRenderer.pdfData(invoice: invoice, settings: settings) ?? Data()
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { $0.data }
            .suggestedFileName { $0.fileName }
    }
}

// MARK: - Hjálp við að taka á móti skrám

enum DroppedFile {
    /// Er slóðin skrá sem innflutningur viðskiptavina ræður við?
    static func isCustomerList(_ url: URL) -> Bool {
        ["xlsx", "csv", "tsv", "xml", "txt"].contains(url.pathExtension.lowercased())
    }

    /// Tyme-útflutningur (JSON) eða BLIZZ-sending (.rukktime)?
    static func isTimeExport(_ url: URL) -> Bool {
        ["json", "rukktime"].contains(url.pathExtension.lowercased())
    }

    static func isImage(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif", "tiff", "heic", "pdf", "svg"].contains(url.pathExtension.lowercased())
    }

    /// Les skrá sem notandi sleppti. Sleppt skjal fær sandkassaaðgang, en aðeins
    /// meðan hún er sótt — því er hún lesin strax.
    static func data(at url: URL) -> Data? {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
    }
}
