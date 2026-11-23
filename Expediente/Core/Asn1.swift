import Foundation

/// Leitura e escrita mínimas de DER (ASN.1), para ler certificados ICP-Brasil e montar a assinatura CMS dos PDFs.
enum DER {
    struct Node {
        var tag: UInt8
        /// Bytes do elemento inteiro (tag + tamanho + conteúdo).
        var raw: Data
        var content: Data

        var isConstructed: Bool { tag & 0x20 != 0 }
        var tagClass: UInt8 { tag & 0xC0 }
        var tagNumber: UInt8 { tag & 0x1F }

        func children() throws -> [Node] { try DER.parseAll(content) }
    }

    struct Failure: Error {}

    static func parse(_ data: Data) throws -> Node {
        let b = [UInt8](data)
        var i = 0
        let n = try read(b, &i)
        return n
    }

    static func parseAll(_ data: Data) throws -> [Node] {
        let b = [UInt8](data)
        var i = 0
        var out: [Node] = []
        while i < b.count { out.append(try read(b, &i)) }
        return out
    }

    private static func read(_ b: [UInt8], _ i: inout Int) throws -> Node {
        guard i + 2 <= b.count else { throw Failure() }
        let start = i
        let tag = b[i]
        i += 1
        guard tag & 0x1F != 0x1F else { throw Failure() } // tags longos não aparecem nos certificados usados aqui
        var len = Int(b[i])
        i += 1
        if len & 0x80 != 0 {
            let count = len & 0x7F
            guard count > 0, count <= 4, i + count <= b.count else { throw Failure() }
            len = 0
            for _ in 0..<count {
                len = (len << 8) | Int(b[i])
                i += 1
            }
        }
        guard len >= 0, i + len <= b.count else { throw Failure() }
        let content = Data(b[i..<(i + len)])
        i += len
        return Node(tag: tag, raw: Data(b[start..<i]), content: content)
    }

    // MARK: - Escrita

    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var d = Data([tag])
        d.append(length(content.count))
        d.append(content)
        return d
    }

    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.reduce(Data(), +)) }
    static func contextExplicit(_ n: UInt8, _ content: Data) -> Data { tlv(0xA0 | n, content) }
    static func contextImplicit(_ n: UInt8, constructed: Bool, _ content: Data) -> Data { tlv((constructed ? 0xA0 : 0x80) | n, content) }
    static func octetString(_ d: Data) -> Data { tlv(0x04, d) }
    static var null: Data { Data([0x05, 0x00]) }

    static func integer(_ v: Int) -> Data {
        var bytes: [UInt8] = []
        var x = v
        repeat {
            bytes.insert(UInt8(x & 0xFF), at: 0)
            x >>= 8
        } while x > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return tlv(0x06, Data()) }
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for p in parts.dropFirst(2) {
            var stack: [UInt8] = [UInt8(p & 0x7F)]
            var v = p >> 7
            while v > 0 {
                stack.insert(UInt8(v & 0x7F) | 0x80, at: 0)
                v >>= 7
            }
            out += stack
        }
        return tlv(0x06, Data(out))
    }

    static func oidString(_ content: Data) -> String {
        let b = [UInt8](content)
        guard let first = b.first else { return "" }
        var parts = [String(first / 40), String(first % 40)]
        var v: UInt64 = 0
        for byte in b.dropFirst() {
            v = (v << 7) | UInt64(byte & 0x7F)
            if byte & 0x80 == 0 {
                parts.append(String(v))
                v = 0
            }
        }
        return parts.joined(separator: ".")
    }

    static func utcTime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(f.string(from: date).utf8))
    }

    /// UTCTime ou GeneralizedTime.
    static func time(_ n: Node) -> Date? {
        guard let s = String(data: n.content, encoding: .ascii) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = n.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }

    /// Texto de qualquer tipo de string ASN.1.
    static func string(_ n: Node) -> String {
        switch n.tag {
        case 0x1E: // BMPString
            var chars: [UInt16] = []
            let b = [UInt8](n.content)
            var i = 0
            while i + 1 < b.count {
                chars.append(UInt16(b[i]) << 8 | UInt16(b[i + 1]))
                i += 2
            }
            return String(utf16CodeUnits: chars, count: chars.count)
        case 0x0C:
            return String(data: n.content, encoding: .utf8) ?? ""
        default:
            return String(data: n.content, encoding: .utf8) ?? String(data: n.content, encoding: .isoLatin1) ?? ""
        }
    }
}

// MARK: - Certificado X.509

