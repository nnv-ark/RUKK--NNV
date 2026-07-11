import Foundation
import CoreGraphics
import CoreImage

/// Býr til QR-kóða fyrir reikning með númeri, dagsetningu og fjárhæð.
struct InvoiceQRCode {
    let invoiceNumber: String
    let date: Date
    let amount: Decimal?

    /// Format: RUKK|{númer}|{dagsetning}|{fjárhæð}?
    var payload: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let dateString = formatter.string(from: date)

        var parts = ["RUKK", invoiceNumber, dateString]
        if let amount = amount {
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.maximumFractionDigits = 2
            nf.minimumFractionDigits = 2
            nf.decimalSeparator = "."
            if let amountStr = nf.string(from: amount as NSDecimalNumber) {
                parts.append(amountStr)
            }
        }
        return parts.joined(separator: "|")
    }

    /// Býr til QR-mynd í gefinni stærð (sjálfgefið 100pt) með Core Image.
    func generateCGImage(size: CGFloat = 100) -> CGImage? {
        guard let data = payload.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel") // hátt villuleiðrétting

        guard let outputImage = filter?.outputImage else { return nil }

        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        let context = CIContext()
        return context.createCGImage(transformed, from: transformed.extent)
    }
}
