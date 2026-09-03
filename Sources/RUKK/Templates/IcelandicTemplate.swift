import SwiftUI

/// Íslenskt reikningssnið skv. reglugerð nr. 505/2013: viðskiptanúmer, bókunardagur,
/// eindagi og lagatilvísun í fæti, og upphæðir bæði án og með VSK.
/// Uppsetningin sjálf er í `InvoicePage` — hér er aðeins það sem sniðinu er sérstakt.
extension InvoiceLayout {
    @MainActor
    static let icelandic = InvoiceLayout(
        // Fylgir reikningsmáli fyrirtækisins, óháð viðmótsmáli.
        strings: { InvoiceStrings(.from($0.invoiceLanguage)) },

        metaRows: { invoice, s in
            if invoice.isEstimate {
                // Tilboð: eigið T-númer og gildistími — engir gjalddagar né eindagar.
                return [
                    MetaRow(label: s.estimateNo, value: invoice.estimateNumber, bold: true),
                    MetaRow(label: s.customerNo, value: invoice.recipient?.nationalID ?? ""),
                    MetaRow(label: s.issueDate, value: s.date(invoice.issueDate)),
                    MetaRow(label: s.validUntil, value: s.date(invoice.validUntil)),
                ]
            }
            var rows = [MetaRow(label: invoice.isCreditNote ? s.creditNoteNo : s.invoiceNo,
                                value: invoice.number, bold: true)]
            if invoice.isCreditNote && !invoice.creditedInvoiceNumber.isEmpty {
                rows.append(MetaRow(label: s.creditReason, value: invoice.creditedInvoiceNumber))
            }
            rows += [
                MetaRow(label: s.customerNo, value: invoice.recipient?.nationalID ?? ""),
                MetaRow(label: s.issueDate, value: s.date(invoice.issueDate)),
                MetaRow(label: s.bookingDate, value: s.date(invoice.bookingDate ?? invoice.issueDate)),
                MetaRow(label: s.dueDate, value: s.date(invoice.dueDate ?? invoice.issueDate)),
                MetaRow(label: s.finalDueDate, value: s.date(invoice.effectiveFinalDueDate)),
                MetaRow(label: s.collectionMethod, value: invoice.collectionMethod),
            ]
            return rows
        },

        columns: { s in
            [
                ItemColumn(title: s.itemDescription, subtitle: nil, width: nil, alignment: .leading) { item, _ in
                    item.itemDescription
                },
                ItemColumn(title: s.quantity, subtitle: nil, width: 50) { item, _ in
                    item.quantity.formatted()
                },
                ItemColumn(title: s.amount, subtitle: s.exclVAT, width: 60) { item, s in
                    s.amountString(item.unitPrice)
                },
                ItemColumn(title: s.amount, subtitle: s.inclVAT, width: 60) { item, s in
                    s.amountString(item.unitPriceIncTax)
                },
                ItemColumn(title: s.vat, subtitle: nil, width: 40) { item, _ in
                    "\(item.taxRate.formatted())%"
                },
                ItemColumn(title: s.total, subtitle: s.exclVAT, width: 75) { item, s in
                    s.currency(item.subtotal)
                },
                ItemColumn(title: s.total, subtitle: s.inclVAT, width: 75) { item, s in
                    s.currency(item.subtotalIncTax)
                },
            ]
        },

        showsLegalFooter: true)
}
