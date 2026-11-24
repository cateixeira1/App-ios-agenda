import Foundation

// MARK: - Certificados (ICP-Brasil)

/// A1: certificado em arquivo (.pfx/.p12), guardado cifrado pelo app. A3 (token ou cartão) não funciona no iPhone.
enum CertificateKind: String, Codable, Hashable {
    case a1, a3
}

struct CertificateEntry: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    @Default<Defaults.CertA1> var kind: CertificateKind = .a1
    /// Nome comum do certificado (CN).
    @Default<Defaults.EmptyString> var subject: String = ""
    /// Nome do titular (sem o CPF/CNPJ que costuma vir junto no CN).
    @Default<Defaults.EmptyString> var holderName: String = ""
    @Default<Defaults.EmptyString> var holderCpf: String = ""
    @Default<Defaults.EmptyString> var holderCnpj: String = ""
    @Default<Defaults.EmptyString> var issuer: String = ""
    @Default<Defaults.Distant> var notBefore: Date = Date(timeIntervalSinceReferenceDate: 0)
    @Default<Defaults.Distant> var notAfter: Date = Date(timeIntervalSinceReferenceDate: 0)
    @Default<Defaults.EmptyString> var thumbprint: String = ""
    @Default<Defaults.EmptyString> var serialNumber: String = ""
    @Default<Defaults.False> var isIcpBrasil: Bool = false
    @Default<Defaults.False> var isDefault: Bool = false
    @Default<Defaults.Distant> var addedAt: Date = Date()
    /// A1: arquivo .pfx guardado cifrado (anexo).
    var pfxAttachmentID: UUID?

    var typeLabel: String { !holderCnpj.isEmpty ? "e-CNPJ" : !holderCpf.isEmpty ? "e-CPF" : "Certificado" }
    var kindLabel: String { kind == .a1 ? "A1 (arquivo)" : "A3 (token ou cartão)" }

    func daysLeft(now: Date = Date()) -> Int { Int(floor(notAfter.timeIntervalSince(now) / 86_400)) }
    func isExpired(now: Date = Date()) -> Bool { now > notAfter }
    func expiresSoon(now: Date = Date()) -> Bool { !isExpired(now: now) && daysLeft(now: now) <= 30 }
    /// No iPhone só assina o A1 (arquivo guardado no app).
    var canSignOnThisDevice: Bool { kind == .a1 && pfxAttachmentID != nil }
}

// MARK: - Cobrança

/// Regras de cobrança usadas em todo o app.
/// - Atendimento com a tag de retorno parte do princípio de que não tem custo, mas passa a ter quando o próprio
///   atendimento ou a tag de retorno recebem um valor.
/// - Atendimento de pacote nunca é cobrado sozinho: o pagamento é o do pacote.
/// Atendimentos sem custo não entram em recebido, em aberto, previsto nem inadimplência e não geram nota.
enum Billing {
    static func isNoCharge(_ a: Appointment, in db: Database) -> Bool {
        if a.packageID != nil, db.package(a.packageID) != nil { return true }
        guard let tagID = a.tagID, let tag = db.returnTag(), tag.id == tagID else { return false }
        return (a.amountCents ?? db.tagPrice(tag) ?? 0) == 0
    }

    static func isBillable(_ a: Appointment, in db: Database) -> Bool { !isNoCharge(a, in: db) }

    static func noChargeLabel(_ a: Appointment, in db: Database) -> String {
        if let p = db.package(a.packageID) {
            return NameMatcher.normalize(p.title).hasPrefix("pacote") ? p.title : "Pacote: \(p.title)"
        }
        return "Retorno sem custo"
    }
}

// MARK: - Pacotes

enum Packages {
    /// Atendimentos que contam no pacote: todos os ligados a ele, menos os desmarcados com aviso.
    static func usedAppointments(_ p: ServicePackage, in db: Database) -> [Appointment] {
        db.appointments.filter { $0.packageID == p.id && !$0.isCancelled }.sorted { $0.start < $1.start }
    }

    static func used(_ p: ServicePackage, in db: Database) -> Int { usedAppointments(p, in: db).count }

    static func remaining(_ p: ServicePackage, in db: Database) -> Int { max(0, p.totalSessions - used(p, in: db)) }

    /// Aceita mais atendimentos: tem saldo, não venceu e não foi encerrado.
    static func isAvailable(_ p: ServicePackage, in db: Database, now: Date = Date()) -> Bool {
        !p.closed && !p.isExpired(now: now) && remaining(p, in: db) > 0
    }

    /// Pacotes do cliente que ainda aceitam atendimentos (o mais antigo primeiro, para gastar antes).
    static func available(for patientID: UUID, in db: Database, now: Date = Date()) -> [ServicePackage] {
        db.packages.filter { $0.patientID == patientID && isAvailable($0, in: db, now: now) }
            .sorted { $0.purchasedAt < $1.purchasedAt }
    }

    static func of(_ patientID: UUID, in db: Database) -> [ServicePackage] {
        db.packages.filter { $0.patientID == patientID }.sorted { $0.purchasedAt > $1.purchasedAt }
    }

    /// Valor de cada atendimento do pacote (para relatórios).
    static func unitPriceCents(_ p: ServicePackage) -> Int {
        p.totalSessions > 0 ? p.priceCents / p.totalSessions : p.priceCents
    }

    /// "3 de 10 usados · 7 restantes".
    static func usageLabel(_ p: ServicePackage, in db: Database) -> String {
        let u = used(p, in: db)
        let r = max(0, p.totalSessions - u)
        return "\(u) de \(p.totalSessions) usados · \(r) \(r == 1 ? "restante" : "restantes")"
    }
}

// MARK: - NFS-e