/// O que o app precisa de um certificado: titular, CPF/CNPJ (ICP-Brasil), emissor, validade e os campos da assinatura CMS.
struct X509Info {
    var der: Data
    var subjectCN = ""
    var issuerCN = ""
    var issuerText = ""
    var notBefore = Date.distantPast
    var notAfter = Date.distantPast
    /// Número de série (hexadecimal em maiúsculas, como o Windows mostra).
    var serialHex = ""
    /// SHA-1 do certificado, em hexadecimal maiúsculo (o "thumbprint" do Windows).
    var thumbprint = ""
    /// DER do emissor (Name) e do número de série (INTEGER), para o IssuerAndSerialNumber do CMS.
    var issuerDER = Data()
    var serialDER = Data()
    var otherNames: [(oid: String, value: String)] = []
    var hasRSAKey = false

    static let oidCN = "2.5.4.3"
    static let oidPersonData = "2.16.76.1.3.1"
    static let oidCnpj = "2.16.76.1.3.3"
    static let oidResponsibleData = "2.16.76.1.3.4"

    var isIcpBrasil: Bool { issuerText.localizedCaseInsensitiveContains("ICP-Brasil") }

    /// CPF (e-CPF ou do responsável no e-CNPJ) e CNPJ (e-CNPJ).
    var documents: (cpf: String?, cnpj: String?) {
        var cpf: String?, cnpj: String?
        for (oid, value) in otherNames {
            let d = value.filter(\.isASCIIDigit)
            switch oid {
            case X509Info.oidPersonData, X509Info.oidResponsibleData:
                if d.count >= 19, cpf == nil { cpf = String(Array(d)[8..<19]) }
            case X509Info.oidCnpj:
                if d.count >= 14 { cnpj = String(d.prefix(14)) }
            default: break
            }
        }
        if cpf == nil && cnpj == nil, let i = subjectCN.lastIndex(of: ":") {
            let tail = subjectCN[subjectCN.index(after: i)...].filter(\.isASCIIDigit)
            if tail.count == 11 { cpf = String(tail) } else if tail.count == 14 { cnpj = String(tail) }
        }
        return (cpf, cnpj)
    }

    /// O CN da ICP-Brasil costuma ser "NOME:CPF"; fica só o nome.
    var holderName: String {
        if let i = subjectCN.lastIndex(of: ":") {
            let tail = subjectCN[subjectCN.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, tail.allSatisfy(\.isASCIIDigit) { return subjectCN[..<i].trimmingCharacters(in: .whitespaces) }
        }
        return subjectCN.trimmingCharacters(in: .whitespaces)
    }

    static func parse(_ der: Data, sha1: (Data) -> Data) throws -> X509Info {
        var info = X509Info(der: der)
        info.thumbprint = sha1(der).map { String(format: "%02X", $0) }.joined()
        let cert = try DER.parse(der)
        let parts = try cert.children()
        guard let tbs = parts.first else { throw DER.Failure() }
        var fields = try tbs.children()
        if fields.first?.tag == 0xA0 { fields.removeFirst() } // versão
        guard fields.count >= 6 else { throw DER.Failure() }
        info.serialDER = fields[0].raw
        info.serialHex = fields[0].content.drop(while: { $0 == 0 }).map { String(format: "%02X", $0) }.joined()
        info.issuerDER = fields[2].raw
        let issuer = try names(fields[2])
        info.issuerCN = issuer.first { $0.oid == oidCN }?.value ?? ""
        info.issuerText = issuer.map(\.value).joined(separator: ", ")
        let validity = try fields[3].children()
        if validity.count == 2 {
            info.notBefore = DER.time(validity[0]) ?? .distantPast
            info.notAfter = DER.time(validity[1]) ?? .distantPast
        }
        info.subjectCN = try names(fields[4]).first { $0.oid == oidCN }?.value ?? ""
        if let alg = try fields[5].children().first?.children().first {
            info.hasRSAKey = DER.oidString(alg.content) == "1.2.840.113549.1.1.1"
        }
        for f in fields.dropFirst(6) where f.tag == 0xA3 {
            guard let exts = try f.children().first?.children() else { continue }
            for ext in exts {
                let items = try ext.children()
                guard let id = items.first, DER.oidString(id.content) == "2.5.29.17", let value = items.last, value.tag == 0x04 else { continue }
                info.otherNames = otherNamesFrom(san: value.content)
            }
        }
        return info
    }

    private static func names(_ name: DER.Node) throws -> [(oid: String, value: String)] {
        var out: [(String, String)] = []
        for rdn in try name.children() {
            for atv in try rdn.children() {
                let kv = try atv.children()
                if kv.count == 2 { out.append((DER.oidString(kv[0].content), DER.string(kv[1]))) }
            }
        }
        return out
    }

    /// otherName ::= [0] IMPLICIT SEQUENCE { type-id OID, value [0] EXPLICIT ANY }
    static func otherNamesFrom(san: Data) -> [(oid: String, value: String)] {
        var out: [(String, String)] = []
        guard let seq = try? DER.parse(san), let names = try? seq.children() else { return out }
        for n in names where n.tag == 0xA0 {
            guard let inner = try? n.children(), inner.count >= 2, inner[0].tag == 0x06,
                  let wrapped = try? inner[1].children().first else { continue }
            out.append((DER.oidString(inner[0].content), DER.string(wrapped)))
        }
        return out
    }

    /// Descrição para a lista de certificados do app.
    func entry(kind: CertificateKind = .a1, now: Date = Date()) -> CertificateEntry {
        let docs = documents
        var e = CertificateEntry()
        e.kind = kind
        e.subject = subjectCN
        e.holderName = holderName
        e.holderCpf = docs.cpf ?? ""
        e.holderCnpj = docs.cnpj ?? ""
        e.issuer = issuerCN.isEmpty ? issuerText : issuerCN
        e.notBefore = notBefore
        e.notAfter = notAfter
        e.thumbprint = thumbprint
        e.serialNumber = serialHex
        e.isIcpBrasil = isIcpBrasil
        e.addedAt = now
        return e
    }
}

// MARK: - Assinatura CMS (PAdES)

/// Monta a assinatura CMS destacada (SignedData) usada no PDF: SHA-256 com RSA, com o atributo
/// signing-certificate-v2 (exigido pelo PAdES), sem signingTime (no PAdES a hora vai no dicionário do PDF).
enum CMSSigner {
    static let oidData = "1.2.840.113549.1.7.1"
    static let oidSignedData = "1.2.840.113549.1.7.2"
    static let oidSHA256 = "2.16.840.1.101.3.4.2.1"
    static let oidRSA = "1.2.840.113549.1.1.1"
    static let oidSHA256WithRSA = "1.2.840.113549.1.1.11"
    static let oidContentType = "1.2.840.113549.1.9.3"
    static let oidMessageDigest = "1.2.840.113549.1.9.4"
    static let oidSigningCertificateV2 = "1.2.840.113549.1.9.16.2.47"

