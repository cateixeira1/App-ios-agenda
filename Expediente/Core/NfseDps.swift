import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// NFS-e Nacional (leiaute 1.01): DPS, pedido de cancelamento e assinatura XMLDSig. Mesmas regras da versão para
// Windows. O XML é montado aqui mesmo, já na forma canônica (C14N 1.0), para a assinatura conferir no servidor.

enum NfseError: LocalizedError, Equatable {
    case validation([String])
    case message(String)

    var errorDescription: String? {
        switch self {
        case .validation(let p): return p.joined(separator: "\n")
        case .message(let m): return m
        }
    }
}

/// Dados de uma DPS (Declaração de Prestação de Serviço).
struct DpsData {
    var environment: NfseEnvironment = .homologation
    var issuedAt = Date()
    var timeZone = TimeZone.current
    /// Série com 5 dígitos (faixa das aplicações próprias: 00001 a 49999).
    var series = "00001"
    var number: Int64 = 0
    /// Dia da sessão.
    var competence = Date()
    var municipalityCode = Nfse.santoAndre
    var providerCnpj = ""
    var providerCpf = ""
    var providerMunicipalRegistration = ""
    var providerPhone = ""
    var providerEmail = ""
    var simplesOption = 3
    var simplesRegime = 1
    var specialRegime = 0
    var takerCpf = ""
    var takerName = ""
    var takerEmail = ""
    var taxCode = ""
    var nbsCode = ""
    var description = ""
    var valueCents = 0
    var approxTaxSnPercent = ""
    var appVersion = "Expediente-iOS"

    var providerInscription: String { providerCnpj.isEmpty ? providerCpf : providerCnpj }
    var id: String { NfseDps.identifier(municipality: municipalityCode, inscription: providerInscription, series: series, number: number) }
}

/// Elemento XML simples, serializado na forma canônica (C14N 1.0, sem comentários).
final class XmlNode {
    let name: String
    var attributes: [(String, String)]
    var children: [XmlNode] = []
    var text: String?

    init(_ name: String, _ text: String? = nil, attributes: [(String, String)] = []) {
        self.name = name
        self.text = text
        self.attributes = attributes
    }

    @discardableResult
    func add(_ name: String, _ text: String? = nil, attributes: [(String, String)] = []) -> XmlNode {
        let n = XmlNode(name, text, attributes: attributes)
        children.append(n)
        return n
    }

    func append(_ node: XmlNode) { children.append(node) }

    /// Forma canônica. `namespace` é a declaração do espaço de nomes padrão que aparece neste elemento.
    func canonical(namespace: String? = nil) -> String {
        var s = "<" + name
        if let namespace { s += " xmlns=\"\(XmlNode.escapeAttribute(namespace))\"" }
        for (k, v) in attributes.sorted(by: { $0.0 < $1.0 }) { s += " \(k)=\"\(XmlNode.escapeAttribute(v))\"" }
        s += ">"
        if let text { s += XmlNode.escapeText(text) }
        for c in children { s += c.canonical(namespace: c.declaredNamespace) }
        s += "</\(name)>"
        return s
    }

    /// Espaço de nomes declarado no próprio elemento (só a raiz e a Signature declaram).
    var declaredNamespace: String?

