import CryptoKit
import SwiftUI

/// Estado geral: primeira configuração, bloqueado ou aberto.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable { case setup, locked, unlocked }

    @Published var phase: Phase
    @Published private(set) var store: Store?
    @Published private(set) var firstName: String
    @Published private(set) var email: String

    let vault: Vault
    let anchor: AuditAnchorStore
    private(set) var isDemo = false
    private var backgroundedAt: Date?

    init(vault: Vault = Vault(directory: Vault.defaultDirectory), anchor: AuditAnchorStore = KeychainAnchorStore()) {
        self.vault = vault
        self.anchor = anchor
        let meta = try? vault.meta()
        phase = meta == nil ? .setup : .locked
        firstName = meta?.firstName ?? ""
        email = meta?.email ?? ""
        TemporaryFiles.clear()
    }

    /// Para o modo de demonstração e para os testes: entra direto com um banco já pronto.
    init(demoStore: Store) {
        vault = demoStore.vault
        anchor = MemoryAnchorStore()
        store = demoStore
        isDemo = true
        phase = .unlocked
        firstName = demoStore.db.professional.firstName
        email = demoStore.db.professional.email
    }

    // MARK: - Conta nova

    /// Cria a conta e devolve a chave de recuperação. O app só abre depois de `finishSetup()`.
    func createAccount(fullName: String, email: String, occupation: String, area: BusinessArea, term: ClientTerm,
                       password: String) async throws -> String {
        let vault = self.vault
        let first = fullName.split(separator: " ").first.map(String.init) ?? fullName
        let result = try await Task.detached(priority: .userInitiated) {
            try vault.create(firstName: first, email: email, password: password)
        }.value
        anchor.clear()
        let s = try Store(vault: vault, key: result.key, anchor: anchor)
        s.update { db in
            db.professional = Professional(fullName: fullName.trimmingCharacters(in: .whitespaces),
                                           email: email.trimmingCharacters(in: .whitespaces))
            db.professional.occupation = occupation.trimmingCharacters(in: .whitespaces)
        }
        s.applyBusinessArea(area, term: term)
        try s.saveNow()
        s.audit(.accountCreated)
        vault.setIncludedInDeviceBackup(false)
        store = s
        firstName = first
        self.email = email
        return result.recoveryKey
    }

    func finishSetup() {
        phase = .unlocked
        rescheduleReminders()
    }

    // MARK: - Entrar

    func unlock(email: String, password: String) async throws {
        let vault = self.vault
        do {
            let key = try await Task.detached(priority: .userInitiated) {
                try vault.unlock(email: email, password: password)
            }.value
            try open(with: key, event: .loginPassword)
        } catch let error as VaultError where error == .wrongCredentials {
            AuditLog.recordPendingFailure(in: vault, detail: "E-mail ou senha incorretos")
            throw error
        }
    }

    func unlockWithBiometrics() async -> Bool {
        guard Biometrics.isEnabled, let raw = await Biometrics.unlock() else { return false }
        do {
            try open(with: SymmetricKey(data: raw), event: .loginBiometrics)
            return true
        } catch {
            // A chave guardada não confere mais (ex.: backup restaurado). Desliga a biometria.
            Biometrics.disable()
            return false
        }
    }

    func unlockWithRecovery(_ recoveryKey: String, newPassword: String) async throws {
        let vault = self.vault
        do {
            let key = try await Task.detached(priority: .userInitiated) { () -> SymmetricKey in
                let key = try vault.unlock(recoveryKey: recoveryKey)
                try vault.changePassword(key: key, newPassword: newPassword)
                return key
            }.value
            try open(with: key, event: .loginRecoveryKey)
            store?.audit(.passwordChanged, "Senha redefinida com a chave de recuperação")
            if Biometrics.isEnabled { _ = Biometrics.enable(key: key.rawData) }
        } catch let error as VaultError where error == .wrongRecoveryKey {
            AuditLog.recordPendingFailure(in: vault, detail: "Chave de recuperação incorreta")
            throw error
        }
    }

    private func open(with key: SymmetricKey, event: AuditEvent) throws {
        let s = try Store(vault: vault, key: key, anchor: anchor)
        let anchorWasMissing = anchor.load() == nil
        if anchorWasMissing { s.resetAuditAnchor() }
        s.flushPendingFailures()
        if anchorWasMissing && !s.auditEntries.isEmpty { s.audit(.logAnchorReset) }
        s.audit(event)
        s.vault.setIncludedInDeviceBackup(s.db.settings.includeInDeviceBackup)
        store = s
        firstName = s.db.professional.firstName
        email = s.db.professional.email
        phase = .unlocked
        rescheduleReminders()
    }

    func lock() {
        guard !isDemo, phase == .unlocked else { return }
        store?.flush()
        store = nil
        TemporaryFiles.clear()
        phase = vault.exists ? .locked : .setup
    }

    /// Depois de restaurar um backup ou apagar a conta, volta para a tela certa.
    func reloadAfterRestore() {
        store = nil
        Biometrics.disable()
        let meta = try? vault.meta()
        firstName = meta?.firstName ?? ""
        email = meta?.email ?? ""
        phase = meta == nil ? .setup : .locked
    }

    func eraseEverything() {
        store = nil
        vault.destroy()
        Biometrics.disable()
        anchor.clear()
        ReminderScheduler.cancelAll()
        firstName = ""
        email = ""
        phase = .setup
    }

    // MARK: - Restaurar backup na primeira configuração

    func restoreForSetup(_ file: BackupFile, email: String, password: String?, recoveryKey: String?) async throws {
        let key = try await Task.detached(priority: .userInitiated) { () -> SymmetricKey in
            if let recoveryKey, !recoveryKey.isEmpty { return try Backup.unlock(file, recoveryKey: recoveryKey) }
            return try Backup.unlock(file, email: email, password: password ?? "")
        }.value
        try Backup.restore(file, key: key, into: vault, currentLog: nil)
        anchor.clear()
        let s = try Store(vault: vault, key: key, anchor: anchor)
        s.resetAuditAnchor()
        s.audit(.backupRestored, "Backup de \(Formatters.dateTime.string(from: file.createdAt))")
        store = s
        firstName = s.db.professional.firstName
        self.email = s.db.professional.email
        phase = .unlocked
        rescheduleReminders()
    }

    // MARK: - Ciclo de vida

    func scenePhaseChanged(_ scenePhase: ScenePhase) {
        guard !isDemo else { return }
        switch scenePhase {
        case .background:
            store?.flush()
            backgroundedAt = Date()
            if (store?.db.settings.lockAfterSeconds ?? 0) == 0 { lock() }
        case .active:
            if let t = backgroundedAt, let s = store, Date().timeIntervalSince(t) >= TimeInterval(s.db.settings.lockAfterSeconds) {
                lock()
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    func rescheduleReminders() {
        guard let s = store, !isDemo else { return }
        let db = s.db
        Task {
            if db.settings.endOfDayReminder || db.settings.reminderMinutesBefore > 0 { _ = await ReminderScheduler.requestPermission() }
            await ReminderScheduler.reschedule(db)
        }
    }
}
