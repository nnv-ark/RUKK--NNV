import Foundation
import AppKit
import PDFKit

/// Myndameðhöndlun kvittana: sýnileika í góðri upplausn án þess að geymslan
/// þrútni. Sama markmið og í Bill To Book (1800 px löng hlið, JPEG ~0.8) —
/// PDF er haldið sem PDF (það er þegar þjappað), myndir eru smækkaðar.
enum ReceiptImage {

    /// Löng hlið í dílum við geymslu og birtingu (sami staur og Bill To Book).
    static let maxLongSide: CGFloat = 1800
    static let jpegQuality: CGFloat = 0.82

    static func isPDF(_ data: Data) -> Bool {
        data.prefix(5) == Data("%PDF-".utf8)
    }

    /// Rétt skráarending eftir innihaldi (fyrir „Opna í Preview").
    static func fileExtension(for data: Data) -> String {
        if isPDF(data) { return "pdf" }
        if data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) { return "jpg" }
        return "png"
    }

    // MARK: - Birting (OCR og skjár)

    /// Hágæða uppdráttur fyrir skjá eða Vision: PDF er rendrað á
    /// `longSide` díla löngu hliðina (thumbnail() gefur of lítið), myndir
    /// eru lesnar beint.
    static func render(_ data: Data, longSide: CGFloat = 2000) -> NSImage? {
        if isPDF(data) { return renderPDF(data, longSide: longSide) }
        return NSImage(data: data)
    }

    /// Rendrar fyrstu síðu PDF í fullri upplausn með CoreGraphics —
    /// `PDFPage.thumbnail` er ætlað lítlum táknum og dregur úr OCR-gæðum.
    static func renderPDF(_ data: Data, longSide: CGFloat) -> NSImage? {
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = longSide / max(bounds.width, bounds.height)
        let pixels = CGSize(width: (bounds.width * scale).rounded(.up),
                            height: (bounds.height * scale).rounded(.up))
        guard let context = CGContext(
            data: nil,
            width: Int(pixels.width), height: Int(pixels.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Hvítur bakgrunnur — gegnsætt PDF ells lendir textinn á svörtu.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixels))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let cgImage = context.makeImage() else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: bounds.width, height: bounds.height))
    }

    // MARK: - Geymsla

    /// Eðlileg geymslumynd: PDF er geymt óbreytt (Bill To Book þjappar þegar),
    /// myndir eru smækkaðar að maxLongSide og kóðaðar sem JPEG — nema þær séu
    /// þegar smárar, þá er óbreytt gildi haldið (óþarfa endurkóðun).
    static func normalized(_ data: Data) -> Data {
        guard !isPDF(data), let image = NSImage(data: data) else { return data }
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return data }
        let longSide = CGFloat(max(cg.width, cg.height))
        guard longSide > maxLongSide else { return data }

        let scale = maxLongSide / longSide
        let target = CGSize(width: (CGFloat(cg.width) * scale).rounded(.up),
                            height: (CGFloat(cg.height) * scale).rounded(.up))
        guard let context = CGContext(
            data: nil,
            width: Int(target.width), height: Int(target.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return data }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: target))
        context.draw(cg, in: CGRect(origin: .zero, size: target))
        guard let resized = context.makeImage() else { return data }

        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return data }
        CGImageDestinationAddImage(destination, resized, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        return out as Data
    }
}
