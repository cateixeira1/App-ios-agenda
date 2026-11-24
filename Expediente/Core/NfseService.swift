import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Compression)
import Compression
#endif

// Conversa com o Sistema Nacional da NFS-e (Sefin Nacional) e emissão com proteção contra nota em dobro.
// Mesmas regras da versão para Windows.

struct NfseHTTPResponse: Equatable {
    var status: Int
    var body: Data
    var text: String { String(data: body, encoding: .utf8) ?? "" }
}

/// Conexão com o Sistema Nacional (TLS mútuo com o certificado do prestador). Erro lançado = sem resposta.
protocol NfseTransport {
    func send(method: String, url: URL, json: Data?) async throws -> NfseHTTPResponse
}

struct NfseMessageItem: Equatable {
    var code: String
    var description: String
    var text: String { code.isEmpty ? description : "\(code): \(description)" }
}

struct NfseCallResult {
    var success = false
    /// Não dá para saber se a nota foi gerada (falha de conexão, tempo esgotado, erro do servidor).
    var uncertain = false
    var status = 0
    var accessKey: String?
    var number: String?
    var xml: Data?
    var messages: [NfseMessageItem] = []

    var errorText: String {
        if !messages.isEmpty { return messages.map(\.text).joined(separator: "\n") }
        return status > 0 ? "Resposta \(status) do Sistema Nacional." : "Sem resposta do Sistema Nacional."
    }
}

enum Gzip {
    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    #if canImport(Compression)
    private static func process(_ input: Data, _ op: compression_stream_operation) -> Data? {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, op, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(stream) }
        let size = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        var out = Data()
        return input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data? in
            stream.pointee.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(buffer)
            stream.pointee.src_size = input.count
            while true {
                stream.pointee.dst_ptr = buffer
                stream.pointee.dst_size = size
                let status = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buffer, count: size - stream.pointee.dst_size)
                if status == COMPRESSION_STATUS_END { return out }
                if status == COMPRESSION_STATUS_ERROR { return nil }
            }
        }
    }

    /// Gzip (RFC 1952) com DEFLATE do sistema.
    static func compress(_ data: Data) -> Data {
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
        out.append(process(data, COMPRESSION_STREAM_ENCODE) ?? Data())
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4))
        out.append(Data(bytes: &size, count: 4))
        return out
    }

    static func decompress(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return process(Data(b[i..<(b.count - 8)]), COMPRESSION_STREAM_DECODE)
    }
    #else
    static func compress(_ data: Data) -> Data { data }
    static func decompress(_ data: Data) -> Data? { nil }
    #endif
}

/// Chamadas à API do Emissor Nacional.
struct NfseClient {
    let transport: NfseTransport
    let baseURL: String

    init(transport: NfseTransport, environment: NfseEnvironment) {
        self.transport = transport
        baseURL = Nfse.baseURL(environment)
    }

    static func gzipBase64(_ xml: String) -> String { Gzip.compress(Data(xml.utf8)).base64EncodedString() }

