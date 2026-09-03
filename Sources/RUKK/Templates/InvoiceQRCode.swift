import Foundation
import CoreGraphics
import CoreImage

/// Býr til QR-kóða fyrir reikning með númeri, dagsetningu og fjárhæð.
struct InvoiceQRCode {
    /// Dýr í smíðum — reikningssniðið teiknar QR-kóðann upp á nýtt í hverri umferð.
    private static let ciContext = CIContext()

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
            // Án þessa fær íslensk locale þúsundapunkt: 1.234.567.89 er ólæsilegt.
            nf.usesGroupingSeparator = false
            if let amountStr = nf.string(from: amount as NSDecimalNumber) {
                parts.append(amountStr)
            }
        }
        return parts.joined(separator: "|")
    }

    /// Býr til QR-mynd í gefinni stærð (sjálfgefið 100pt) með Core Image.
    func generateCGImage(size: CGFloat = 100) -> CGImage? {
        let data = Data(payload.utf8)

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("H", forKey: "inputCorrectionLevel") // hátt villuleiðrétting

        guard let outputImage = filter?.outputImage else { return nil }

        let scaleX = size / outputImage.extent.size.width
        let scaleY = size / outputImage.extent.size.height
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return Self.ciContext.createCGImage(transformed, from: transformed.extent)
    }
}
