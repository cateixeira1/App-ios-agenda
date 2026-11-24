import CryptoKit
import Foundation

enum AuditEvent: String, Codable, CaseIterable {
    case accountCreated
    case loginPassword
    case loginBiometrics
    case loginRecoveryKey
    case loginFailed
    case locked
    case passwordChanged
    case recoveryKeyRegenerated
    case biometricsEnabled
    case biometricsDisabled
    case recordExported
    case reportExported
    case backupExported
    case backupRestored
    case patientDeleted
    case consentAttached
    case logAnchorReset
    case certificateAdded
    case certificateRemoved
    case nfseIssued
    case nfseCancelled

    var label: String {
        switch self {
        case .accountCreated: return "Conta criada"
        case .loginPassword: return "Acesso com senha"
        case .loginBiometrics: return "Acesso com biometria"
        case .loginRecoveryKey: return "Acesso com chave de recuperação"
        case .loginFailed: return "Tentativa de acesso recusada"
        case .locked: return "App bloqueado"
        case .passwordChanged: return "Senha alterada"
        case .recoveryKeyRegenerated: return "Nova chave de recuperação"
        case .biometricsEnabled: return "Biometria ativada"
        case .biometricsDisabled: return "Biometria desativada"
        case .recordExported: return "Anotação exportada ou enviada"
        case .reportExported: return "Relatório exportado"
        case .backupExported: return "Backup exportado"
        case .backupRestored: return "Backup restaurado"
        case .patientDeleted: return "Cadastro excluído"
        case .consentAttached: return "Documento anexado ao cadastro"
        case .logAnchorReset: return "Registro iniciado neste aparelho"
        case .certificateAdded: return "Certificado digital adicionado"
        case .certificateRemoved: return "Certificado digital removido"
        case .nfseIssued: return "NFS-e emitida"
        case .nfseCancelled: return "NFS-e cancelada"
        }
    }

    var symbol: String {
        switch self {
        case .loginPassword, .loginBiometrics, .loginRecoveryKey: return "person.badge.key"
        case .loginFailed: return "exclamationmark.shield"
        case .locked: return "lock"
        case .recordExported, .reportExported, .backupExported: return "square.and.arrow.up"
        case .backupRestored: return "arrow.down.doc"
        case .patientDeleted, .certificateRemoved: return "trash"
        case .certificateAdded: return "checkmark.seal"
        case .nfseIssued, .nfseCancelled: return "doc.text"
        default: return "gearshape"
        }
    }
}

struct AuditEntry: Codable, Identifiable, Equatable {
    var id: Int
    var timestampMillis: Int64
    var actor: String
    var device: String
    var event: AuditEvent
    var detail: String
    var previousHash: String
    var hash: String

    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestampMillis) / 1000) }

    static func computeHash(id: Int, timestampMillis: Int64, actor: String, device: String,
                            event: AuditEvent, detail: String, previousHash: String) -> String {
        let payload = [String(id), String(timestampMillis), actor, device, event.rawValue, detail, previousHash]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var expectedHash: String {
        AuditEntry.computeHash(id: id, timestampMillis: timestampMillis, actor: actor, device: device,
                               event: event, detail: detail, previousHash: previousHash)
    }
}

/// Guarda a contagem e o último hash fora do arquivo do registro, para detectar apagamentos.
protocol AuditAnchorStore {
    func load() -> (count: Int, lastHash: String)?
    func save(count: Int, lastHash: String)
    func clear()
}

struct KeychainAnchorStore: AuditAnchorStore {
    let account = "audit-anchor"

    func load() -> (count: Int, lastHash: String)? {
        guard let data = Keychain.get(account: account),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "|")
        guard parts.count == 2, let count = Int(parts[0]) else { return nil }
        return (count, String(parts[1]))
    }

    func save(count: Int, lastHash: String) {
        Keychain.set(Data("\(count)|\(lastHash)".utf8), account: account)
    }

    func clear() { Keychain.delete(account: account) }
}

final class MemoryAnchorStore: AuditAnchorStore {
    var value: (count: Int, lastHash: String)?
    func load() -> (count: Int, lastHash: String)? { value }
    func save(count: Int, lastHash: String) { value = (count, lastHash) }
    func clear() { value = nil }
}

enum AuditIntegrity: Equatable {
    case intact
    case tampered(String)

    var isIntact: Bool { self == .intact }
}

/// Registro de acessos: só aceita novos itens. Cada item leva o hash do anterior (cadeia SHA-256),
/// então qualquer alteração, inclusão no meio ou remoção é detectada.
final class AuditLog {
    static let genesisHash = String(repeating: "0", count: 64)
    static let fileName = "log.bin"

