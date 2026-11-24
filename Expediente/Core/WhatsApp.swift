import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mensagens pelo WhatsApp, sem a API da Meta e sem servidor: os botões abrem o WhatsApp (link https://wa.me) na
/// conversa do cliente, com a mensagem já escrita. Quem envia é o profissional.
enum WhatsAppMessage {
    static let nameField = "{nome}"
    static let timeField = "{horário}"
    static let dateField = "{data}"
    static let placeField = "{local}"
    static let valueField = "{valor}"
    static let pixField = "{pix}"
    static let defaultTemplate = "Olá, {nome}! Confirmando nosso horário {data} às {horário}. Até logo!"
    static let defaultChargeTemplate = "Olá, {nome}! O valor do atendimento de {data} ficou em {valor}."
    static let defaultChargePixSuffix = "\n\nPix copia e cola:\n{pix}"
    static let maxTemplateLength = 700

    private static let fields = try! NSRegularExpression(
        pattern: #"\{\s*(nome|primeiro nome|hor[áa]rio|hora|data|dia|local|valor|pix)\s*\}"#, options: [.caseInsensitive])

    /// A mensagem escolhida em Ajustes (vazio = a padrão).
    static func template(_ s: AppSettings) -> String {
        s.whatsAppTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultTemplate : s.whatsAppTemplate
    }

    /// "hoje", "amanhã" ou "na terça, 25/11".
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "hoje" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return "amanhã" }
        let prep = Formatters.isFeminineWeekday(date, calendar: calendar) ? "na" : "no"
        return "\(prep) \(Formatters.weekdayName(date, calendar: calendar)), \(Formatters.dayMonth.string(from: date))"
    }

    /// Troca os campos entre chaves pelos valores (campo sem valor some).
    static func fill(_ template: String, values: [String: String]) -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in fields.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var field = ns.substring(with: m.range(at: 1)).lowercased()
            if field.hasPrefix("hor") { field = "horário" }
            if field == "primeiro nome" { field = "nome" }
            if field == "dia" { field = "data" }
            out += values[field] ?? ""
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Troca {nome} pelo primeiro nome, {horário} pelo horário, {data} por "hoje", "amanhã" ou o dia, e {local} pelo local.
    static func compose(_ template: String?, firstName: String, start: Date, place: String = "", now: Date = Date()) -> String {
        let raw = (template ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = raw.isEmpty ? defaultTemplate : raw
        return fill(t, values: ["nome": firstName, "horário": Formatters.time.string(from: start),
                                "data": relativeDay(start, now: now), "local": place])
    }

    /// Número no formato do link: internacional, só dígitos (ex.: 5511987654321). nil = vazio, sem DDD ou inválido.
    static func linkPhone(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let plus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        var d = Masks.digits(raw)
        if plus {
            if d.hasPrefix("55") { return [12, 13].contains(d.count) ? d : nil }
            return (8...15).contains(d.count) ? d : nil
        }
        while d.hasPrefix("0") { d.removeFirst() }
        if [10, 11].contains(d.count) { return "55" + d }
        if d.hasPrefix("55") && [12, 13].contains(d.count) { return d }
        return nil
    }

    /// Por que o botão não abre a conversa deste cliente (nil = abre).
    static func blockReason(_ p: Patient?) -> String? {
        guard let p else { return "Atendimento sem \(Term.client)." }
        if Masks.phoneToSave(p.phone).isEmpty { return "Sem telefone no cadastro do \(Term.client)." }
        if linkPhone(p.phone) != nil { return nil }
        var d = Masks.digits(p.phone)
        while d.hasPrefix("0") { d.removeFirst() }
        return [8, 9].contains(d.count) && !p.phone.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            ? "Telefone sem DDD no cadastro do \(Term.client)."
            : "Telefone incompleto ou inválido no cadastro do \(Term.client)."
    }

    static func link(phone: String, text: String) -> URL? {
        // Só os caracteres não reservados ficam como estão (o resto, inclusive acentos, vai codificado).
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://wa.me/\(phone)?text=\(encoded)")
    }

    /// A mensagem da tag do atendimento, se ela tiver uma; senão a mensagem geral de Ajustes.
    static func template(for a: Appointment, in db: Database) -> String {
        let own = (db.tag(a.tagID)?.whatsAppMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? template(db.settings) : own
    }

    static func message(for a: Appointment, in db: Database, now: Date = Date()) -> String {
        compose(template(for: a, in: db), firstName: db.patient(a.patientID)?.firstName ?? "", start: a.start,
                place: db.location(of: a), now: now)
    }

    /// O link deste atendimento, com o telefone do cadastro do cliente, ou nil quando não dá para abrir a conversa.
    static func link(for a: Appointment, in db: Database, now: Date = Date()) -> URL? {
        guard let p = db.patient(a.patientID), blockReason(p) == nil, let phone = linkPhone(p.phone) else { return nil }
        return link(phone: phone, text: message(for: a, in: db, now: now))
    }

    /// O botão de confirmação aparece nos atendimentos de hoje em diante que não foram cancelados.
    static func showsButton(_ a: Appointment, now: Date, calendar: Calendar = .current) -> Bool {
        a.start >= calendar.startOfDay(for: now) && !a.isCancelled
    }

    // MARK: - Cobrança

    /// Mensagem de cobrança: a de Ajustes ou a padrão (com o Pix copia e cola, se estiver configurado).
    static func chargeTemplate(_ s: AppSettings, count: Int = 1) -> String {
        let own = s.chargeTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        let base = count > 1 ? "Olá, {nome}! O valor dos atendimentos de {data} ficou em {valor}." : defaultChargeTemplate
        return Pix.isConfigured(s) ? base + defaultChargePixSuffix : base
    }

    /// Cobrança de um ou mais atendimentos do mesmo cliente (o total vai em {valor}; o Pix já leva o valor).
    static func chargeMessage(for list: [Appointment], in db: Database) -> String {
        let sorted = list.sorted { $0.start < $1.start }
        let total = sorted.reduce(0) { $0 + db.price(of: $1) }
        let dates = sorted.map { Formatters.dayMonth.string(from: $0.start) }
        let first = sorted.first.flatMap { db.patient($0.patientID)?.firstName } ?? ""
        let pix = Pix.payload(db.settings, amountCents: total) ?? ""
        let text = fill(chargeTemplate(db.settings, count: sorted.count), values: [
            "nome": first, "valor": Formatters.money(total), "data": Formatters.list(dates),
            "horário": sorted.first.map { Formatters.time.string(from: $0.start) } ?? "",
            "local": sorted.first.map { db.location(of: $0) } ?? "", "pix": pix,
        ])
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cobrança de um pacote.
    static func chargeMessage(for p: ServicePackage, in db: Database) -> String {
        let first = db.patient(p.patientID)?.firstName ?? ""
        let pix = Pix.payload(db.settings, amountCents: p.priceCents) ?? ""
        var text = "Olá, \(first)! O valor do \(p.title.lowercasedFirst) ficou em \(Formatters.money(p.priceCents))."
        if !pix.isEmpty { text += "\n\nPix copia e cola:\n\(pix)" }
        return text
    }

    static func chargeLink(for list: [Appointment], in db: Database) -> URL? {
        guard let a = list.first, let p = db.patient(a.patientID), blockReason(p) == nil, let phone = linkPhone(p.phone) else { return nil }
        return link(phone: phone, text: chargeMessage(for: list, in: db))
    }

    static func chargeLink(for pkg: ServicePackage, in db: Database) -> URL? {
        guard let p = db.patient(pkg.patientID), blockReason(p) == nil, let phone = linkPhone(p.phone) else { return nil }
        return link(phone: phone, text: chargeMessage(for: pkg, in: db))
    }
}

extension String {
    /// "Pacote de 10" → "pacote de 10".
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// Endereço encontrado para um CEP.
struct CepResult: Equatable {
    var cep: String
    var street: String
    var district: String
    var city: String
    var state: String
    var ibgeCode: String
}

/// Busca do endereço pelo CEP no ViaCEP (https://viacep.com.br). Só o CEP sai do aparelho.
enum CepLookup {
    static let serviceName = "ViaCEP"

    static func url(_ cepDigits: String) -> URL { URL(string: "https://viacep.com.br/ws/\(cepDigits)/json/")! }

    /// O endereço do CEP, ou nil se o CEP não existe. Lança erro se o serviço não responder.
    static func find(_ cep: String, session: URLSession = .shared) async throws -> CepResult? {
        let d = Masks.digits(cep)
        guard d.count == Masks.cepDigits else { return nil }
        var req = URLRequest(url: url(d), timeoutInterval: 8)
        req.setValue("Expediente-iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 400 { return nil }
            guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> CepResult? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let erro = obj["erro"], (erro as? Bool) == true || (erro as? String) == "true" { return nil }
        func get(_ k: String) -> String { ((obj[k] as? String) ?? "").trimmingCharacters(in: .whitespaces) }
        let cep = get("cep")
        guard Masks.digits(cep).count == Masks.cepDigits else { return nil }
        return CepResult(cep: Masks.cep(cep), street: get("logradouro"), district: get("bairro"), city: get("localidade"),
                         state: get("uf").uppercased(), ibgeCode: get("ibge"))
    }

    static func fill(_ a: inout PostalAddress, with r: CepResult) {
        a.cep = r.cep
        a.street = r.street
        a.district = r.district
        a.city = r.city
        a.state = r.state
    }
}
