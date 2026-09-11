import Foundation
import Vision
import AppKit
import PDFKit

/// Les texta af kvittunarmyndum með Vision (on-device, engin netþjónusta).
/// Tekur PDF (fyrsta síða er teiknuð upp) eða myndgögn (PNG/JPEG) beint.
enum ReceiptReader {

    /// OCR á gögnum — skilar textalínum í lestrarröð. Tómt ef ekkert lesist.
    static func textLines(from data: Data) async -> [String] {
        guard let image = firstPageImage(from: data) else { return [] }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["is", "en"]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Myndgögn beint, annars fyrsta síða PDF teiknuð upp í nægri upplausn.
    private static func firstPageImage(from data: Data) -> CGImage? {
        if let image = NSImage(data: data),
           let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           !isPDF(data) {
            return cg
        }
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // ~2000 px á breiddina er nóg fyrir prentaðan kvittunatexta.
        let scale = max(1, 2000 / bounds.width)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let thumb = page.thumbnail(of: size, for: .mediaBox)
        return thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func isPDF(_ data: Data) -> Bool {
        data.prefix(5) == Data("%PDF-".utf8)
    }
}
