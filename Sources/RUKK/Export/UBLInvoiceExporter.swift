import Foundation
import AppKit
import os

private let ublLog = Logger(subsystem: "is.calmail.kula", category: "ubl")

/// Framleiðir UBL 2.1 reikning skv. PEPPOL BIS Billing 3.0 / TS-136 (íslensk CIUS).
/// Native Swift, engin ytri söfn. Skilar XML-streng og getur vistað um NSSavePanel.
@MainActor
enum UBLInvoiceExporter {

    // PEPPOL BIS Billing 3.0 auðkenni (TS-136 byggir á þessu).
    private static let customizationID =
        "urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0"
    private static let profileID = "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

    /// PEPPOL EAS-kóði fyrir íslenska kennitölu / fyrirtækjaskrá.
    private static let icelandScheme = "0196"

    // MARK: - Public API

    static func xml(for invoice: Invoice, company: AppSettings) -> String {
        var b = XMLBuilder()
        b.line(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        b.open("Invoice", attrs: [
            "xmlns": "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2",
            "xmlns:cac": "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2",
            "xmlns:cbc": "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
        ])

        b.el("cbc:CustomizationID", customizationID)
        b.el("cbc:ProfileID", profileID)
        b.el("cbc:ID", invoice.number)
        b.el("cbc:IssueDate", isoDate(invoice.issueDate))
        if let due = invoice.dueDate { b.el("cbc:DueDate", isoDate(due)) }
        b.el("cbc:InvoiceTypeCode", invoice.isCreditNote ? "381" : "380")   // 380 = reikningur, 381 = kreditreikningur
        if !invoice.note.isEmpty { b.el("cbc:Note", invoice.note) }
        b.el("cbc:DocumentCurrencyCode", invoice.currencyCode)

        // Tilvísun í upprunalega reikninginn sem kreditreikningur leiðréttir.
        if invoice.isCreditNote && !invoice.creditedInvoiceNumber.isEmpty {
            b.open("cac:BillingReference")
            b.open("cac:InvoiceDocumentReference")
            b.el("cbc:ID", invoice.creditedInvoiceNumber)
            b.close("cac:InvoiceDocumentReference")
            b.close("cac:BillingReference")
        }

        supplierParty(&b, company)
        customerParty(&b, invoice.recipient)
        paymentMeans(&b, company, invoice)
        documentAllowances(&b, invoice)
        taxTotal(&b, invoice)
        monetaryTotal(&b, invoice)
        invoiceLines(&b, invoice)

        b.close("Invoice")
        return b.text
    }

    static func export(invoice: Invoice, company: AppSettings) {
        // UBL / TS-136 á aðeins við lagalega reikninga — aldrei tilboð.
        guard !invoice.isEstimate else { NSSound.beep(); return }
        let content = xml(for: invoice, company: company)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.xml]
        let safeName = invoice.number.isEmpty ? "reikningur" : invoice.number
        panel.nameFieldStringValue = "\(safeName).xml"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ublLog.error("Failed to write UBL XML to \(url, privacy: .public): \(error, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Tókst ekki að vista XML")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: - Parties

    private static func supplierParty(_ b: inout XMLBuilder, _ c: AppSettings) {
        b.open("cac:AccountingSupplierParty")
        b.open("cac:Party")
        if !c.companyNationalID.isEmpty {
            b.el("cbc:EndpointID", c.companyNationalID, attrs: ["schemeID": icelandScheme])
        }
        b.open("cac:PartyName"); b.el("cbc:Name", c.displayName); b.close("cac:PartyName")
        postalAddress(&b, oneLine: c.companyAddress)
        if !c.companyVATNumber.isEmpty {
            b.open("cac:PartyTaxScheme")
            b.el("cbc:CompanyID", c.companyVATNumber)
            b.open("cac:TaxScheme"); b.el("cbc:ID", "VAT"); b.close("cac:TaxScheme")
            b.close("cac:PartyTaxScheme")
        }
        b.open("cac:PartyLegalEntity")
        b.el("cbc:RegistrationName", c.displayName)
        if !c.companyNationalID.isEmpty {
            b.el("cbc:CompanyID", c.companyNationalID, attrs: ["schemeID": icelandScheme])
        }
        b.close("cac:PartyLegalEntity")
        if !c.companyEmail.isEmpty {
            b.open("cac:Contact"); b.el("cbc:ElectronicMail", c.companyEmail); b.close("cac:Contact")
        }
        b.close("cac:Party")
        b.close("cac:AccountingSupplierParty")
    }

    private static func customerParty(_ b: inout XMLBuilder, _ contact: Contact?) {
        b.open("cac:AccountingCustomerParty")
        b.open("cac:Party")
        let name = contact.map { $0.company.isEmpty ? $0.name : $0.company } ?? "Óþekktur"
        if let kt = contact?.nationalID, !kt.isEmpty {
            b.el("cbc:EndpointID", kt, attrs: ["schemeID": icelandScheme])
        }
        b.open("cac:PartyName"); b.el("cbc:Name", name); b.close("cac:PartyName")
        postalAddress(&b, oneLine: contact?.address ?? "")
        b.open("cac:PartyLegalEntity")
        b.el("cbc:RegistrationName", name)
        if let kt = contact?.nationalID, !kt.isEmpty {
            b.el("cbc:CompanyID", kt, attrs: ["schemeID": icelandScheme])
        }
        b.close("cac:PartyLegalEntity")
        b.close("cac:Party")
        b.close("cac:AccountingCustomerParty")
    }

    private static func postalAddress(_ b: inout XMLBuilder, oneLine: String) {
        let clean = oneLine.replacingOccurrences(of: "\n", with: ", ")
        b.open("cac:PostalAddress")
        if !clean.isEmpty { b.el("cbc:StreetName", clean) }
        b.open("cac:Country"); b.el("cbc:IdentificationCode", "IS"); b.close("cac:Country")
        b.close("cac:PostalAddress")
    }

    // MARK: - Payment

    private static func paymentMeans(_ b: inout XMLBuilder, _ c: AppSettings, _ invoice: Invoice) {
        guard !c.bankAccountNumber.isEmpty else { return }
        b.open("cac:PaymentMeans")
        b.el("cbc:PaymentMeansCode", "30")                       // credit transfer
        b.el("cbc:PaymentID", invoice.number)
        b.open("cac:PayeeFinancialAccount")
        b.el("cbc:ID", c.bankAccountNumber)
        b.close("cac:PayeeFinancialAccount")
        b.close("cac:PaymentMeans")
    }

    private static func documentAllowances(_ b: inout XMLBuilder, _ invoice: Invoice) {
        guard invoice.discountAmount != 0 else { return }
        let cur = invoice.currencyCode
        let pct = invoice.discountAmount
        // Eitt document-level AllowanceCharge per VSK-flokk svo skattstofn hvers flokks
        // lækki rétt og heildartölur rími (BR-S-08, BR-CO-13/15 í PEPPOL EN16931).
        for group in invoice.lineNetByRate {
            b.open("cac:AllowanceCharge")
            b.el("cbc:ChargeIndicator", "false")
            b.el("cbc:AllowanceChargeReason", "Afsláttur")
            b.el("cbc:MultiplierFactorNumeric", percent(pct))
            b.el("cbc:Amount", money(group.net * pct / 100), attrs: ["currencyID": cur])
            b.el("cbc:BaseAmount", money(group.net), attrs: ["currencyID": cur])
            taxCategory(&b, rate: group.rate)
            b.close("cac:AllowanceCharge")
        }
    }

    // MARK: - Tax

    private static func taxTotal(_ b: inout XMLBuilder, _ invoice: Invoice) {
        let cur = invoice.currencyCode
        b.open("cac:TaxTotal")
        b.el("cbc:TaxAmount", money(invoice.taxValue), attrs: ["currencyID": cur])
        for group in invoice.vatBreakdown {
            b.open("cac:TaxSubtotal")
            b.el("cbc:TaxableAmount", money(group.base), attrs: ["currencyID": cur])
            b.el("cbc:TaxAmount", money(group.tax), attrs: ["currencyID": cur])
            taxCategory(&b, rate: group.rate)
            b.close("cac:TaxSubtotal")
        }
        b.close("cac:TaxTotal")
    }

    private static func taxCategory(_ b: inout XMLBuilder, rate: Decimal) {
        b.open("cac:TaxCategory")
        b.el("cbc:ID", rate > 0 ? "S" : "Z")                     // S = standard, Z = zero-rated
        b.el("cbc:Percent", percent(rate))
        b.open("cac:TaxScheme"); b.el("cbc:ID", "VAT"); b.close("cac:TaxScheme")
        b.close("cac:TaxCategory")
    }

    // MARK: - Totals

    private static func monetaryTotal(_ b: inout XMLBuilder, _ invoice: Invoice) {
        let cur = invoice.currencyCode
        b.open("cac:LegalMonetaryTotal")
        b.el("cbc:LineExtensionAmount", money(invoice.subtotal), attrs: ["currencyID": cur])
        b.el("cbc:TaxExclusiveAmount", money(invoice.taxableBase), attrs: ["currencyID": cur])
        b.el("cbc:TaxInclusiveAmount", money(invoice.total), attrs: ["currencyID": cur])
        if invoice.discountValue != 0 {
            b.el("cbc:AllowanceTotalAmount", money(invoice.discountValue), attrs: ["currencyID": cur])
        }
        b.el("cbc:PayableAmount", money(invoice.total), attrs: ["currencyID": cur])
        b.close("cac:LegalMonetaryTotal")
    }

    private static func invoiceLines(_ b: inout XMLBuilder, _ invoice: Invoice) {
        let cur = invoice.currencyCode
        // Fyrirsagnir eru útlit, ekki gjaldlínur — þær fara ekki í rafrænan reikning.
        for (idx, item) in invoice.orderedItems.filter({ !$0.isHeading }).enumerated() {
            b.open("cac:InvoiceLine")
            b.el("cbc:ID", "\(idx + 1)")
            b.el("cbc:InvoicedQuantity", quantity(item.quantity), attrs: ["unitCode": "C62"])
            b.el("cbc:LineExtensionAmount", money(item.subtotal), attrs: ["currencyID": cur])
            b.open("cac:Item")
            b.el("cbc:Name", item.itemDescription.isEmpty ? "Vara" : item.itemDescription)
            b.open("cac:ClassifiedTaxCategory")
            b.el("cbc:ID", item.taxRate > 0 ? "S" : "Z")
            b.el("cbc:Percent", percent(item.taxRate))
            b.open("cac:TaxScheme"); b.el("cbc:ID", "VAT"); b.close("cac:TaxScheme")
            b.close("cac:ClassifiedTaxCategory")
            b.close("cac:Item")
            b.open("cac:Price")
            b.el("cbc:PriceAmount", money(item.unitPrice), attrs: ["currencyID": cur])
            b.close("cac:Price")
            b.close("cac:InvoiceLine")
        }
    }

    // MARK: - Formatting

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let qtyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 4
        return f
    }()

