import SwiftUI

/// Velur reikningssnið eftir `invoice.templateName` ("icelandic" sjálfgefið, "universal" valkvætt).
enum InvoiceRenderer {
    /// Reikningurinn eins og hann prentast — ein eða fleiri blaðsíður.
    @MainActor
    static func pages(for invoice: Invoice, settings: AppSettings) -> [InvoicePage] {
        let layout = layout(for: invoice)
        let split = InvoicePagination.split(invoice: invoice, settings: settings, layout: layout)
        return split.enumerated().map { index, items in
            InvoicePage(invoice: invoice, settings: settings, layout: layout,
                        items: items, pageIndex: index, pageCount: split.count)
        }
    }

    /// Fyrsta blaðsíðan — þar sem aðeins ein sýn kemst að.
    @MainActor
    static func view(for invoice: Invoice, settings: AppSettings) -> some View {
        pages(for: invoice, settings: settings)[0]
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
    /// Línurnar sem eiga heima á þessari blaðsíðu.
    var items: [LineItem]
    var pageIndex = 0
    var pageCount = 1

    fileprivate static let hPad: CGFloat = 48
    private var hPad: CGFloat { Self.hPad }

    private var isFirstPage: Bool { pageIndex == 0 }
    private var isLastPage: Bool { pageIndex == pageCount - 1 }

    init(invoice: Invoice, settings: AppSettings, layout: InvoiceLayout,
         items: [LineItem]? = nil, pageIndex: Int = 0, pageCount: Int = 1) {
        self.invoice = invoice
        self.settings = settings
        self.layout = layout
        self.items = items ?? invoice.orderedItems
        self.pageIndex = pageIndex
        self.pageCount = pageCount
    }

    private var page: CGSize { InvoiceRenderer.pageSize(settings.paperSize) }
    private var textColor: Color { Color(hex: settings.textColorHex) ?? .black }
    private var s: InvoiceStrings { layout.strings(settings) }

    /// Grunnletur síðunnar. Mælingar verða að nota það líka — annars mælast
    /// línurnar í sjálfgefnu kerfisletri og margfalt of háar.
    fileprivate var baseFont: Font { font(settings.baseFontSize) }

    private func font(_ size: Double, weight: Font.Weight = .regular) -> Font {
        if settings.fontName.isEmpty {
            .system(size: size, weight: weight)
        } else {
            .custom(settings.fontName, fixedSize: size).weight(weight)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isFirstPage {
                topHeader
                    .padding(.horizontal, hPad)
                    .padding(.top, 36)
                    .padding(.bottom, 18)

                Divider()

                metaBanner
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 18)
                    .background(Color(white: 0.93))
            } else {
                timeReportHeader
                    .padding(.horizontal, hPad)
                    .padding(.top, 30)
                    .padding(.bottom, 12)

                Divider()
            }

            itemsTable
                .padding(.horizontal, hPad)
                .padding(.top, 24)

            if isFirstPage {
                totalsRow
                    .padding(.horizontal, hPad)
                    .padding(.top, 12)

                if !invoice.note.isEmpty {
                    notesView
                        .padding(.horizontal, hPad)
                        .padding(.top, 28)
                }
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

    /// Haus tímaskýrslunnar: titill og nóg til að lausblað þekkist.
    fileprivate var timeReportHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.timeReport).font(font(settings.headingFontSize * 0.5, weight: .bold))
            HStack(alignment: .firstTextBaseline) {
                Text(settings.companyName).bold()
                Spacer(minLength: 16)
                Text("\(invoice.isEstimate ? s.estimateNo : s.invoiceNo) \(invoice.isEstimate ? invoice.estimateNumber : invoice.number)")
                Text(s.date(invoice.issueDate))
            }
        }
    }

    // MARK: - Haus