    private(set) var entries: [AuditEntry] = []
    private let vault: Vault
    private let key: SymmetricKey
    private let anchor: AuditAnchorStore

    init(vault: Vault, key: SymmetricKey, anchor: AuditAnchorStore) throws {
        self.vault = vault
        self.key = key
        self.anchor = anchor
        if let data = try vault.readSealed(name: AuditLog.fileName, key: key) {
            entries = try JSONDecoder().decode([AuditEntry].self, from: data)
        }
    }

    /// Identificação do aparelho, sem depender da interface (ex.: "iPhone15,2 · iOS 18.1").
    static let deviceName: String = {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if targetEnvironment(simulator)
        let model = "Simulador"
        #else
        let model = machine
        #endif
        return "\(model) · iOS \(v.majorVersion).\(v.minorVersion)"
    }()

    @discardableResult
    func append(_ event: AuditEvent, actor: String, detail: String = "", date: Date = Date()) throws -> AuditEntry {
        let id = (entries.last?.id ?? 0) + 1
        let prev = entries.last?.hash ?? AuditLog.genesisHash
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let device = AuditLog.deviceName
        let hash = AuditEntry.computeHash(id: id, timestampMillis: millis, actor: actor, device: device,
                                          event: event, detail: detail, previousHash: prev)
        let entry = AuditEntry(id: id, timestampMillis: millis, actor: actor, device: device, event: event,
                               detail: detail, previousHash: prev, hash: hash)
        entries.append(entry)
        try persist()
        anchor.save(count: entries.count, lastHash: hash)
        return entry
    }

    private func persist() throws {
        try vault.writeSealed(try JSONEncoder().encode(entries), name: AuditLog.fileName, key: key)
    }

    /// Recomeça a âncora a partir do registro atual (conta nova ou backup restaurado em outro aparelho).
    func resetAnchor() {
        if let last = entries.last {
            anchor.save(count: entries.count, lastHash: last.hash)
        } else {
            anchor.clear()
        }
    }

    func verify() -> AuditIntegrity {
        AuditLog.verify(entries: entries, anchor: anchor.load())
    }

    static func verify(entries: [AuditEntry], anchor: (count: Int, lastHash: String)?) -> AuditIntegrity {
        var prev = genesisHash
        for (index, entry) in entries.enumerated() {
            if entry.id != index + 1 {
                return .tampered("A numeração do registro foi alterada perto do item \(index + 1).")
            }
            if entry.previousHash != prev {
                return .tampered("O item \(entry.id) não se encaixa no anterior.")
            }
            if entry.expectedHash != entry.hash {
                return .tampered("O item \(entry.id) foi alterado depois de gravado.")
            }
            prev = entry.hash
        }
        if let anchor {
            if anchor.count != entries.count || anchor.lastHash != (entries.last?.hash ?? "") {
                return .tampered("Itens do registro foram apagados ou substituídos.")
            }
        }
        return .intact
    }

    // MARK: - Tentativas antes de entrar

    /// Tentativas recusadas acontecem antes de existir a chave; ficam numa lista à parte
    /// e entram no registro no próximo acesso.
    static func recordPendingFailure(in vault: Vault, detail: String, date: Date = Date()) {
        var list = pendingFailures(in: vault)
        list.append(PendingFailure(timestampMillis: Int64(date.timeIntervalSince1970 * 1000), detail: detail))
        if let data = try? JSONEncoder().encode(list) {
            _ = try? data.write(to: vault.url(for: "pending.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    static func pendingFailures(in vault: Vault) -> [PendingFailure] {
        guard let data = try? Data(contentsOf: vault.url(for: "pending.json")) else { return [] }
        return (try? JSONDecoder().decode([PendingFailure].self, from: data)) ?? []
    }

    func flushPendingFailures(actor: String) {
        let pending = AuditLog.pendingFailures(in: vault)
        for item in pending {
            let date = Date(timeIntervalSince1970: TimeInterval(item.timestampMillis) / 1000)
            let when = AuditLog.dateFormatter.string(from: date)
            _ = try? append(.loginFailed, actor: actor, detail: "\(item.detail) em \(when)")
        }
        try? FileManager.default.removeItem(at: vault.url(for: "pending.json"))
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy 'às' HH:mm:ss"
        return f
    }()
}

struct PendingFailure: Codable, Equatable {
    var timestampMillis: Int64
    var detail: String
}
