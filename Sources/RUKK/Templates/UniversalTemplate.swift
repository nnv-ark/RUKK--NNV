import SwiftUI

/// Einfalt, alþjóðlegt reikningssnið — alltaf á ensku, óháð `invoiceLanguage`.
/// Sleppir íslensku regluverki (viðskiptanúmer, bókunardagur, eindagi, lagatilvísun)
/// og sýnir eina einingaverðs- og eina upphæðardálk í stað beggja án/með VSK.
extension InvoiceLayout {
    @MainActor
    static let universal = InvoiceLayout(
        strings: { _ in InvoiceStrings(.english) },

        metaRows: { invoice, s in
            if invoice.isEstimate {
                return [
                    MetaRow(label: s.estimateNo, value: invoice.estimateNumber, bold: true),
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
                MetaRow(label: s.issueDate, value: s.date(invoice.issueDate)),
                MetaRow(label: s.dueDate, value: s.date(invoice.dueDate ?? invoice.issueDate)),
            ]
            if !invoice.collectionMethod.isEmpty {
                rows.append(MetaRow(label: s.collectionMethod, value: invoice.collectionMethod))
            }
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
                ItemColumn(title: s.unitPrice, subtitle: nil, width: 80) { item, s in
                    s.amountString(item.unitPrice)
                },
                ItemColumn(title: s.vat, subtitle: nil, width: 40) { item, _ in
                    "\(item.taxRate.formatted())%"
                },
                ItemColumn(title: s.amount, subtitle: nil, width: 90) { item, s in
                    s.currency(item.subtotal)
                },
            ]
        },

        showsLegalFooter: false)
}
