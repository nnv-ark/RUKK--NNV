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
                let observations = (request.results as? [VNRecognizedTextObservation] ?? [])
                let pairs: [(rect: CGRect, text: String)] = observations.compactMap {
                    guard let text = $0.topCandidates(1).first?.string else { return nil }
                    return ($0.boundingBox, text)
                }
                continuation.resume(returning: joinRows(pairs))
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

    /// Sameinar textabúti sem standa á sömu sjónröð. Kvittanir eru
    /// dálkaskipt skjöl („VSK 11%" | „1.432" | „158") og Vision skilar
    /// hverjum dálki sem sér línu — án þessa fengi parserinn aldrei
    /// heila sundurliðunarlínuna. Raðað er efst-upp-frá (Vision: y=0 er
    /// neðst), bútar með næstum sama lóðrétta miðpunkti fara í sömu röð
    /// og raðast síðan vinstri-hægri.
    static func joinRows(_ pairs: [(rect: CGRect, text: String)]) -> [String] {
        let sorted = pairs.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[(rect: CGRect, text: String)]] = []
        for pair in sorted {
            if let ref = rows.last?.first,
               abs(ref.rect.midY - pair.rect.midY) < max(ref.rect.height, pair.rect.height) * 0.6 {
                rows[rows.count - 1].append(pair)
            } else {
                rows.append([pair])
            }
        }
        return rows.map { row in
            row.sorted { $0.rect.minX < $1.rect.minX }
               .map(\.text)
               .joined(separator: " ")
        }
    }
}
