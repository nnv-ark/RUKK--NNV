import SwiftUI

struct IcelandicTemplate: View {
    let invoice: Invoice
    let settings: AppSettings

    private let hPad: CGFloat = 48

    /// Pappírsstærð í punktum (72 dpi).
    static func pageSize(_ paper: String) -> CGSize {
        switch paper {
        case "letter": CGSize(width: 612, height: 792)
        default:       CGSize(width: 595.28, height: 841.89)   // A4
        }
    }

    private var page: CGSize { Self.pageSize(settings.paperSize) }
    private var textColor: Color { Color(hex: settings.textColorHex) ?? .black }

    /// Textar reikningsins á völdu reikningsmáli (óháð viðmótsmáli).
    private var s: InvoiceStrings { InvoiceStrings(.from(settings.invoiceLanguage)) }

    private func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        if settings.fontName.isEmpty {
            .system(size: size, weight: weight)
        } else {
            .custom(settings.fontName, fixedSize: size).weight(weight)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topHeader
                .padding(.horizontal, hPad)
                .padding(.top, 36)
                .padding(.bottom, 18)

            Divider()

            metaBanner
                .padding(.horizontal, hPad)
                .padding(.vertical, 18)
                .background(Color(white: 0.93))

            itemsTable
                .padding(.horizontal, hPad)
                .padding(.top, 24)

            totalsRow
                .padding(.horizontal, hPad)
                .padding(.top, 12)

            if !invoice.note.isEmpty {
                notesView
                    .padding(.horizontal, hPad)
                    .padding(.top, 28)
            }

            Spacer(minLength: 0)

            Divider()
            footer
                .padding(.horizontal, hPad)
                .padding(.vertical, 14)
        }
        .frame(width: page.width, height: page.height, alignment: .top)
        .background(.white)
        .foregroundStyle(textColor)
        .font(font(settings.baseFontSize))
    }

    // MARK: - Top header

    private var topHeader: some View {
        // Merki nær aldrei að miðju A4 (breidd) né gráu línunni (hæð) — stærri grunnur en áður.
        let maxLogoW = min(200 * settings.logoScale, page.width / 2 - hPad - 24)
        let maxLogoH = min(90 * settings.logoScale, 120)
        return HStack(alignment: .top) {
            if let data = settings.logoData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable().scaledToFit()
                    .frame(maxWidth: maxLogoW, maxHeight: maxLogoH, alignment: .topLeading)
            } else {
                Text(settings.companyName.isEmpty ? s.companyPlaceholder : settings.companyName.uppercased())
                    .font(font(settings.headingFontSize, weight: .black))
            }
            Spacer(minLength: 16)

            // QR-kóði fyrir reikning (miðjusvæðið)
            if !invoice.number.isEmpty,
               let qrCGImage = InvoiceQRCode(
                   invoiceNumber: invoice.number,
                   date: invoice.issueDate,
                   amount: invoice.total
               ).generateCGImage(size: 100) {
                Image(nsImage: NSImage(cgImage: qrCGImage, size: NSSize(width: 100, height: 100)))
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 100, height: 100)
                    .background(Color.white)
            }

            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                // Röð skv. mynd: nafn → kt. → heimilisfang+sími → netfang → reikningsnr. → VSK-númer
                Text(settings.companyName).font(font(15, weight: .bold))
                if !settings.companyNationalID.isEmpty {
                    Text(s.idNo(settings.companyNationalID))
                }

                let addrLine = [settings.companyAddress.replacingOccurrences(of: "\n", with: ", "),
                                settings.companyPhone.isEmpty ? nil : s.phone(settings.companyPhone)]
                    .compactMap { ($0?.isEmpty == false) ? $0 : nil }
                    .joined(separator: ", ")
                if !addrLine.isEmpty {
                    Text(addrLine).bold().padding(.top, 6)
                }
                if !settings.companyEmail.isEmpty {
                    Text(settings.companyEmail).padding(.top, 6)
                }
                if !settings.bankAccountNumber.isEmpty {
                    Text(s.bankAccount(settings.bankAccountNumber)).padding(.top, 6)
                }
                if !settings.companyVATNumber.isEmpty {
                    Text(s.vatNumber(settings.companyVATNumber))
                }
            }
        }
    }

    // MARK: - Meta banner (recipient + invoice meta)

    private var metaBanner: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                if let r = invoice.recipient {
                    Text(r.company.isEmpty ? r.name : r.company)
                    Text(r.address)
                    if !r.nationalID.isEmpty { Text(s.idNo(r.nationalID)) }
                }
            }
            Spacer(minLength: 80)
            VStack(alignment: .leading, spacing: 3) {
                if invoice.isEstimate {
                    // Tilboð: eigið T-númer og gildistími — engir gjalddagar/eindagar.
                    metaRow(s.estimateNo, invoice.estimateNumber, boldLabel: true)
                    metaRow(s.customerNo, invoice.recipient?.nationalID ?? "")
                    metaRow(s.issueDate, date(invoice.issueDate))
                    metaRow(s.validUntil, date(invoice.validUntil))
                } else {
                    metaRow(invoice.isCreditNote ? s.creditNoteNo : s.invoiceNo, invoice.number, boldLabel: true)
                    if invoice.isCreditNote && !invoice.creditedInvoiceNumber.isEmpty {
                        metaRow(s.creditReason, invoice.creditedInvoiceNumber)
                    }
                    metaRow(s.customerNo, invoice.recipient?.nationalID ?? "")
                    metaRow(s.issueDate, date(invoice.issueDate))
                    metaRow(s.bookingDate, date(invoice.bookingDate ?? invoice.issueDate))
                    metaRow(s.dueDate, date(invoice.dueDate ?? invoice.issueDate))
                    metaRow(s.finalDueDate, date(invoice.effectiveFinalDueDate))
                    metaRow(s.collectionMethod, invoice.collectionMethod)
                }
            }
            .frame(width: 260)
        }
    }

    private func metaRow(_ label: String, _ value: String, boldLabel: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).fontWeight(boldLabel ? .bold : .regular)
            Spacer()
            Text(value).fontWeight(boldLabel ? .bold : .regular)
        }
    }

    private func date(_ d: Date) -> String { s.date(d) }

    // MARK: - Items table

    private var itemsTable: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                col(s.itemDescription, width: nil, align: .leading).bold()
                col(s.quantity, width: 50, align: .trailing).bold()
                colTwoLine(s.amount, s.exclVAT, width: 60).bold()
                colTwoLine(s.amount, s.inclVAT, width: 60).bold()
                col(s.vat, width: 40, align: .trailing).bold()
                colTwoLine(s.total, s.exclVAT, width: 75).bold()
                colTwoLine(s.total, s.inclVAT, width: 75).bold()
            }
            .padding(.bottom, 6)

            Divider()

            ForEach(invoice.orderedItems) { item in
                HStack(alignment: .top, spacing: 8) {
                    col(item.itemDescription, width: nil, align: .leading)
                    col(item.quantity.formatted(), width: 50, align: .trailing)
                    col(amount(item.unitPrice), width: 60, align: .trailing)
                    col(amount(item.unitPriceIncTax), width: 60, align: .trailing)
                    col("\(item.taxRate.formatted())%", width: 40, align: .trailing)
                    col(currency(item.subtotal), width: 75, align: .trailing)
                    col(currency(item.subtotalIncTax), width: 75, align: .trailing)
                }
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func col(_ text: String, width: CGFloat?, align: Alignment) -> some View {
        if let w = width {
            Text(text).frame(width: w, alignment: align)
        } else {
            Text(text).frame(maxWidth: .infinity, alignment: align)
        }
    }

    private func colTwoLine(_ a: String, _ b: String, width: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(a)
            Text(b)
        }
        .frame(width: width, alignment: .trailing)
    }

    // MARK: - Totals

    private var totalsRow: some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                tRow(s.subtotalExclVAT, currency(invoice.subtotal))
                if invoice.discountValue > 0 {
                    tRow(discountLabel, "-" + currency(invoice.discountValue))
                    tRow(s.taxableBase, currency(invoice.taxableBase))
                }
                tRow(s.vat, currency(invoice.taxValue))
                tRow(s.totalInclVAT, currency(invoice.total), bold: true)
            }
            .frame(width: 260)
        }
    }

    private var discountLabel: String {
        s.discountLabel(amount(invoice.discountAmount))
    }

    private func tRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(bold ? .bold : .regular)
            Spacer()
            Text(value).fontWeight(bold ? .bold : .regular)
                .monospacedDigit()
        }
    }

    // MARK: - Notes

    private var notesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.notes).bold()
            Text(invoice.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom) {
            if !invoice.isEstimate {
                // Lagatilvísun (505/2013) á aðeins við reikninga — ekki tilboð.
                Text(s.footerLegal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text(invoice.isEstimate ? invoice.estimateNumber : invoice.number).bold()
                .font(font(14, weight: .bold))
        }
    }

    // MARK: - Formatting

    private func amount(_ d: Decimal) -> String { s.amountString(d) }

    private func currency(_ d: Decimal) -> String { s.currency(d) }
}
