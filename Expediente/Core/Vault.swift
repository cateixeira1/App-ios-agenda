import CommonCrypto
import CryptoKit
import Foundation

enum VaultError: LocalizedError, Equatable {
    case notFound
    case wrongCredentials
    case wrongRecoveryKey
    case weakPassword
    case corrupted
    case keyDerivationFailed

    var errorDescription: String? {
        switch self {
        case .notFound: return "Nenhuma conta foi encontrada neste aparelho."
        case .wrongCredentials: return "E-mail ou senha incorretos."
        case .wrongRecoveryKey: return "A chave de recuperação não confere. Confira as letras e os números."
        case .weakPassword: return "A senha precisa ter pelo menos 8 caracteres."
        case .corrupted: return "Os dados não puderam ser lidos. O arquivo pode estar danificado."
        case .keyDerivationFailed: return "Não foi possível preparar a chave de segurança."
        }
    }
}

/// Informações públicas da conta, gravadas sem cifra. Não contêm dados de clientes.
/// A chave dos dados aparece aqui só embrulhada (cifrada) pela senha e pela chave de recuperação.
struct VaultMeta: Codable, Equatable {
    var version = 1
    var email: String
    var firstName: String
    var salt: Data
    var iterations: Int
    var passwordWrapped: Data
    var recoverySalt: Data
    var recoveryWrapped: Data
    var createdAt: Date
}

enum KeyDerivation {
    /// PBKDF2-HMAC-SHA256. A senha é normalizada (NFC) para que acentos digitados de jeitos diferentes deem a mesma chave.
    static func pbkdf2(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        let normalized = password.precomposedStringWithCanonicalMapping
        let passwordLength = normalized.utf8.count
        var derived = [UInt8](repeating: 0, count: 32)
        let derivedCount = derived.count
        let status: Int32 = normalized.withCString { pwChars in
            salt.withUnsafeBytes { saltRaw in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwChars, passwordLength,
                    saltRaw.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derived, derivedCount)
            }
        }
        guard status == Int32(kCCSuccess) else { throw VaultError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "Gerador aleatório indisponível")
        return Data(bytes)
    }
}

/// Chave de recuperação: 160 bits em base32 (alfabeto de Crockford), mostrada em 8 grupos de 4.
enum RecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func generate() -> String {
        format(encode(KeyDerivation.randomBytes(20)))
    }

    static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var out = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(value >> (bits - 5)) & 31])
                bits -= 5
            }
            value &= (1 << bits) - 1
        }
        if bits > 0 { out.append(alphabet[(value << (5 - bits)) & 31]) }
        return out
    }

    static func format(_ raw: String) -> String {
        stride(from: 0, to: raw.count, by: 4).map { i -> String in
            let start = raw.index(raw.startIndex, offsetBy: i)
            let end = raw.index(start, offsetBy: min(4, raw.count - i))
            return String(raw[start..<end])
        }.joined(separator: "-")
    }

    /// Aceita minúsculas, espaços, hifens e as trocas comuns (O por 0, I e L por 1).
    static func normalize(_ input: String) -> String {
        var out = ""
        for ch in input.uppercased() {
            switch ch {
            case "O": out.append("0")
            case "I", "L": out.append("1")
            default:
                if alphabet.contains(ch) { out.append(ch) }
            }
        }
        return out
    }

    static func decode(_ input: String) -> Data? {
        let s = normalize(input)
        guard s.count == 32 else { return nil }
        var bits = 0
        var value = 0
        var bytes: [UInt8] = []
        for ch in s {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
            }
            value &= (1 << bits) - 1
        }
        return bytes.count == 20 ? Data(bytes) : nil
    }

    static func key(from input: String, salt: Data) -> SymmetricKey? {
        guard let bytes = decode(input) else { return nil }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: salt,
                                      info: Data("expediente-recovery-v1".utf8), outputByteCount: 32)
    }
}

enum Seal {
    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else { throw VaultError.corrupted }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key)
        } catch {
            throw VaultError.corrupted
        }
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}

/// Cofre local: guarda a conta e os arquivos cifrados com AES-GCM (256 bits).
final class Vault {
    static let minimumPasswordLength = 8
    static let defaultIterations = 600_000

    let directory: URL
    let iterations: Int

    init(directory: URL, iterations: Int = Vault.defaultIterations) {
        self.directory = directory
        self.iterations = iterations
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Expediente", isDirectory: true)
    }

    var metaURL: URL { directory.appendingPathComponent("vault.json") }
    var attachmentsDirectory: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    var exists: Bool { FileManager.default.fileExists(atPath: metaURL.path) }

    func meta() throws -> VaultMeta {
        guard exists else { throw VaultError.notFound }
        do {
            return try JSONDecoder().decode(VaultMeta.self, from: Data(contentsOf: metaURL))
        } catch {
            throw VaultError.corrupted
        }
    }

