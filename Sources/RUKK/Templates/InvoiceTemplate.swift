import SwiftUI

/// Velur reikningssnið eftir `invoice.templateName` ("icelandic" sjálfgefið, "universal" valkvætt).
enum InvoiceRenderer {
    @MainActor
    static func view(for invoice: Invoice, settings: AppSettings) -> some View {
        InvoicePage(invoice: invoice, settings: settings, layout: layout(for: invoice))
    }

    @MainActor
    static func layout(for invoice: Invoice) -> InvoiceLayout {
        switch invoice.templateName {
        case "universal": .universal
        default:          .icelandic
        }
    }

    /// Pappírsstærð í punktum (72 dpi) — sameiginleg öllum reikningssniðum,
    /// svo forskoðun geti reiknað mælikvarða án þess að þekkja sniðið.
    static func pageSize(_ paper: String) -> CGSize {
        switch paper {
        case "letter": CGSize(width: 612, height: 792)
        default:       CGSize(width: 595.28, height: 841.89)   // A4
        }
    }
}

// MARK: - Lýsing á reikningssniði

/// Ein lína í gráa borðanum hægra megin (Reikningur nr., Útgáfudagur, …).
struct MetaRow {
    var label: String
    var value: String
    var bold = false
}

/// Einn dálkur í upphæðatöflunni. Breidd, staðsetning og gildi eru gögn, svo
/// sniðin geti verið ólík án þess að teikniforskriftin sé afrituð.
struct ItemColumn {
    var title: String
    /// Önnur línan í haus (t.d. „(án VSK)“). Tveggja lína haus er alltaf hægri-jafnaður.
    var subtitle: String?
    var width: CGFloat?          // nil = tekur það pláss sem eftir er
    var alignment: Alignment = .trailing
    var value: (LineItem, InvoiceStrings) -> String
}

/// Allt sem greinir eitt reikningssnið frá öðru. Uppsetningin sjálf — haus, borði,
/// tafla, samtölur, athugasemd, fótur — er sameiginleg og býr í `InvoicePage`.
struct InvoiceLayout {
    /// Textar reikningsins: íslenska sniðið fylgir `invoiceLanguage`, Universal er alltaf enskt.
    var strings: (AppSettings) -> InvoiceStrings
    /// Reitirnir í gráa borðanum, í réttri röð.
    var metaRows: (Invoice, InvoiceStrings) -> [MetaRow]
    /// Dálkar upphæðatöflunnar, í réttri röð.
    var columns: (InvoiceStrings) -> [ItemColumn]
    /// Lagatilvísun (reglug. nr. 505/2013) í fæti — á aðeins við íslenska reikninga.
    var showsLegalFooter: Bool
}

// MARK: - Reikningssíðan

/// Reikningurinn eins og hann er prentaður: ein blaðsíða, sama uppsetning fyrir öll
/// snið. `layout` ræður tungumáli, reitum borðans, dálkum töflunnar og fætinum.
struct InvoicePage: View {
    let invoice: Invoice
    let settings: AppSettings
    let layout: InvoiceLayout

    private let hPad: CGFloat = 48

    private var page: CGSize { InvoiceRenderer.pageSize(settings.paperSize) }
    private var textColor: Color { Color(hex: settings.textColorHex) ?? .black }
    private var s: InvoiceStrings { layout.strings(settings) }

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

    // MARK: - Haus