enum NfseState: String, Codable, Hashable {
    /// Enviada, sem resposta: é preciso conferir antes de tentar de novo.
    case unknown
    case rejected
    case issued
    case cancelled

    var label: String {
        switch self {
        case .unknown: return "Enviada, aguardando confirmação"
        case .rejected: return "Recusada"
        case .issued: return "Emitida"
        case .cancelled: return "Cancelada"
        }
    }
}

struct NfseInfo: Codable, Equatable, Hashable {
    /// "DPS" + 42 dígitos. É o mesmo em todas as tentativas do atendimento, o que impede nota em dobro.
    @Default<Defaults.EmptyString> var dpsId: String = ""
    @Default<Defaults.EmptyString> var series: String = ""
    var dpsNumber: Int64 = 0
    @Default<Defaults.Homologation> var environment: NfseEnvironment = .homologation
    @Default<Defaults.NfseUnknown> var state: NfseState = .unknown
    @Default<Defaults.Distant> var firstAttemptAt: Date = Date()
    var lastAttemptAt: Date?
    var issuedAt: Date?
    /// Chave de acesso (50 dígitos).
    var accessKey: String?
    var number: String?
    /// XML autorizado, guardado cifrado (anexo).
    var xmlAttachmentID: UUID?
    var lastError: String?
    var cancelledAt: Date?
    @Default<Defaults.EmptyString> var takerName: String = ""
    @Default<Defaults.EmptyString> var takerDocument: String = ""
    @Default<Defaults.Zero> var valueCents: Int = 0

    var isIssued: Bool { state == .issued }

    private enum CodingKeys: String, CodingKey {
        case dpsId, series, dpsNumber, environment, state, firstAttemptAt, lastAttemptAt, issuedAt, accessKey, number,
             xmlAttachmentID, lastError, cancelledAt, takerName, takerDocument, valueCents
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dpsId = try c.decode(Default<Defaults.EmptyString>.self, forKey: .dpsId).wrappedValue
        series = try c.decode(Default<Defaults.EmptyString>.self, forKey: .series).wrappedValue
        dpsNumber = try c.decodeIfPresent(Int64.self, forKey: .dpsNumber) ?? 0
        environment = try c.decode(Default<Defaults.Homologation>.self, forKey: .environment).wrappedValue
        state = try c.decode(Default<Defaults.NfseUnknown>.self, forKey: .state).wrappedValue
        firstAttemptAt = try c.decode(Default<Defaults.Distant>.self, forKey: .firstAttemptAt).wrappedValue
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        issuedAt = try c.decodeIfPresent(Date.self, forKey: .issuedAt)
        accessKey = try c.decodeIfPresent(String.self, forKey: .accessKey)
        number = try c.decodeIfPresent(String.self, forKey: .number)
        xmlAttachmentID = try c.decodeIfPresent(UUID.self, forKey: .xmlAttachmentID)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        takerName = try c.decode(Default<Defaults.EmptyString>.self, forKey: .takerName).wrappedValue
        takerDocument = try c.decode(Default<Defaults.EmptyString>.self, forKey: .takerDocument).wrappedValue
        valueCents = try c.decode(Default<Defaults.Zero>.self, forKey: .valueCents).wrappedValue
    }
}

/// Constantes da NFS-e Nacional usadas pelo app.
enum Nfse {
    /// Código IBGE de Santo André (SP), o único município atendido nesta versão.
    static let santoAndre = "3547809"
    static let santoAndreName = "Santo André (SP)"
    static let productionURL = "https://sefin.nfse.gov.br/SefinNacional"
    static let homologationURL = "https://sefin.producaorestrita.nfse.gov.br/SefinNacional"
    static let publicConsultURL = "https://www.nfse.gov.br/consultapublica"
    static let namespace = "http://www.sped.fazenda.gov.br/nfse"
    static let layoutVersion = "1.01"

    static func baseURL(_ e: NfseEnvironment) -> String { e == .production ? productionURL : homologationURL }

    /// O código de tributação nacional informado pelo profissional (6 dígitos; vazio se não informado).
    static func taxCode(_ db: Database) -> String { onlyDigits(db.fiscal.nationalTaxCode) }

    static func taxCodeLabel(_ code: String) -> String {
        guard code.count == 6 else { return code.isEmpty ? "não informado" : code }
        let c = Array(code)
        return "\(String(c[0..<2])).\(String(c[2..<4])).\(String(c[4..<6]))"
    }

    /// Nota de teste (homologação) num atendimento, com o app já em produção: não conta como nota fiscal.
    static func isTestLeftover(_ n: NfseInfo?, fiscal f: FiscalProfile) -> Bool {
        guard let n else { return false }
        return n.environment == .homologation && f.environment == .production
    }

    static func onlyDigits(_ s: String?) -> String { (s ?? "").filter(\.isASCIIDigit) }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}

// MARK: - Local do atendimento

enum Places {
    /// "https://meet.google.com/…", "zoom.us/j/…" etc.
    static func isLink(_ place: String) -> Bool {
        let t = place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("www.")
            || ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "jit.si"].contains { t.contains($0) }
    }

    /// "Online" sem link.
    static func isOnline(_ place: String) -> Bool {
        let t = NameMatcher.normalize(place)
        return t == "online" || t == "on-line" || t == "virtual" || t == "remoto"
    }

    /// Link para abrir: o próprio endereço da reunião ou o endereço no app Mapas. nil para "Online".
    static func url(for place: String) -> URL? {
        let t = place.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isOnline(t) else { return nil }
        if isLink(t) {
            let withScheme = t.lowercased().hasPrefix("http") ? t : "https://" + t
            return URL(string: withScheme)
        }
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "q", value: t)]
        return c?.url
    }
}
