import PDFKit
import UIKit

/// Gera PDFs (anotação, recibo e relatórios) a partir de texto formatado, com o cabeçalho e o rodapé de Ajustes.
enum PDFExporter {
    static let pageSize = CGSize(width: 595.2, height: 841.8) // A4 em pontos

    // MARK: - Montagem do texto

    final class Builder {
        let text = NSMutableAttributedString()

        func title(_ s: String) {
            append(s + "\n", font: .systemFont(ofSize: 20, weight: .bold), spacingAfter: 4)
        }

        func subtitle(_ s: String) {
            append(s + "\n", font: .systemFont(ofSize: 11), color: .darkGray, spacingAfter: 12)
        }

        func heading(_ s: String) {
            append(s + "\n", font: .systemFont(ofSize: 14, weight: .semibold), spacingBefore: 12, spacingAfter: 4)
        }

        func paragraph(_ s: String, font: UIFont = .systemFont(ofSize: 12), color: UIColor = .black) {
            append(s + "\n", font: font, color: color, spacingAfter: 6)
        }

        func rich(_ rich: RichText) {
            let body = NSMutableAttributedString(attributedString: RichTextCodec.forPrinting(RichTextCodec.decode(rich)))
            // Ajusta o tamanho da letra da tela (17) para o papel (12), mantendo as proporções.
            let range = NSRange(location: 0, length: body.length)
            body.enumerateAttribute(.font, in: range) { value, sub, _ in
                let f = (value as? UIFont) ?? .systemFont(ofSize: RichTextCodec.baseFontSize)
                body.addAttribute(.font, value: f.withSize(max(8, f.pointSize * 12 / RichTextCodec.baseFontSize)), range: sub)
            }
            text.append(body)
            text.append(NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 12)]))
        }

        func line(_ label: String, _ value: String) {
            let m = NSMutableAttributedString(string: label + ": ", attributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.black])
            m.append(NSAttributedString(string: value + "\n", attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black]))
            text.append(m)
        }

        func spacer() { append("\n", font: .systemFont(ofSize: 6)) }

        private func append(_ s: String, font: UIFont, color: UIColor = .black, spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0) {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = spacingAfter
            text.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]))
        }
    }

    // MARK: - Renderização

    /// Cabeçalho e rodapé de Ajustes › Cabeçalho e rodapé (imagem do timbre e texto).
    struct Letterhead {
        var headerImage: UIImage?
        var headerHeightMm: Double = 22
        var headerText = ""
        var footerImage: UIImage?
        var footerHeightMm: Double = 22
        var footerText = ""

        static let none = Letterhead()
        static func mm(_ v: Double) -> CGFloat { CGFloat(v / 25.4 * 72) }
    }

    @MainActor
    static func letterhead(_ store: Store) -> Letterhead {
        let l = store.db.settings.documentLayout
        return Letterhead(headerImage: store.documentImage(l.header).flatMap(UIImage.init(data:)), headerHeightMm: l.header.imageHeightMm,
                          headerText: l.header.text, footerImage: store.documentImage(l.footer).flatMap(UIImage.init(data:)),
                          footerHeightMm: l.footer.imageHeightMm, footerText: l.footer.text)
    }

    static func render(_ text: NSAttributedString, footer: String, letterhead: Letterhead = .none) -> Data {
        let paper = CGRect(origin: .zero, size: pageSize)
        let headerTextAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray]
        let footerAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.gray]
        let headerText = letterhead.headerText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let footerText = letterhead.footerText.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let contentWidth = paper.width - 112
        let headerTextHeight = headerText.length == 0 ? 0 : ceil(headerText.boundingRect(with: CGSize(width: contentWidth, height: 200),
            options: .usesLineFragmentOrigin, attributes: headerTextAttrs, context: nil).height) + 6
        let footerTextHeight = footerText.length == 0 ? 0 : ceil(footerText.boundingRect(with: CGSize(width: contentWidth, height: 200),
            options: .usesLineFragmentOrigin, attributes: footerAttrs, context: nil).height) + 4
        let headerImageHeight = letterhead.headerImage == nil ? 0 : Letterhead.mm(letterhead.headerHeightMm) + 8
        let footerImageHeight = letterhead.footerImage == nil ? 0 : Letterhead.mm(letterhead.footerHeightMm) + 6
        let top: CGFloat = 40 + headerImageHeight + headerTextHeight + 12
        let bottom: CGFloat = 52 + footerImageHeight + footerTextHeight

        let printable = CGRect(x: 56, y: top, width: contentWidth, height: paper.height - top - bottom)
        let formatter = UISimpleTextPrintFormatter(attributedText: text)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        let pages = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
        for i in 0..<pages {
            UIGraphicsBeginPDFPage()
            var y: CGFloat = 40
            if let img = letterhead.headerImage {
                let h = Letterhead.mm(letterhead.headerHeightMm)
                let w = min(contentWidth, img.size.width * h / max(img.size.height, 1))
                img.draw(in: CGRect(x: (paper.width - w) / 2, y: y, width: w, height: h))
                y += h + 8
            }
            if headerText.length > 0 {
                headerText.draw(with: CGRect(x: 56, y: y, width: contentWidth, height: headerTextHeight),
                                options: .usesLineFragmentOrigin, attributes: headerTextAttrs, context: nil)
            }
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
            var fy = paper.height - 40
            let f = "\(footer) · página \(i + 1) de \(pages)" as NSString
            f.draw(at: CGPoint(x: 56, y: fy), withAttributes: footerAttrs)
            if footerText.length > 0 {
                fy -= footerTextHeight
                footerText.draw(with: CGRect(x: 56, y: fy, width: contentWidth, height: footerTextHeight),
                                options: .usesLineFragmentOrigin, attributes: footerAttrs, context: nil)
            }
            if let img = letterhead.footerImage {
                let h = Letterhead.mm(letterhead.footerHeightMm)
                let w = min(contentWidth, img.size.width * h / max(img.size.height, 1))
                img.draw(in: CGRect(x: (paper.width - w) / 2, y: fy - h - 6, width: w, height: h))
            }
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    /// Protege o PDF com senha (abrir exige a senha).
    static func protect(_ data: Data, password: String) -> Data? {
        guard let doc = PDFDocument(data: data) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = doc.write(to: url, withOptions: [
            PDFDocumentWriteOption.userPasswordOption: password,
            PDFDocumentWriteOption.ownerPasswordOption: password,
        ])
        guard ok else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: - Documentos

    static func noteDocument(_ note: SessionNote, db: Database) -> NSAttributedString {
        let b = Builder()
        b.title("Anotação de atendimento")
        var sub = "Atualizada em \(Formatters.dateTime.string(from: note.updatedAt))"
        if let appt = db.appointments.first(where: { $0.id == note.appointmentID }) {
            sub = "Atendimento de \(Formatters.dateTime.string(from: appt.start)) · " + sub
        }
        b.subtitle(sub)
        b.line(Term.Client, db.patient(note.patientID)?.name ?? "—")
        b.spacer()
        b.rich(note.body)
        return b.text
    }

    /// Valor por extenso ("cento e cinquenta reais e trinta centavos"), para o recibo.
    static func moneyInWords(_ cents: Int) -> String {
        let reais = cents / 100, centavos = cents % 100
        var parts: [String] = []
        if reais > 0 { parts.append(NumberWords.words(reais) + (reais == 1 ? " real" : (reais % 1_000_000 == 0 ? " de reais" : " reais"))) }
        if centavos > 0 { parts.append(NumberWords.words(centavos) + (centavos == 1 ? " centavo" : " centavos")) }
        return parts.isEmpty ? "zero real" : parts.joined(separator: " e ")
    }

    /// Recibo de pagamento de atendimentos (ou de um pacote), com os dados do profissional.
    static func receiptDocument(patient: Patient, items: [(String, Int)], paidAt: Date, method: PaymentMethod?, db: Database) -> NSAttributedString {
        let b = Builder()
        let total = items.reduce(0) { $0 + $1.1 }
        let pro = db.professional
        let fiscal = db.fiscal
        let issuer = fiscal.legalName.trimmingCharacters(in: .whitespaces).isEmpty ? pro.fullName : fiscal.legalName
        b.title("Recibo")
        b.subtitle("Valor: \(Formatters.money(total))")
        var who = patient.name
        if !patient.cpf.isEmpty { who += ", CPF \(patient.cpf)" }
        if !patient.guardianName.isEmpty {
            who += ", por meio de \(patient.guardianName)"
            if !patient.guardianCpf.isEmpty { who += " (CPF \(patient.guardianCpf))" }
        }
        let how = method.map { " (\($0.label.lowercased()))" } ?? ""
        b.paragraph("Recebi de \(who) a quantia de \(Formatters.money(total)) (\(moneyInWords(total)))\(how), referente a:")
        for (desc, value) in items { b.paragraph("• \(desc): \(Formatters.money(value))") }
        b.spacer()
        b.paragraph("Data do pagamento: \(Formatters.longDate.string(from: paidAt)).")
        b.spacer()
        b.spacer()
        b.paragraph("______________________________________")
        b.paragraph(issuer)
        if !fiscal.document.isEmpty { b.paragraph((fiscal.personType == .company ? "CNPJ " : "CPF ") + fiscal.document, color: .darkGray) }
        if !pro.subtitle.isEmpty { b.paragraph(pro.subtitle, color: .darkGray) }
        let address = pro.officeAddress.isEmpty ? fiscal.address : pro.officeAddress
        if !address.isEmpty { b.paragraph(address, font: .systemFont(ofSize: 10), color: .darkGray) }
        b.spacer()
        b.paragraph("Este recibo não substitui a nota fiscal, quando ela for exigida.", font: .systemFont(ofSize: 9), color: .gray)
        return b.text
    }

    static func receiptItems(_ list: [Appointment], db: Database) -> [(String, Int)] {
        list.sorted { $0.start < $1.start }.map { a in
            let what = db.tag(a.tagID)?.name ?? "Atendimento"
            return ("\(what) em \(Formatters.dateTime.string(from: a.start))", db.price(of: a))
        }
    }

    static func patientSessionsReport(_ patient: Patient, interval: DateInterval, db: Database, now: Date = Date()) -> NSAttributedString {
        let b = Builder()
        b.title("Relatório de atendimentos")
        b.subtitle("\(patient.name) · \(Formatters.shortDate.string(from: interval.start)) a \(Formatters.shortDate.string(from: interval.end.addingTimeInterval(-1)))")
        let list = db.appointments(of: patient.id).filter { interval.contains($0.start) }
        let attended = list.filter { $0.attendance == .attended || ($0.attendance == .scheduled && $0.end <= now) }.count
        let missed = list.filter { $0.attendance == .missed }.count
        let cancelled = list.filter { $0.attendance == .cancelled }.count
        b.line("Atendimentos no período", "\(list.count)")
        b.line("Realizados", "\(attended)")
        b.line("Faltas", "\(missed)")
        if cancelled > 0 { b.line("Cancelados com aviso", "\(cancelled)") }
        b.heading("Atendimentos")
        for a in list {
            let pay: String
            if let pkg = db.package(a.packageID) { pay = "pacote (\(pkg.title))" }
            else if Billing.isNoCharge(a, in: db) { pay = "sem custo" }
            else { pay = a.payment == .paid ? "pago" : (a.payment == .unpaid ? "não pago" : "pagamento não informado") }
            let tag = db.tag(a.tagID).map { " · \($0.name)" } ?? ""
            b.paragraph("\(Formatters.dateTime.string(from: a.start))\(tag) · \(a.attendance.label) · \(pay) · \(Formatters.money(db.price(of: a)))")
        }
        if list.isEmpty { b.paragraph("Nenhum atendimento no período.", color: .gray) }
        let pkgs = Packages.of(patient.id, in: db)
        if !pkgs.isEmpty {
            b.heading("Pacotes")
            for p in pkgs {
                b.paragraph("\(p.title) · \(Formatters.money(p.priceCents)) · \(p.isPaid ? "pago" : "não pago") · \(Packages.usageLabel(p, in: db))")
            }
        }
        return b.text
    }

    static func financeReport(interval: DateInterval, db: Database, now: Date = Date()) -> NSAttributedString {
        let s = Finance.summary(db, interval: interval, now: now)
        let b = Builder()
        b.title("Relatório financeiro")
        b.subtitle("\(Formatters.shortDate.string(from: interval.start)) a \(Formatters.shortDate.string(from: interval.end.addingTimeInterval(-1)))")
        b.line("Recebido", "\(Formatters.money(s.receivedCents)) (\(s.receivedCount) \(s.receivedCount == 1 ? "pagamento" : "pagamentos"))")
        if s.packagesReceivedCount > 0 { b.line("Dos quais em pacotes", "\(Formatters.money(s.packagesReceivedCents)) (\(s.packagesReceivedCount))") }
        b.line("Despesas", Formatters.money(s.expensesCents))
        b.line("Resultado (recebido menos despesas)", Formatters.money(s.netCents))
        b.line("Em aberto", "\(Formatters.money(s.openCents)) (\(s.openCount))")
        b.line("Inadimplência", Formatters.percent(s.delinquencyRate))
        b.line("\(Term.Clients) com valores em aberto", "\(s.delinquentPatientCount)")
        b.line("Previsto (atendimentos futuros)", "\(Formatters.money(s.expectedCents)) em \(s.expectedCount) atendimentos")
        if !s.byMethod.isEmpty {
            b.heading("Recebido por forma de pagamento")
            for (m, v) in s.byMethod.sorted(by: { $0.value > $1.value }) { b.paragraph("\(m.label): \(Formatters.money(v))") }
        }
        if !s.expensesByCategory.isEmpty {
            b.heading("Despesas por categoria")
            for (c, v) in s.expensesByCategory.sorted(by: { $0.value > $1.value }) { b.paragraph("\(c.label): \(Formatters.money(v))") }
        }
        if !s.openByPatient.isEmpty {
            b.heading("Valores em aberto por \(Term.client)")
            let rows = s.openByPatient.map { (db.patient($0.key)?.name ?? "—", $0.value) }.sorted { $0.1 > $1.1 }
            for (name, v) in rows { b.paragraph("\(name): \(Formatters.money(v))") }
        }
        return b.text
    }
}

/// Números por extenso, em português (até 999.999.999).
enum NumberWords {
    private static let units = ["zero", "um", "dois", "três", "quatro", "cinco", "seis", "sete", "oito", "nove", "dez",
                                "onze", "doze", "treze", "catorze", "quinze", "dezesseis", "dezessete", "dezoito", "dezenove"]
    private static let tens = ["", "", "vinte", "trinta", "quarenta", "cinquenta", "sessenta", "setenta", "oitenta", "noventa"]
    private static let hundreds = ["", "cento", "duzentos", "trezentos", "quatrocentos", "quinhentos", "seiscentos",
                                   "setecentos", "oitocentos", "novecentos"]

    static func words(_ n: Int) -> String {
        guard n > 0 else { return "zero" }
        var parts: [String] = []
        let millions = n / 1_000_000, thousands = (n / 1000) % 1000, rest = n % 1000
        if millions > 0 { parts.append(millions == 1 ? "um milhão" : "\(below1000(millions)) milhões") }
        if thousands > 0 { parts.append(thousands == 1 ? "mil" : "\(below1000(thousands)) mil") }
        if rest > 0 { parts.append(below1000(rest)) }
        guard parts.count > 1 else { return parts.first ?? "" }
        // "mil e cem", "mil e vinte", "dois mil trezentos e dez": o "e" antes do último grupo quando ele é redondo ou < 100.
        let last = parts.removeLast()
        let useAnd = rest > 0 && (rest < 100 || rest % 100 == 0)
        return parts.joined(separator: " ") + (useAnd ? " e " : " ") + last
    }

    private static func below1000(_ n: Int) -> String {
        if n == 100 { return "cem" }
        let h = n / 100, r = n % 100
        var parts: [String] = []
        if h > 0 { parts.append(hundreds[h]) }
        if r > 0 {
            if r < 20 { parts.append(units[r]) }
            else { parts.append(r % 10 == 0 ? tens[r / 10] : "\(tens[r / 10]) e \(units[r % 10])") }
        }
        return parts.joined(separator: " e ")
    }
}
