import Foundation
import SwiftData

@Model
final class LineItem {
    var itemDescription: String = ""
    var quantity: Decimal = 1
    var unitPrice: Decimal = 0             // verð án VSK
    var taxRate: Decimal = 24              // VSK% fyrir þessa línu
    var order: Int = 0
    /// Fyrirsagnarlína: ber aðeins texta (t.d. heiti verkþáttar) og telur ekki með
    /// í neinum upphæðum. Skiptir reikningnum í kafla.
    var isHeading: Bool = false

    var invoice: Invoice?

    var subtotal: Decimal { quantity * unitPrice }                          // án VSK
    var taxAmount: Decimal { subtotal * taxRate / 100 }
    var subtotalIncTax: Decimal { subtotal + taxAmount }                    // með VSK
    var unitPriceIncTax: Decimal { unitPrice + unitPrice * taxRate / 100 }

    init(description: String = "", quantity: Decimal = 1, unitPrice: Decimal = 0,
         taxRate: Decimal = 24, order: Int = 0, isHeading: Bool = false) {
        self.itemDescription = description
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.taxRate = taxRate
        self.order = order
        self.isHeading = isHeading
    }

    /// Fyrirsögn sem skiptir reikningnum í kafla — engin upphæð, enginn VSK.
    static func heading(_ title: String, order: Int) -> LineItem {
        LineItem(description: title, quantity: 0, unitPrice: 0, taxRate: 0,
                 order: order, isHeading: true)
    }
}