    static func fromGzipBase64(_ b64: String) -> Data? {
        guard let d = Data(base64Encoded: b64) else { return nil }
        return Gzip.decompress(d)
    }

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? s
    }

    private func send(_ method: String, _ path: String, _ json: [String: String]? = nil) async -> NfseHTTPResponse? {
        guard let url = URL(string: baseURL + path) else { return nil }
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return try? await transport.send(method: method, url: url, json: body)
    }

    func emit(_ signedXml: String) async -> NfseCallResult {
        NfseClient.parseIssued(await send("POST", "/nfse", ["dpsXmlGZipB64": NfseClient.gzipBase64(signedXml)]))
    }

    func get(_ accessKey: String) async -> NfseCallResult {
        NfseClient.parseIssued(await send("GET", "/nfse/" + escape(accessKey)))
    }

    /// Chave de acesso da nota gerada a partir da DPS; nil se a DPS não virou nota; erro se não deu para saber.
    func findByDps(_ dpsID: String) async throws -> String? {
        guard let res = await send("GET", "/dps/" + escape(NfseDps.apiID(dpsID))), res.status < 500,
              ![401, 403, 429].contains(res.status) else {
            throw NfseError.message("Não foi possível consultar o Sistema Nacional agora.")
        }
        if res.status >= 400 { return nil }
        let key = NfseClient.find(res.body, "chaveAcesso")
        return (key ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : key
    }

    /// Já existe nota para esta DPS (para não reutilizar um número já usado)?
    func dpsExists(_ dpsID: String) async throws -> Bool {
        guard let res = await send("HEAD", "/dps/" + escape(NfseDps.apiID(dpsID))), res.status < 500 else {
            throw NfseError.message("Não foi possível consultar o Sistema Nacional agora.")
        }
        return (200..<300).contains(res.status)
    }

    func cancel(_ accessKey: String, signedEventXml: String) async -> NfseCallResult {
        guard let res = await send("POST", "/nfse/" + escape(accessKey) + "/eventos",
                                   ["pedidoRegistroEventoXmlGZipB64": NfseClient.gzipBase64(signedEventXml)]) else {
            return NfseCallResult(uncertain: true)
        }
        if (200..<300).contains(res.status) { return NfseCallResult(success: true, status: res.status) }
        return NfseCallResult(uncertain: res.status >= 500, status: res.status, messages: NfseClient.messages(res.body))
    }

    static func parseIssued(_ res: NfseHTTPResponse?) -> NfseCallResult {
        guard let res else { return NfseCallResult(uncertain: true) }
        if (200..<300).contains(res.status) {
            let key = find(res.body, "chaveAcesso")
            let xml = find(res.body, "nfseXmlGZipB64").flatMap(fromGzipBase64)
            guard let key, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return NfseCallResult(uncertain: true, status: res.status) }
            return NfseCallResult(success: true, status: res.status, accessKey: key, number: xml.flatMap(numberFromXml), xml: xml)
        }
        return NfseCallResult(uncertain: res.status >= 500 || res.status == 429, status: res.status, messages: messages(res.body))
    }

    static func numberFromXml(_ xml: Data) -> String? {
        let text = String(data: xml, encoding: .utf8) ?? ""
        guard let re = try? NSRegularExpression(pattern: #"<(?:\w+:)?nNFSe>\s*([^<]+?)\s*</"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Procura um campo de texto em qualquer nível do JSON (sem diferenciar maiúsculas).
    static func find(_ json: Data, _ field: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else { return nil }
        return find(obj, field.lowercased())
    }

    private static func find(_ obj: Any, _ field: String) -> String? {
        if let dict = obj as? [String: Any] {
            for (k, v) in dict where k.lowercased() == field {
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
            }
            for (_, v) in dict { if let f = find(v, field) { return f } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let f = find(v, field) { return f } }
        }
        return nil
    }

    /// Mensagens de erro (objetos com "Codigo" e "Descricao", em qualquer nível).
    static func messages(_ json: Data) -> [NfseMessageItem] {
        guard let obj = try? JSONSerialization.jsonObject(with: json, options: [.fragmentsAllowed]) else {
            let t = (String(data: json, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : [NfseMessageItem(code: "", description: String(t.prefix(300)))]
        }
        var list: [NfseMessageItem] = []
        collect(obj, &list)
        return list
    }

    private static func collect(_ obj: Any, _ list: inout [NfseMessageItem]) {
        if let arr = obj as? [Any] { for v in arr { collect(v, &list) }; return }
        guard let dict = obj as? [String: Any] else { return }
        var code: String?, desc: String?, complement: String?
        for (k, v) in dict {
            let s = (v as? String) ?? (v as? NSNumber)?.stringValue
            guard let s else { continue }
            switch k.lowercased() {
            case "codigo": code = s
            case "descricao", "mensagem", "message": desc = s
            case "complemento": complement = s
            default: break
            }
        }
        if code != nil || desc != nil {
            let extra = (complement ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "" : " (\(complement!))"
            list.append(NfseMessageItem(code: code ?? "", description: (desc ?? "") + extra))
        }
        for (_, v) in dict where v is [String: Any] || v is [Any] { collect(v, &list) }
    }
}

/// Quem recebe a nota (tomador): o paciente ou o responsável.
struct NfseTaker: Equatable {
    var cpf: String
    var name: String
    var email: String

    static func forPatient(_ p: Patient) -> NfseTaker { NfseTaker(cpf: Nfse.onlyDigits(p.cpf), name: p.name, email: p.email) }

    static func forGuardian(_ p: Patient) -> NfseTaker? {
        let cpf = Nfse.onlyDigits(p.guardianCpf)
        guard !cpf.isEmpty else { return nil }
        let name = p.guardianName.trimmingCharacters(in: .whitespaces)
        return NfseTaker(cpf: cpf, name: name.isEmpty ? p.name : name, email: "")
    }
}

struct NfseOutcome: Equatable {
    var state: NfseState
    var message: String
}

/// Emissão da NFS-e de uma sessão, com proteção contra nota em dobro:
/// 1. cada sessão tem uma identificação de DPS própria, gravada antes do envio e repetida em todas as tentativas;
/// 2. se uma tentativa ficou sem resposta, o app consulta o Sistema Nacional pela DPS antes de enviar de novo;
/// 3. antes de usar um número novo, confere se ele já foi usado (ex.: outro aparelho com a mesma série).
@MainActor
final class NfseService {
    let store: Store
    var clock: () -> Date = { Date() }
    var appVersion = "Expediente-iOS"

    init(store: Store) { self.store = store }

    private var db: Database { store.db }

    static func providerInscription(_ f: FiscalProfile) -> String { Nfse.onlyDigits(f.document) }

    static func description(_ db: Database, _ a: Appointment) -> String {
        var t = db.fiscal.nfseDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty {
            t = (db.fiscal.serviceDescription.trimmingCharacters(in: .whitespaces).isEmpty ? "Atendimento" : db.fiscal.serviceDescription.trimmingCharacters(in: .whitespaces)) + " em {data}."
        }
        return t.replacingOccurrences(of: "{data}", with: Formatters.shortDate.string(from: a.start))
    }

    /// O que falta para emitir a nota deste atendimento (vazio = pode emitir).
    static func check(_ db: Database, _ a: Appointment, taker: NfseTaker?, now: Date) -> [String] {
        var p: [String] = []
        let f = db.fiscal
        if Billing.isNoCharge(a, in: db) {
            p.append(a.packageID != nil ? "Atendimento de pacote não gera nota sozinho: emita a nota do pacote pelo Emissor Nacional." : "Retorno sem custo não gera nota fiscal.")
        }
        if Nfse.taxCode(db).count != 6 { p.append("Informe o código de tributação nacional (6 dígitos) em Ajustes › Notas fiscais (NFS-e).") }
        if a.nfse?.state == .issued && !Nfse.isTestLeftover(a.nfse, fiscal: f) { p.append("Este atendimento já tem NFS-e emitida.") }
        if f.municipalityCode != Nfse.santoAndre { p.append("Nesta versão, a emissão automática atende só o município de Santo André (SP).") }
        let insc = providerInscription(f)
        if insc.count == 14 ? !NfseDps.isValidCNPJ(insc) : !NfseDps.isValidCPF(insc) { p.append("Preencha o CNPJ em Seus dados fiscais.") }
        if f.simplesOption == 3 && insc.count != 14 { p.append("Optante pelo Simples Nacional (ME/EPP) emite com o CNPJ.") }
        if db.price(of: a) <= 0 { p.append("Informe o valor do atendimento.") }
        if Calendar.current.startOfDay(for: a.start) > Calendar.current.startOfDay(for: now) {
            p.append("A nota só pode ser emitida a partir do dia do atendimento (\(Formatters.shortDate.string(from: a.start))).")
        }
        if let taker, !taker.cpf.isEmpty {
            if !NfseDps.isValidCPF(taker.cpf) { p.append("O CPF do tomador não é válido. Confira o cadastro do \(Term.client).") }
        } else {
            p.append("Cadastre o CPF do \(Term.client) (ou do responsável) para emitir a nota.")
        }
        return p
    }

    func prepare(_ a: Appointment, taker: NfseTaker, reserved: NfseInfo) -> DpsData {
        let f = db.fiscal
        let insc = NfseService.providerInscription(f)
        var d = DpsData()
        d.environment = reserved.environment
        d.issuedAt = clock().addingTimeInterval(-60)
        d.series = reserved.series
        d.number = reserved.dpsNumber
        d.competence = a.start
        d.municipalityCode = f.municipalityCode
        d.providerCnpj = insc.count == 14 ? insc : ""
        d.providerCpf = insc.count == 11 ? insc : ""
        d.providerMunicipalRegistration = f.municipalRegistration.trimmingCharacters(in: .whitespaces)
        d.providerPhone = f.fiscalPhone
        d.providerEmail = f.fiscalEmail.trimmingCharacters(in: .whitespaces)
        d.simplesOption = f.simplesOption
        d.simplesRegime = f.simplesRegime
        d.specialRegime = f.specialRegime
        d.takerCpf = taker.cpf
        d.takerName = taker.name
        d.takerEmail = taker.email
        d.taxCode = Nfse.taxCode(db)
        d.nbsCode = Nfse.onlyDigits(f.nbsCode)
        d.description = NfseService.description(db, a)
        d.valueCents = db.price(of: a)
        d.approxTaxSnPercent = f.approxTaxPercent
        d.appVersion = appVersion
        return d
    }

    func issue(_ appointmentID: UUID, taker: NfseTaker, identity: XmlSigningIdentity, transport: NfseTransport) async throws -> NfseOutcome {
        guard var a = store.appointment(appointmentID) else { throw NfseError.message("Atendimento não encontrado.") }
        if Nfse.isTestLeftover(a.nfse, fiscal: db.fiscal) {
            store.archiveTestNfse(appointmentID)
            a = store.appointment(appointmentID)!
        }
        if let done = a.nfse, done.state == .issued {
            return NfseOutcome(state: .issued, message: "Este atendimento já tem a NFS-e nº \(done.number ?? "").")
        }
        let problems = NfseService.check(db, a, taker: taker, now: clock())
        if !problems.isEmpty { throw NfseError.validation(problems) }
        let env = (a.nfse.map { $0.state != .cancelled } ?? false) ? a.nfse!.environment : db.fiscal.environment
        let client = NfseClient(transport: transport, environment: env)
        let insc = NfseService.providerInscription(db.fiscal)

        // 1. Tentativa anterior sem resposta: confere se a nota já existe antes de enviar de novo.
        if let pending = a.nfse, pending.state == .unknown, pending.lastAttemptAt != nil {
            let key: String?
            do { key = try await client.findByDps(pending.dpsId) } catch {
                return NfseOutcome(state: .unknown, message: "Não foi possível conferir a tentativa anterior no Sistema Nacional. Nada foi enviado de novo. Tente mais tarde.")
            }
            if let key { return await recovered(appointmentID, client, key) }
        }

        // 2. Número novo: pula números que já viraram nota.
        if a.nfse == nil || a.nfse?.state == .cancelled {
            for _ in 0..<20 {
                let used: Bool
                do { used = try await client.dpsExists(store.peekDpsID(inscription: insc)) } catch {
                    return NfseOutcome(state: .rejected, message: "Sem conexão com o Sistema Nacional da NFS-e. Nada foi enviado. Confira a internet e tente de novo.")
                }
                if !used { break }
                store.skipDpsNumber()
            }
            _ = try store.reserveDps(appointmentID, inscription: insc)
        }
        guard let info = store.appointment(appointmentID)?.nfse else { throw NfseError.message("Atendimento não encontrado.") }

        // 3. Monta, assina e grava a tentativa antes de enviar.
        let data = prepare(a, taker: taker, reserved: info)
        let xml = try NfseDps.build(data)
        try NfseDps.sign(xml, identity: identity)
        let text = NfseDps.xmlString(xml)
        let attemptAt = clock()
        store.updateNfse(appointmentID) { n in
            n.state = .unknown
            n.lastAttemptAt = attemptAt
            n.takerName = taker.name
            n.takerDocument = taker.cpf
            n.valueCents = data.valueCents
            n.lastError = nil
        }

        let result = await client.emit(text)
        if result.success, let key = result.accessKey { return markIssued(appointmentID, key, result.number, result.xml) }

        // Recusada ou sem resposta: confere pela DPS (uma resposta perdida pode esconder uma nota gerada).
        if let found = try? await client.findByDps(info.dpsId) { return await recovered(appointmentID, client, found) }

        if result.uncertain {
            store.updateNfse(appointmentID) { $0.lastError = result.errorText }
            return NfseOutcome(state: .unknown, message: "O Sistema Nacional não respondeu. A nota pode ou não ter sido gerada: o app vai conferir antes de qualquer novo envio. Use “Conferir” em alguns minutos.")
        }
        store.updateNfse(appointmentID) { n in
            n.state = .rejected
            n.lastError = result.errorText
        }
        return NfseOutcome(state: .rejected, message: "A nota foi recusada:\n" + result.errorText)
    }

    /// Confere uma tentativa sem resposta (sem enviar nada).
    func checkPending(_ appointmentID: UUID, transport: NfseTransport) async -> NfseOutcome {
        guard let info = store.appointment(appointmentID)?.nfse else {
            return NfseOutcome(state: .rejected, message: "Nenhuma tentativa de emissão neste atendimento.")
        }
        if info.state == .issued { return NfseOutcome(state: .issued, message: "NFS-e nº \(info.number ?? "") emitida.") }
        let client = NfseClient(transport: transport, environment: info.environment)
        let key: String?
        do { key = try await client.findByDps(info.dpsId) } catch {
            return NfseOutcome(state: .unknown, message: "Não foi possível consultar o Sistema Nacional agora. Tente de novo em alguns minutos.")
        }
        if let key { return await recovered(appointmentID, client, key) }
        if info.state == .unknown {
            store.updateNfse(appointmentID) { n in
                n.state = .rejected
                n.lastError = "A tentativa anterior não gerou nota. Pode emitir de novo."
            }
            return NfseOutcome(state: .rejected, message: "A tentativa anterior não gerou nota. Pode emitir de novo com segurança.")
        }
        return NfseOutcome(state: info.state, message: info.lastError ?? info.state.label)
    }

    private func recovered(_ appointmentID: UUID, _ client: NfseClient, _ key: String) async -> NfseOutcome {
        let got = await client.get(key)
        return markIssued(appointmentID, key, got.success ? got.number : nil, got.success ? got.xml : nil)
    }

    private func markIssued(_ appointmentID: UUID, _ accessKey: String, _ number: String?, _ xml: Data?) -> NfseOutcome {
        let xmlID = xml.flatMap { try? store.writeAttachment($0) }
        let when = clock()
        store.updateNfse(appointmentID) { n in
            n.state = .issued
            n.accessKey = accessKey
            n.number = number ?? n.number ?? "(consultar)"
            n.issuedAt = when
            n.lastError = nil
            if let xmlID { n.xmlAttachmentID = xmlID }
        }
        let a = store.appointment(appointmentID)
        let number = a?.nfse?.number ?? ""
        store.audit(.nfseIssued, "NFS-e nº \(number) · \(db.patient(a?.patientID)?.name ?? "") · \(a?.nfse?.environment.shortLabel ?? "")")
        return NfseOutcome(state: .issued, message: "NFS-e nº \(number) emitida.")
    }

    func cancel(_ appointmentID: UUID, reasonCode: Int, reason: String, identity: XmlSigningIdentity, transport: NfseTransport) async throws -> NfseOutcome {
        guard let info = store.appointment(appointmentID)?.nfse, info.state == .issued, let key = info.accessKey else {
            return NfseOutcome(state: .rejected, message: "Este atendimento não tem NFS-e emitida para cancelar.")
        }
        let doc = try NfseDps.buildCancellation(environment: info.environment, accessKey: key,
                                                authorInscription: NfseService.providerInscription(db.fiscal), reasonCode: reasonCode,
                                                reason: reason, when: clock().addingTimeInterval(-60), appVersion: appVersion)
        try NfseDps.sign(doc, identity: identity)
        let result = await NfseClient(transport: transport, environment: info.environment).cancel(key, signedEventXml: NfseDps.xmlString(doc))
        guard result.success else {
            return NfseOutcome(state: .issued, message: result.uncertain
                ? "O Sistema Nacional não respondeu. Confira a nota no portal antes de tentar cancelar de novo."
                : "O cancelamento foi recusado:\n" + result.errorText)
        }
        let when = clock()
        store.update { db in
            guard let i = db.appointments.firstIndex(where: { $0.id == appointmentID }) else { return }
            db.appointments[i].nfse?.state = .cancelled
            db.appointments[i].nfse?.cancelledAt = when
            db.appointments[i].invoiceNumber = nil
            db.appointments[i].invoiceIssuedAt = nil
        }
        try? store.saveNow()
        store.audit(.nfseCancelled, "NFS-e nº \(info.number ?? "") · \(NfseDps.cancellationReasonLabel(reasonCode))")
        return NfseOutcome(state: .cancelled, message: "NFS-e nº \(info.number ?? "") cancelada.")
    }

    func xml(_ a: Appointment) -> Data? {
        guard let id = a.nfse?.xmlAttachmentID else { return nil }
        return try? store.readAttachment(id)
    }

    static func summary(_ db: Database, _ a: Appointment, taker: NfseTaker) -> String {
        let f = db.fiscal
        let im = f.municipalRegistration.isEmpty ? "" : " · IM \(f.municipalRegistration)"
        return [
            "Prestador: CNPJ \(Masks.cnpj(providerInscription(f)))\(im)",
            "Tomador: \(taker.name) · CPF \(Masks.cpf(taker.cpf))",
            "Serviço: \(Nfse.taxCodeLabel(Nfse.taxCode(db)))",
            "Descrição: \(description(db, a))",
            "Valor: \(Formatters.money(db.price(of: a)))",
            "Competência: \(Formatters.shortDate.string(from: a.start)) · Local: \(Nfse.santoAndreName)",
        ].joined(separator: "\n")
    }
}