    private var topHeader: some View {
        // Merki nær aldrei að miðju A4 (breidd) né gráu línunni (hæð).
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

            qrCode

            Spacer(minLength: 16)
            // Jafnt línubil alla leið — engin stök .padding milli valkvæðra lína,
            // sem gerði bilin misstór eftir því hvaða reitir voru útfylltir.
            VStack(alignment: .trailing, spacing: 4) {
                // Röð: nafn → kt. → heimilisfang+sími → netfang → reikningsnr. → VSK-númer
                Text(settings.companyName).font(font(15, weight: .bold))
                if !settings.companyNationalID.isEmpty {
                    Text(s.idNo(settings.companyNationalID))
                }

                let addrLine = [settings.companyAddress.replacingOccurrences(of: "\n", with: ", "),
                                settings.companyPhone.isEmpty ? nil : s.phone(settings.companyPhone)]
                    .compactMap { ($0?.isEmpty == false) ? $0 : nil }
                    .joined(separator: ", ")
                if !addrLine.isEmpty {
                    Text(addrLine).bold()
                }
                if !settings.companyEmail.isEmpty {
                    Text(settings.companyEmail)
                }
                if !settings.bankAccountNumber.isEmpty {
                    Text(s.bankAccount(settings.bankAccountNumber))
                }
                if !settings.companyVATNumber.isEmpty {
                    Text(s.vatNumber(settings.companyVATNumber))
                }
            }
        }
    }

    @ViewBuilder
    private var qrCode: some View {
        if !invoice.number.isEmpty,
           let cgImage = InvoiceQRCode(invoiceNumber: invoice.number,
                                       date: invoice.issueDate,
                                       amount: invoice.total).generateCGImage(size: 100) {
            Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: 100, height: 100)))
                .resizable()
                .interpolation(.none)
                .frame(width: 100, height: 100)
                .background(Color.white)
        }
    }

    // MARK: - Grái borðinn (móttakandi + reikningsupplýsingar)

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
                ForEach(Array(layout.metaRows(invoice, s).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label).fontWeight(row.bold ? .bold : .regular)
                        Spacer()
                        Text(row.value).fontWeight(row.bold ? .bold : .regular)
                    }
                }
            }
            .frame(width: 260)
        }
    }

    // MARK: - Upphæðatafla

    private var itemsTable: some View {
        let columns = layout.columns(s)
        return VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    header(column).bold()
                }
            }
            .padding(.bottom, 6)

            Divider()

            ForEach(invoice.orderedItems) { item in
                if item.isHeading {
                    // Kaflaskil: heiti verkþáttar yfir línunum sem tilheyra honum.
                    Text(item.itemDescription)
                        .bold()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                            col(column.value(item, s), width: column.width, align: column.alignment)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ column: ItemColumn) -> some View {
        if let subtitle = column.subtitle, let width = column.width {
            VStack(alignment: .trailing, spacing: 0) {
                Text(column.title)
                Text(subtitle)
            }
            .frame(width: width, alignment: .trailing)
        } else {
            col(column.title, width: column.width, align: column.alignment)
        }
    }

    @ViewBuilder
    private func col(_ text: String, width: CGFloat?, align: Alignment) -> some View {
        if let width {
            Text(text).frame(width: width, alignment: align)
        } else {
            Text(text).frame(maxWidth: .infinity, alignment: align)
        }
    }

    // MARK: - Samtölur

    private var totalsRow: some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                tRow(s.subtotalExclVAT, s.currency(invoice.subtotal))
                if invoice.discountValue > 0 {
                    tRow(s.discountLabel(s.amountString(invoice.discountAmount)),
                         "-" + s.currency(invoice.discountValue))
                    tRow(s.taxableBase, s.currency(invoice.taxableBase))
                }
                tRow(s.vat, s.currency(invoice.taxValue))
                tRow(s.totalInclVAT, s.currency(invoice.total), bold: true)
            }
            .frame(width: 260)
        }
    }

    private func tRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).fontWeight(bold ? .bold : .regular)
            Spacer()
            Text(value).fontWeight(bold ? .bold : .regular)
                .monospacedDigit()
        }
    }

    // MARK: - Athugasemd og fótur

    private var notesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.notes).bold()
            Text(invoice.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(alignment: .bottom) {
            // Lagatilvísun á aðeins við íslenska reikninga — ekki tilboð, ekki Universal.
            if layout.showsLegalFooter && !invoice.isEstimate {
                Text(s.footerLegal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text(invoice.isEstimate ? invoice.estimateNumber : invoice.number).bold()
                .font(font(14, weight: .bold))
        }
    }
}