    func writeMeta(_ meta: VaultMeta) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(meta), to: metaURL)
    }

    /// Cria a conta. Devolve a chave dos dados e a chave de recuperação (mostrada uma única vez).
    func create(firstName: String, email: String, password: String) throws -> (key: SymmetricKey, recoveryKey: String) {
        guard password.count >= Vault.minimumPasswordLength else { throw VaultError.weakPassword }
        try prepareDirectory()
        let dataKey = SymmetricKey(size: .bits256)
        let recovery = RecoveryKey.generate()
        let meta = try wrap(dataKey: dataKey, firstName: firstName, email: email, password: password,
                            recoveryKey: recovery, createdAt: Date())
        try writeMeta(meta)
        return (dataKey, recovery)
    }

    func wrap(dataKey: SymmetricKey, firstName: String, email: String, password: String,
              recoveryKey: String, createdAt: Date) throws -> VaultMeta {
        let salt = KeyDerivation.randomBytes(16)
        let kek = try KeyDerivation.pbkdf2(password: password, salt: salt, iterations: iterations)
        let recoverySalt = KeyDerivation.randomBytes(16)
        guard let rkek = RecoveryKey.key(from: recoveryKey, salt: recoverySalt) else { throw VaultError.wrongRecoveryKey }
        return VaultMeta(
            email: email.trimmingCharacters(in: .whitespaces),
            firstName: firstName,
            salt: salt,
            iterations: iterations,
            passwordWrapped: try Seal.seal(dataKey.rawData, key: kek),
            recoverySalt: recoverySalt,
            recoveryWrapped: try Seal.seal(dataKey.rawData, key: rkek),
            createdAt: createdAt)
    }

    func unlock(email: String, password: String) throws -> SymmetricKey {
        let meta = try meta()
        guard Vault.sameEmail(meta.email, email) else { throw VaultError.wrongCredentials }
        let kek = try KeyDerivation.pbkdf2(password: password, salt: meta.salt, iterations: meta.iterations)
        do {
            return SymmetricKey(data: try Seal.open(meta.passwordWrapped, key: kek))
        } catch {
            throw VaultError.wrongCredentials
        }
    }

    func unlock(recoveryKey: String) throws -> SymmetricKey {
        let meta = try meta()
        guard let rkek = RecoveryKey.key(from: recoveryKey, salt: meta.recoverySalt) else { throw VaultError.wrongRecoveryKey }
        do {
            return SymmetricKey(data: try Seal.open(meta.recoveryWrapped, key: rkek))
        } catch {
            throw VaultError.wrongRecoveryKey
        }
    }

    /// Confere se a chave em mãos é a chave deste cofre.
    func verify(key: SymmetricKey, password: String) -> Bool {
        guard let meta = try? meta(), let kek = try? KeyDerivation.pbkdf2(password: password, salt: meta.salt, iterations: meta.iterations),
              let raw = try? Seal.open(meta.passwordWrapped, key: kek) else { return false }
        return raw == key.rawData
    }

    func changePassword(key: SymmetricKey, newPassword: String) throws {
        guard newPassword.count >= Vault.minimumPasswordLength else { throw VaultError.weakPassword }
        var meta = try meta()
        let salt = KeyDerivation.randomBytes(16)
        let kek = try KeyDerivation.pbkdf2(password: newPassword, salt: salt, iterations: iterations)
        meta.salt = salt
        meta.iterations = iterations
        meta.passwordWrapped = try Seal.seal(key.rawData, key: kek)
        try writeMeta(meta)
    }

    func regenerateRecoveryKey(key: SymmetricKey) throws -> String {
        var meta = try meta()
        let recovery = RecoveryKey.generate()
        let salt = KeyDerivation.randomBytes(16)
        guard let rkek = RecoveryKey.key(from: recovery, salt: salt) else { throw VaultError.wrongRecoveryKey }
        meta.recoverySalt = salt
        meta.recoveryWrapped = try Seal.seal(key.rawData, key: rkek)
        try writeMeta(meta)
        return recovery
    }

    /// Adota a senha e a chave de recuperação de outro aparelho (sincronização). Mantém o e-mail e o nome daqui.
    func adoptCredentials(_ other: VaultMeta) throws {
        var meta = try meta()
        meta.salt = other.salt
        meta.iterations = other.iterations
        meta.passwordWrapped = other.passwordWrapped
        meta.recoverySalt = other.recoverySalt
        meta.recoveryWrapped = other.recoveryWrapped
        try writeMeta(meta)
    }

    func updateProfile(firstName: String, email: String) throws {
        var meta = try meta()
        meta.firstName = firstName
        meta.email = email
        try writeMeta(meta)
    }

    // MARK: - Arquivos cifrados

    func url(for name: String) -> URL { directory.appendingPathComponent(name) }

    func writeSealed(_ data: Data, name: String, key: SymmetricKey) throws {
        try write(try Seal.seal(data, key: key), to: url(for: name))
    }

    func readSealed(name: String, key: SymmetricKey) throws -> Data? {
        let u = url(for: name)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Seal.open(Data(contentsOf: u), key: key)
    }

    func writeAttachment(_ data: Data, id: UUID, key: SymmetricKey) throws {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        try write(try Seal.seal(data, key: key), to: attachmentsDirectory.appendingPathComponent(id.uuidString))
    }

    /// Anexo que já vem cifrado (da sincronização), gravado como está.
    func writeSealedAttachment(_ sealed: Data, id: UUID) throws {
        try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
        try write(sealed, to: attachmentsDirectory.appendingPathComponent(id.uuidString))
    }

    func readAttachment(id: UUID, key: SymmetricKey) throws -> Data {
        try Seal.open(Data(contentsOf: attachmentsDirectory.appendingPathComponent(id.uuidString)), key: key)
    }

    func deleteAttachment(id: UUID) {
        try? FileManager.default.removeItem(at: attachmentsDirectory.appendingPathComponent(id.uuidString))
    }

    func attachmentIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: attachmentsDirectory.path)) ?? []
        return names.compactMap(UUID.init(uuidString:))
    }

    /// Apaga a conta e todos os dados deste aparelho.
    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }

    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Define se a pasta do app entra no backup do iCloud do aparelho (os arquivos continuam cifrados).
    func setIncludedInDeviceBackup(_ included: Bool) {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = !included
        try? url.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func sameEmail(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
