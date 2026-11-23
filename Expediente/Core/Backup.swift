import CryptoKit
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let expedienteBackup = UTType(exportedAs: "br.com.colorsoftware.expediente.backup", conformingTo: .data)
}

/// Arquivo de backup: os mesmos arquivos cifrados do aparelho, juntos num só arquivo.
/// Abre com a senha ou com a chave de recuperação da conta no momento do backup.
struct BackupFile: Codable {
    var format = "expediente-backup"
    var version = 1
    var createdAt: Date
    var meta: VaultMeta
    var data: Data
    var log: Data?
    var attachments: [String: Data] = [:]
}

enum BackupError: LocalizedError {
    case invalidFile
    var errorDescription: String? { "Este arquivo não é um backup do Expediente ou está danificado." }
}

enum Backup {
    static let dataFileName = "data.bin"

    /// Junta os arquivos já cifrados. Nada é decifrado para gerar o backup.
    static func make(vault: Vault, date: Date = Date()) throws -> Data {
        let fm = FileManager.default
        let dataURL = vault.url(for: dataFileName)
        guard fm.fileExists(atPath: dataURL.path) else { throw VaultError.notFound }
        var file = BackupFile(createdAt: date, meta: try vault.meta(), data: try Data(contentsOf: dataURL))
        let logURL = vault.url(for: AuditLog.fileName)
        if fm.fileExists(atPath: logURL.path) { file.log = try Data(contentsOf: logURL) }
        for id in vault.attachmentIDs() {
            file.attachments[id.uuidString] = try Data(contentsOf: vault.attachmentsDirectory.appendingPathComponent(id.uuidString))
        }
        return try PropertyListEncoder.binary.encode(file)
    }

    /// Lê o backup (plist binário; JSON também é aceito).
    static func parse(_ data: Data) throws -> BackupFile {
        let isPlist = data.prefix(8) == Data("bplist00".utf8)
        let file = isPlist
            ? try? PropertyListDecoder().decode(BackupFile.self, from: data)
            : try? JSONDecoder().decode(BackupFile.self, from: data)
        guard let file, file.format == "expediente-backup", !file.data.isEmpty else { throw BackupError.invalidFile }
        return file
    }

    static func fileName(date: Date = Date()) -> String {
        "Expediente-backup-\(Formatters.fileStamp.string(from: date)).expedientebackup"
    }

    /// Abre a chave do backup num cofre temporário, sem tocar nos dados atuais.
    static func unlock(_ file: BackupFile, email: String, password: String) throws -> SymmetricKey {
        try withTemporaryVault(file) { try $0.unlock(email: email, password: password) }
    }

    static func unlock(_ file: BackupFile, recoveryKey: String) throws -> SymmetricKey {
        try withTemporaryVault(file) { try $0.unlock(recoveryKey: recoveryKey) }
    }

    private static func withTemporaryVault<T>(_ file: BackupFile, _ body: (Vault) throws -> T) throws -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("backup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v = Vault(directory: dir, iterations: file.meta.iterations)
        try v.writeMeta(file.meta)
        return try body(v)
    }

    /// Confere se os dados do backup abrem com a chave e devolve o banco de dados.
    static func database(in file: BackupFile, key: SymmetricKey) throws -> Database {
        try JSONDecoder().decode(Database.self, from: Seal.open(file.data, key: key))
    }

    /// Grava o backup no aparelho. Se `currentLog` vier preenchido (restauração por cima de uma conta existente),
    /// o registro atual é mantido e recifrado com a chave do backup, para que nada do histórico se perca.
    static func restore(_ file: BackupFile, key: SymmetricKey, into vault: Vault, currentLog: [AuditEntry]?) throws {
        _ = try database(in: file, key: key)
        let fm = FileManager.default
        try? fm.removeItem(at: vault.attachmentsDirectory)
        try vault.prepareDirectory()
        try vault.writeMeta(file.meta)
        try file.data.write(to: vault.url(for: dataFileName), options: [.atomic, .completeFileProtectionUnlessOpen])
        if let currentLog {
            try vault.writeSealed(try JSONEncoder().encode(currentLog), name: AuditLog.fileName, key: key)
        } else if let log = file.log {
            try log.write(to: vault.url(for: AuditLog.fileName), options: [.atomic, .completeFileProtectionUnlessOpen])
        } else {
            try? fm.removeItem(at: vault.url(for: AuditLog.fileName))
        }
        try fm.createDirectory(at: vault.attachmentsDirectory, withIntermediateDirectories: true)
        for (name, sealed) in file.attachments where UUID(uuidString: name) != nil {
            try sealed.write(to: vault.attachmentsDirectory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }
}

extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let e = PropertyListEncoder()
        e.outputFormat = .binary
        return e
    }
}