    static func escapeText(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\r": out += "&#xD;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func escapeAttribute(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case "\"": out += "&quot;"
            case "\t": out += "&#x9;"
            case "\n": out += "&#xA;"
            case "\r": out += "&#xD;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Quem assina o XML: o certificado do prestador (ICP-Brasil, chave RSA).
protocol XmlSigningIdentity {
    /// Certificado (DER), que vai no KeyInfo.
    var certificateDER: Data { get }
    /// Assinatura RSA PKCS#1 v1.5 com SHA-1 dos bytes.
    func signRSASHA1(_ data: Data) throws -> Data
}

enum NfseDps {
    static let dsigNamespace = "http://www.w3.org/2000/09/xmldsig#"
    static let c14nURL = "http://www.w3.org/TR/2001/REC-xml-c14n-20010315"

    static func normalizeSeries(_ s: String?) -> String {
        var d = Nfse.onlyDigits(s)
        while d.hasPrefix("0") { d.removeFirst() }
        var n = Int(d) ?? 1
        if n < 1 || n > 49999 { n = 1 }
        return String(format: "%05d", n)
    }

    /// "DPS" + município (7) + tipo de inscrição (1 = CPF, 2 = CNPJ) + inscrição (14) + série (5) + número (15).
    static func identifier(municipality: String, inscription: String, series: String, number: Int64) -> String {
        let insc = Nfse.onlyDigits(inscription)
        let type = insc.count == 11 ? "1" : "2"
        return "DPS" + pad(Nfse.onlyDigits(municipality), 7) + type + pad(insc, 14) + normalizeSeries(series) + pad(String(number), 15)
    }

    private static func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : String(repeating: "0", count: n - s.count) + s }

    /// O identificador sem o prefixo "DPS", como a API espera em /dps/{id}.
    static func apiID(_ dpsID: String) -> String { dpsID.uppercased().hasPrefix("DPS") ? String(dpsID.dropFirst(3)) : dpsID }

    static func isValidCPF(_ s: String?) -> Bool { Masks.isValidCPF(s) }

    static func isValidCNPJ(_ s: String?) -> Bool {
        let d = Nfse.onlyDigits(s)
        return d.count == 14 && Masks.isValidCNPJ(d)
    }

    /// Texto aceito pelo leiaute (só Latin-1, sem espaços nas pontas).
    static func clean(_ s: String?, keepLineBreaks: Bool = false) -> String {
        guard let s, !s.isEmpty else { return "" }
        var out = ""
        for ch0 in s.precomposedStringWithCanonicalMapping {
            var ch = ch0
            switch ch0 {
            case "–", "—", "−": ch = "-"
            case "‘", "’", "´": ch = "'"
            case "“", "”": ch = "\""
            case "…": ch = "."
            case "\u{00A0}", "\t": ch = " "
            default: break
            }
            if ch == "\r" { continue }
            if ch == "\n" || ch == "\r\n" {
                out.append(keepLineBreaks ? "\n" : " ")
                continue
            }
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                let folded = String(ch).folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
                for f in folded.unicodeScalars where f.value >= 0x20 && f.value <= 0xFF && !(0x7F...0x9F).contains(f.value) {
                    out.unicodeScalars.append(f)
                }
                continue
            }
            if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) { continue }
            if scalar.value > 0xFF {
                let folded = String(ch).folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
                for f in folded.unicodeScalars where f.value >= 0x20 && f.value <= 0xFF { out.unicodeScalars.append(f) }
                continue
            }
            out.append(ch)
        }
        let lines = out.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.contains("  ") { l = l.replacingOccurrences(of: "  ", with: " ") }
            return l.trimmingCharacters(in: .whitespaces)
        }
        return lines.filter { !$0.isEmpty }.joined(separator: keepLineBreaks ? "\n" : " ").trimmingCharacters(in: .whitespaces)
    }

    static func money(_ cents: Int) -> String { "\(cents / 100)." + String(format: "%02d", cents % 100) }

    /// "6,00" → "6.00"; vazio ou inválido → "".
    static func percent(_ text: String?) -> String {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let s = text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(s), v > 0, v < 100 else { return "" }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), v)
    }

    /// "2026-10-23T09:41:00-03:00".
    static func dateTimeText(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let offset = timeZone.secondsFromGMT(for: d)
        let sign = offset < 0 ? "-" : "+"
        let a = abs(offset)
        return f.string(from: d) + String(format: "%@%02d:%02d", sign, a / 3600, (a % 3600) / 60)
    }

    static func day(_ d: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Confere os dados antes de montar a DPS. Devolve os problemas em português (vazio = tudo certo).
    static func validate(_ d: DpsData) -> [String] {
        var p: [String] = []
        if !d.providerCnpj.isEmpty ? !isValidCNPJ(d.providerCnpj) : !isValidCPF(d.providerCpf) {
            p.append("CNPJ do prestador inválido (Notas fiscais › Seus dados fiscais).")
        }
        if d.simplesOption == 3 && d.providerCnpj.isEmpty { p.append("Optante pelo Simples Nacional (ME/EPP) precisa emitir com o CNPJ.") }
        if Nfse.onlyDigits(d.municipalityCode).count != 7 { p.append("Código do município inválido.") }
        if d.providerMunicipalRegistration.count > 15 { p.append("A inscrição municipal tem mais de 15 caracteres.") }
        if !d.providerPhone.isEmpty && !(6...20).contains(Nfse.onlyDigits(d.providerPhone).count) { p.append("Telefone do prestador inválido.") }
        if d.simplesOption == 3 && d.simplesRegime == 1 && d.specialRegime != 0 {
            p.append("Com os tributos apurados pelo Simples Nacional, o regime especial deve ser \"nenhum\".")
        }
        if !d.takerCpf.isEmpty && !isValidCPF(d.takerCpf) { p.append("CPF do tomador inválido (cadastro do \(Term.client)).") }
        if d.takerCpf.isEmpty { p.append("Cadastre o CPF do \(Term.client) (ou do responsável) para emitir a nota.") }
        if clean(d.takerName).isEmpty { p.append("Nome do tomador vazio.") }
        if d.valueCents <= 0 { p.append("O valor do atendimento precisa ser maior que zero.") }
        if Nfse.onlyDigits(d.taxCode).count != 6 { p.append("Código de tributação nacional inválido (6 dígitos).") }
        if !d.nbsCode.isEmpty && Nfse.onlyDigits(d.nbsCode).count != 9 { p.append("Código NBS inválido (9 dígitos).") }
        if clean(d.description, keepLineBreaks: true).isEmpty { p.append("Descrição do serviço vazia.") }
        if d.number < 1 { p.append("Número da DPS inválido.") }
        if day(d.competence, timeZone: d.timeZone) > day(d.issuedAt, timeZone: d.timeZone) {
            p.append("A nota só pode ser emitida a partir do dia do atendimento.")
        }
        return p
    }

    private static func cut(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) : s }

    /// Monta a DPS (sem assinatura). A raiz é DPS; o elemento assinado é infDPS.
    static func build(_ d: DpsData) throws -> XmlNode {
        let problems = validate(d)
        if !problems.isEmpty { throw NfseError.validation(problems) }
        let root = XmlNode("DPS", attributes: [("versao", Nfse.layoutVersion)])
        root.declaredNamespace = Nfse.namespace
        let inf = root.add("infDPS", attributes: [("Id", d.id)])
        inf.add("tpAmb", d.environment == .production ? "1" : "2")
        inf.add("dhEmi", dateTimeText(d.issuedAt, timeZone: d.timeZone))
        inf.add("verAplic", cut(clean(d.appVersion), 20))
        inf.add("serie", normalizeSeries(d.series))
        inf.add("nDPS", String(d.number))
        inf.add("dCompet", day(d.competence, timeZone: d.timeZone))
        inf.add("tpEmit", "1")
        inf.add("cLocEmi", Nfse.onlyDigits(d.municipalityCode))

        // Prestador: só a inscrição e o regime; nome e endereço vêm do cadastro no Sistema Nacional.
        let prest = inf.add("prest")
        if !d.providerCnpj.isEmpty { prest.add("CNPJ", Nfse.onlyDigits(d.providerCnpj)) } else { prest.add("CPF", Nfse.onlyDigits(d.providerCpf)) }
        if !clean(d.providerMunicipalRegistration).isEmpty { prest.add("IM", clean(d.providerMunicipalRegistration)) }
        if !Nfse.onlyDigits(d.providerPhone).isEmpty { prest.add("fone", Nfse.onlyDigits(d.providerPhone)) }
        if !clean(d.providerEmail).isEmpty { prest.add("email", clean(d.providerEmail)) }
        let reg = prest.add("regTrib")
        reg.add("opSimpNac", String(d.simplesOption))
        if d.simplesOption == 3 { reg.add("regApTribSN", String(d.simplesRegime)) }
        reg.add("regEspTrib", String(d.specialRegime))

        // Tomador (o paciente ou o responsável).
        let toma = inf.add("toma")
        toma.add("CPF", Nfse.onlyDigits(d.takerCpf))
        toma.add("xNome", cut(clean(d.takerName), 300))
        let email = clean(d.takerEmail)
        if !email.isEmpty && email.count <= 80 { toma.add("email", email) }

        // Serviço
        let serv = inf.add("serv")
        serv.add("locPrest").add("cLocPrestacao", Nfse.onlyDigits(d.municipalityCode))
        let cServ = serv.add("cServ")
        cServ.add("cTribNac", Nfse.onlyDigits(d.taxCode))
        cServ.add("xDescServ", cut(clean(d.description, keepLineBreaks: true), 2000))
        if Nfse.onlyDigits(d.nbsCode).count == 9 { cServ.add("cNBS", Nfse.onlyDigits(d.nbsCode)) }

        // Valores e tributos
        let valores = inf.add("valores")
        valores.add("vServPrest").add("vServ", money(d.valueCents))
        let trib = valores.add("trib")
        let tribMun = trib.add("tribMun")
        tribMun.add("tribISSQN", "1")
        tribMun.add("tpRetISSQN", "1")
        let tot = trib.add("totTrib")
        let pct = percent(d.approxTaxSnPercent)
        if (d.simplesOption == 2 || d.simplesOption == 3) && !pct.isEmpty { tot.add("pTotTribSN", pct) } else { tot.add("indTotTrib", "0") }
        return root
    }

    /// Pedido de cancelamento (evento 101101). Motivos: 1 erro na emissão, 2 serviço não prestado, 9 outros.
    static func buildCancellation(environment: NfseEnvironment, accessKey: String, authorInscription: String, reasonCode: Int,
                                  reason: String, when: Date, timeZone: TimeZone = .current, appVersion: String = "Expediente-iOS") throws -> XmlNode {
        var problems: [String] = []
        if Nfse.onlyDigits(accessKey).count != 50 { problems.append("Chave de acesso inválida.") }
        if ![1, 2, 9].contains(reasonCode) { problems.append("Motivo do cancelamento inválido.") }
        let text = clean(reason)
        if text.count < 15 || text.count > 255 { problems.append("Explique o motivo com 15 a 255 caracteres.") }
        if !problems.isEmpty { throw NfseError.validation(problems) }
        let root = XmlNode("pedRegEvento", attributes: [("versao", Nfse.layoutVersion)])
        root.declaredNamespace = Nfse.namespace
        let inf = root.add("infPedReg", attributes: [("Id", cancellationID(accessKey))])
        inf.add("tpAmb", environment == .production ? "1" : "2")
        inf.add("verAplic", cut(clean(appVersion), 20))
        inf.add("dhEvento", dateTimeText(when, timeZone: timeZone))
        let insc = Nfse.onlyDigits(authorInscription)
        inf.add(insc.count == 11 ? "CPFAutor" : "CNPJAutor", insc)
        inf.add("chNFSe", Nfse.onlyDigits(accessKey))
        let e = inf.add("e101101")
        e.add("xDesc", "Cancelamento de NFS-e")
        e.add("cMotivo", String(reasonCode))
        e.add("xMotivo", text)
        return root
    }

    static func cancellationID(_ accessKey: String) -> String { "PRE" + Nfse.onlyDigits(accessKey) + "101101" }

    static func cancellationReasonLabel(_ code: Int) -> String {
        switch code {
        case 1: return "Erro na emissão"
        case 2: return "Serviço não prestado"
        default: return "Outros"
        }
    }

    // MARK: - Assinatura

    /// SignedInfo canônico (o que é assinado) para o elemento com o Id e o digest SHA-1 dado.
    static func signedInfo(referenceID: String, digest: String) -> XmlNode {
        let si = XmlNode("SignedInfo")
        si.add("CanonicalizationMethod", attributes: [("Algorithm", c14nURL)])
        si.add("SignatureMethod", attributes: [("Algorithm", dsigNamespace + "rsa-sha1")])
        let ref = si.add("Reference", attributes: [("URI", "#" + referenceID)])
        let transforms = ref.add("Transforms")
        transforms.add("Transform", attributes: [("Algorithm", dsigNamespace + "enveloped-signature")])
        transforms.add("Transform", attributes: [("Algorithm", c14nURL)])
        ref.add("DigestMethod", attributes: [("Algorithm", dsigNamespace + "sha1")])
        ref.add("DigestValue", digest)
        return si
    }

    /// Assinatura XMLDSig envelopada do primeiro filho da raiz (infDPS ou infPedReg): RSA-SHA1, C14N 1.0,
    /// certificado no KeyInfo. A Signature entra como último filho da raiz.
    static func sign(_ root: XmlNode, identity: XmlSigningIdentity) throws {
        guard let target = root.children.first, let id = target.attributes.first(where: { $0.0 == "Id" })?.1 else {
            throw NfseError.message("XML sem o elemento a assinar.")
        }
        let canonicalTarget = target.canonical(namespace: root.declaredNamespace)
        let digest = Data(Insecure.SHA1.hash(data: Data(canonicalTarget.utf8))).base64EncodedString()
        let si = signedInfo(referenceID: id, digest: digest)
        let canonicalSI = si.canonical(namespace: dsigNamespace)
        let value = try identity.signRSASHA1(Data(canonicalSI.utf8))
        let sig = XmlNode("Signature")
        sig.declaredNamespace = dsigNamespace
        sig.append(si)
        sig.add("SignatureValue", value.base64EncodedString())
        sig.add("KeyInfo").add("X509Data").add("X509Certificate", identity.certificateDER.base64EncodedString())
        root.append(sig)
    }

    /// Documento completo (com a declaração), pronto para enviar.
    static func xmlString(_ root: XmlNode) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + root.canonical(namespace: root.declaredNamespace)
    }
}