    fileprivate var topHeader: some View {
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

    fileprivate var metaBanner: some View {
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

    @ViewBuilder
    fileprivate var itemsTable: some View {
        if !isFirstPage {
            timeReportTable
        } else if pageCount > 1 {
            // Sundurliðunin komst ekki fyrir: reikningurinn sýnir eina línu og
            // vísar á tímaskýrsluna, en ber áfram samtölur alls reikningsins.
            VStack(spacing: 0) {
                tableHeader
                Divider()
                summaryRow
            }
        } else {
            VStack(spacing: 0) {
                tableHeader
                Divider()
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    fileprivate var tableHeader: some View {
        let columns = layout.columns(s)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                header(column).bold()
            }
        }
        .padding(.bottom, 6)
    }

    /// Eina línan á reikningi sem á sér tímaskýrslu.
    fileprivate var summaryRow: some View {
        let columns = layout.columns(s)
        let rates = Set(invoice.billableItems.map(\.taxRate))
        return HStack(alignment: .top, spacing: 8) {
            ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                let text: String = {
                    switch index {
                    case 0:                    return s.seeTimeReport
                    case columns.count - 2 where columns.count > 4:
                                               return s.currency(invoice.subtotal)
                    case columns.count - 1:    return s.currency(invoice.subtotalIncTaxTotal)
                    default:
                        // VSK-dálkurinn ber hlutfallið þegar allur reikningurinn
                        // er í sama þrepi; annars stendur hann auður.
                        if column.title == s.vat, rates.count == 1, let only = rates.first {
                            return "\(only.formatted())%"
                        }
                        return ""
                    }
                }()
                col(text, width: column.width, align: column.alignment)
            }
        }
        .padding(.vertical, 6)
        .bold()
    }

    /// Tímaskýrslan: aðeins lýsing, tími og upphæð.
    fileprivate var timeReportTable: some View {
        VStack(spacing: 0) {
            timeReportHeaderRow
            Divider()
            ForEach(items) { item in
                timeReportRow(item)
            }
        }
    }

    fileprivate var timeReportHeaderRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(s.itemDescription).frame(maxWidth: .infinity, alignment: .leading)
            Text(s.hours).frame(width: 70, alignment: .trailing)
            Text(s.amount).frame(width: 110, alignment: .trailing)
        }
        .bold()
        .padding(.bottom, 6)
    }