    /// - Parameters:
    ///   - digest: SHA-256 dos bytes assinados do PDF.
    ///   - certificate: certificado do signatário.
    ///   - chain: outros certificados da cadeia (opcional).
    ///   - certificateHash: SHA-256 do certificado (para o signing-certificate-v2).
    ///   - sign: assina os bytes com RSA PKCS#1 v1.5 e SHA-256.
    static func signedData(digest: Data, certificate: X509Info, chain: [Data] = [], certificateHash: Data,
                           sign: (Data) throws -> Data) throws -> Data {
        let sha256Alg = DER.sequence([DER.oid(oidSHA256)])
        // ESSCertIDv2 com o algoritmo padrão (SHA-256) omitido.
        let issuerSerial = DER.sequence([
            DER.sequence([DER.contextImplicit(4, constructed: true, certificate.issuerDER)]),
            certificate.serialDER,
        ])
        let essCertID = DER.sequence([DER.octetString(certificateHash), issuerSerial])
        let signingCertV2 = DER.sequence([DER.sequence([essCertID])])
        let attrs = [
            DER.sequence([DER.oid(oidContentType), DER.set([DER.oid(oidData)])]),
            DER.sequence([DER.oid(oidMessageDigest), DER.set([DER.octetString(digest)])]),
            DER.sequence([DER.oid(oidSigningCertificateV2), DER.set([signingCertV2])]),
        ]
        // A assinatura é feita sobre o SET (tag 0x31); no SignerInfo os atributos vão com a tag [0].
        let attrsSet = DER.set(attrs)
        let signature = try sign(attrsSet)
        var signedAttrsTagged = attrsSet
        signedAttrsTagged[0] = 0xA0
        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([certificate.issuerDER, certificate.serialDER]),
            sha256Alg,
            signedAttrsTagged,
            DER.sequence([DER.oid(oidSHA256WithRSA), DER.null]),
            DER.octetString(signature),
        ])
        let certs = DER.contextImplicit(0, constructed: true, ([certificate.der] + chain).reduce(Data(), +))
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([sha256Alg]),
            DER.sequence([DER.oid(oidData)]),
            certs,
            DER.set([signerInfo]),
        ])
        return DER.sequence([DER.oid(oidSignedData), DER.contextExplicit(0, signedData)])
    }
}