    private static func money(_ d: Decimal) -> String {
        decimalFormatter.string(from: d as NSDecimalNumber) ?? "0.00"
    }
    private static func quantity(_ d: Decimal) -> String {
        qtyFormatter.string(from: d as NSDecimalNumber) ?? "0"
    }
    private static func percent(_ d: Decimal) -> String {
        qtyFormatter.string(from: d as NSDecimalNumber) ?? "0"
    }
    private static func isoDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

// MARK: - Lightweight indented XML builder

private struct XMLBuilder {
    private(set) var text = ""
    private var depth = 0

    mutating func line(_ s: String) { text += s + "\n" }

    private var indent: String { String(repeating: "  ", count: depth) }

    private func attrString(_ attrs: [String: String]) -> String {
        guard !attrs.isEmpty else { return "" }
        return attrs.sorted { $0.key < $1.key }
            .map { " \($0.key)=\"\(Self.escape($0.value))\"" }
            .joined()
    }

    mutating func open(_ name: String, attrs: [String: String] = [:]) {
        text += "\(indent)<\(name)\(attrString(attrs))>\n"
        depth += 1
    }

    mutating func close(_ name: String) {
        depth = max(0, depth - 1)
        text += "\(indent)</\(name)>\n"
    }

    /// Single element with text content.
    mutating func el(_ name: String, _ value: String, attrs: [String: String] = [:]) {
        text += "\(indent)<\(name)\(attrString(attrs))>\(Self.escape(value))</\(name)>\n"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