    @ViewBuilder
    fileprivate func timeReportRow(_ item: LineItem) -> some View {
        if item.isHeading {
            Text(item.itemDescription)
                .bold()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 12)
                .padding(.bottom, 2)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Text(item.itemDescription).frame(maxWidth: .infinity, alignment: .leading)
                Text(item.quantity.formatted()).frame(width: 70, alignment: .trailing)
                Text(s.currency(item.subtotal)).frame(width: 110, alignment: .trailing)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    fileprivate func row(_ item: LineItem) -> some View {
        let columns = layout.columns(s)
        Group {
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

    fileprivate var totalsRow: some View {
        // Sömu námunduðu upphæðir og í rafræna reikningnum — PDF og UBL ríma alltaf.
        let totals = EInvoiceTotals(invoice: invoice)
        return HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                tRow(s.subtotalExclVAT, s.currency(totals.lineExtension))
                if totals.allowanceTotal > 0 {
                    tRow(s.discountLabel(s.amountString(invoice.discountAmount)),
                         "-" + s.currency(totals.allowanceTotal))
                    tRow(s.taxableBase, s.currency(totals.taxExclusive))
                }
                tRow(s.vat, s.currency(totals.taxTotal))
                tRow(s.totalInclVAT, s.currency(totals.taxInclusive), bold: true)
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

    fileprivate var notesView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.notes).bold()
            Text(invoice.note)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    fileprivate var footer: some View {
        HStack(alignment: .bottom) {
            // Lagatilvísun á aðeins við íslenska reikninga — ekki tilboð, ekki Universal,
            // og aðeins á fyrstu síðu.
            if layout.showsLegalFooter && !invoice.isEstimate && isFirstPage {
                Text(s.footerLegal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if pageCount > 1 {
                Text(s.pageOf(pageIndex + 1, of: pageCount)).foregroundStyle(.secondary)
            }
            Text(invoice.isEstimate ? invoice.estimateNumber : invoice.number).bold()
                .font(font(14, weight: .bold))
        }
    }
}

// MARK: - Blaðsíðuskipting

/// Skiptir línum reiknings á blaðsíður.
///
/// Kemst sundurliðunin á reikninginn er hann ein blaðsíða eins og áður. Geri hún
/// það ekki verður reikningurinn ein síða með einni línu — „Sjá tímaskýrslu“ —
/// og fullum samtölum, og sundurliðunin fylgir á eftir sem tímaskýrsla með tíma
/// og upphæð. Upphæðin sem greiða skal er þannig alltaf á forsíðunni.
///
/// Hæðirnar eru mældar á raunverulegu sýnunum, í letri reikningsins, frekar en
/// ágiskaðar: lýsingar brjóta sig á mislangar línur og letur og leturstærð eru
/// stillanleg, svo fastar tölur myndu skera reikninga af aftur um leið og
/// eitthvað breyttist.
@MainActor
enum InvoicePagination {

    /// Fyrsta stakið er reikningssíðan (tómt þegar hún vísar á tímaskýrslu),
    /// það sem á eftir kemur eru síður tímaskýrslunnar.
    static func split(invoice: Invoice, settings: AppSettings,
                      layout: InvoiceLayout) -> [[LineItem]] {
        let items = invoice.orderedItems
        let page = InvoiceRenderer.pageSize(settings.paperSize)
        let width = page.width - InvoicePage.hPad * 2

        let sample = InvoicePage(invoice: invoice, settings: settings, layout: layout)
        let font = sample.baseFont

        let footer = height(sample.footer, font: font, width: width)

        // Reikningssíðan: haus + borði + tafla + samtölur (+ athugasemd) + fótur.
        var invoiceChrome = 36 + height(sample.topHeader, font: font, width: width) + 18 + 1
            + 18 + height(sample.metaBanner, font: font, width: width) + 18
            + 24 + height(sample.tableHeader, font: font, width: width) + 6 + 1
            + 12 + height(sample.totalsRow, font: font, width: width)
            + 14 + footer + 14 + 1
        if !invoice.note.isEmpty {
            invoiceChrome += 28 + height(sample.notesView, font: font, width: width)
        }

        // Kemst öll sundurliðunin fyrir? Þá er þetta venjulegur einnar síðu reikningur.
        let rowHeights = items.map { height(sample.row($0), font: font, width: width) }
        if rowHeights.reduce(0, +) <= page.height - invoiceChrome {
            return [items]
        }

        // Annars: reikningur með einni línu, svo tímaskýrsla.
        let reportBudget = page.height
            - (30 + height(sample.timeReportHeader, font: font, width: width) + 12 + 1)
            - (24 + height(sample.timeReportHeaderRow, font: font, width: width) + 6 + 1)
            - (14 + footer + 14 + 1)

        var pages: [[LineItem]] = [[]]          // reikningssíðan sjálf
        var current: [LineItem] = []
        var used: CGFloat = 0

        for item in items {
            let rowHeight = height(sample.timeReportRow(item), font: font, width: width)
            // Lína sem er hærri en heil síða fær sína eigin síðu frekar en að
            // stöðva skiptinguna.
            if !current.isEmpty && used + rowHeight > reportBudget {
                pages.append(current)
                current = []
                used = 0
            }
            current.append(item)
            used += rowHeight
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }

    /// Raunhæð sýnar við gefna breidd, í letri reikningsins.
    private static func height<V: View>(_ view: V, font: Font, width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view.font(font).frame(width: width))
        renderer.scale = 1
        return renderer.nsImage?.size.height ?? 0
    }
}
