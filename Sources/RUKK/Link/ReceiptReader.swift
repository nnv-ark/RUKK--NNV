import Foundation
import Vision
import AppKit

/// Les texta af kvittunarmyndum með Vision (on-device, engin netþjónusta).
/// Tekur PDF (fyrsta síða er teiknuð upp) eða myndgögn (PNG/JPEG) beint.
enum ReceiptReader {

    /// OCR á gögnum — skilar textalínum í lestrarröð. Tómt ef ekkert lesist.
    static func textLines(from data: Data) async -> [String] {
        // Sameiginlegur rendrarinn (ReceiptImage) sér um PDF í fullri upplausn —
        // PDFPage.thumbnail gaf of lítla mynd og draga úr OCR-gæðum.
        guard let nsImage = ReceiptImage.render(data),
              let image = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
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
}
