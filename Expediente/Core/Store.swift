import CryptoKit
import Foundation
import SwiftUI

enum CancelScope { case single, thisAndFollowing }

/// Dados abertos (depois do desbloqueio). Toda alteração passa por aqui e é gravada cifrada.
@MainActor
final class Store: ObservableObject {
    @Published private(set) var db: Database
    @Published private(set) var auditEntries: [AuditEntry] = []

    let vault: Vault
    let key: SymmetricKey
    let isDemo: Bool
    private let log: AuditLog
    private let anchor: AuditAnchorStore
    private var saveTask: Task<Void, Never>?
    /// Aumenta a cada alteração.
    private(set) var changeCount = 0
    /// Depois de restaurar um backup, este objeto não grava mais nada (a chave mudou).
    private var retired = false
    var now: () -> Date = { Date() }

    init(vault: Vault, key: SymmetricKey, anchor: AuditAnchorStore = KeychainAnchorStore(), isDemo: Bool = false) throws {
        self.vault = vault
        self.key = key
        self.isDemo = isDemo
        self.anchor = anchor
        if let data = try vault.readSealed(name: Backup.dataFileName, key: key) {
            do {
                db = try JSONDecoder().decode(Database.self, from: data)
            } catch {
                throw VaultError.corrupted
            }
        } else {
            db = Database()
        }
        log = try AuditLog(vault: vault, key: key, anchor: anchor)
        auditEntries = log.entries
        Term.kind = db.settings.clientTerm
    }

    var actor: String {
        let p = db.professional
        if p.email.isEmpty { return p.fullName }
        return p.fullName.isEmpty ? p.email : "\(p.fullName) <\(p.email)>"
    }

    // MARK: - Gravação

    func update(_ change: (inout Database) -> Void) {
        change(&db)
        changeCount += 1
        if Term.kind != db.settings.clientTerm { Term.kind = db.settings.clientTerm }
        scheduleSave()
    }

    func saveNow() throws {
        saveTask?.cancel()
        saveTask = nil
        guard !retired else { return }
        let data = try JSONEncoder().encode(db)
        try vault.writeSealed(data, name: Backup.dataFileName, key: key)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self, !Task.isCancelled else { return }
            try? self.saveNow()
            if !self.isDemo { await ReminderScheduler.reschedule(self.db, now: self.now()) }
        }
    }

    func flush() {
        if saveTask != nil { try? saveNow() }
    }

    // MARK: - Registro de acessos

    func audit(_ event: AuditEvent, _ detail: String = "") {
        guard !retired else { return }
        _ = try? log.append(event, actor: actor, detail: detail, date: now())
        auditEntries = log.entries
    }

    func auditIntegrity() -> AuditIntegrity { log.verify() }

    func flushPendingFailures() {
        log.flushPendingFailures(actor: actor)
        auditEntries = log.entries
    }

    func resetAuditAnchor() {
        log.resetAnchor()
    }

    // MARK: - Pacientes

    @discardableResult
    func addPatient(_ patient: Patient) -> Patient {
        var p = patient
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        update { $0.patients.append(p) }
        return p
    }

    func updatePatient(_ patient: Patient) {
        update { db in
            if let i = db.patients.firstIndex(where: { $0.id == patient.id }) { db.patients[i] = patient }
        }
    }

    func deletePatient(_ id: UUID) {
        let name = db.patient(id)?.name ?? ""
        if let att = db.patient(id)?.consent { vault.deleteAttachment(id: att.id) }
        update { db in
            db.patients.removeAll { $0.id == id }
            db.appointments.removeAll { $0.patientID == id }
            db.notes.removeAll { $0.patientID == id }
            db.packages.removeAll { $0.patientID == id }
        }
        audit(.patientDeleted, name)
    }

    var activePatients: [Patient] {
        db.patients.filter { !$0.archived }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func attachConsent(_ data: Data, fileName: String, to patientID: UUID) throws {
        guard var p = db.patient(patientID) else { return }
        if let old = p.consent { vault.deleteAttachment(id: old.id) }
        let att = Attachment(fileName: fileName, addedAt: now(), byteCount: data.count)
        try vault.writeAttachment(data, id: att.id, key: key)
        p.consent = att
        updatePatient(p)
        try saveNow()
        audit(.consentAttached, "\(p.name): \(fileName)")
    }

    func consentData(_ attachment: Attachment) throws -> Data {
        try vault.readAttachment(id: attachment.id, key: key)
    }

    func removeConsent(from patientID: UUID) {
        guard var p = db.patient(patientID), let att = p.consent else { return }
        vault.deleteAttachment(id: att.id)
        p.consent = nil
        updatePatient(p)
    }

    // MARK: - Agenda

    @discardableResult
    func schedule(_ template: Appointment, rule: RepeatRule, until: Date?) -> [Appointment] {
        schedule(template, dates: Recurrence.dates(start: template.start, rule: rule, until: until))
    }

    /// Agenda nas datas já aprovadas (série ajustada ao calendário real).
    @discardableResult
    func schedule(_ template: Appointment, dates: [Date]) -> [Appointment] {
        guard !dates.isEmpty else { return [] }
        let series: UUID? = dates.count > 1 ? UUID() : nil
        // Atendimentos de pacote: só os que cabem no saldo ficam no pacote; os outros são cobrados um a um.
        var packageRoom = db.package(template.packageID).map { Packages.remaining($0, in: db) } ?? 0
        let created = dates.enumerated().map { index, date -> Appointment in
            var a = template
            if index > 0 {
                a.id = UUID()
                // Pagamento e presença valem só para a primeira; as próximas começam em branco.
                a.payment = nil
                a.paidAt = nil
                a.attendance = .scheduled
                a.invoiceNumber = nil
                a.invoiceIssuedAt = nil
            }
            a.start = date
            a.seriesID = series
            if a.packageID != nil {
                if packageRoom > 0 { packageRoom -= 1 } else { a.packageID = nil }
            }
            return a
        }
        update { $0.appointments.append(contentsOf: created) }
        return created
    }

    func updateAppointment(_ appointment: Appointment) {
        update { db in
            if let i = db.appointments.firstIndex(where: { $0.id == appointment.id }) { db.appointments[i] = appointment }
        }
    }

    func appointment(_ id: UUID?) -> Appointment? {
        guard let id else { return nil }
        return db.appointments.first { $0.id == id }
    }

    /// Desmarcada com aviso: fica no histórico (não conta como falta) e libera o horário.
    func cancelWithNotice(_ id: UUID) {
        setAttendance(id, .cancelled)
    }

    /// Libera o horário. As anotações já escritas continuam no cadastro do cliente.
    func cancel(_ id: UUID, scope: CancelScope) {
        guard let a = appointment(id) else { return }
        update { db in
            if scope == .thisAndFollowing, let series = a.seriesID {
                db.appointments.removeAll { $0.seriesID == series && $0.start >= a.start }
            } else {
                db.appointments.removeAll { $0.id == id }
            }
            for i in db.notes.indices where db.notes[i].appointmentID == id { db.notes[i].appointmentID = nil }
        }
    }

    /// Move o atendimento (com tudo o que ele tem) para outro dia e horário.
    func reschedule(_ id: UUID, to newStart: Date) {
        update { db in
            guard let i = db.appointments.firstIndex(where: { $0.id == id }) else { return }
            db.appointments[i].start = newStart
            // Ao sair da série, deixa de ser apagada junto com "este e os próximos".
            db.appointments[i].seriesID = nil
            if db.appointments[i].attendance == .cancelled { db.appointments[i].attendance = .scheduled }
        }
    }

    func setPayment(_ id: UUID, _ status: PaymentStatus?) {
        update { db in
            guard let i = db.appointments.firstIndex(where: { $0.id == id }) else { return }
            // Retorno sem custo e atendimento de pacote não recebem pagamento.
            if Billing.isNoCharge(db.appointments[i], in: db) {
                db.appointments[i].payment = nil
                db.appointments[i].paidAt = nil
                return
            }
            db.appointments[i].payment = status
            db.appointments[i].paidAt = status == .paid ? (db.appointments[i].paidAt ?? self.now()) : nil
            if status == .paid && db.appointments[i].amountCents == nil {
                let price = db.price(of: db.appointments[i])
                if price > 0 { db.appointments[i].amountCents = price }
            }
        }
    }

    func setAttendance(_ id: UUID, _ attendance: Attendance) {
        update { db in
            guard let i = db.appointments.firstIndex(where: { $0.id == id }) else { return }
            db.appointments[i].attendance = attendance
        }
    }

    // MARK: - Anotações

    func note(for appointmentID: UUID) -> SessionNote? {
        db.notes.first { $0.appointmentID == appointmentID }
    }

    func saveNote(_ note: SessionNote) {
        var n = note
        n.updatedAt = now()
        update { db in
            if let i = db.notes.firstIndex(where: { $0.id == n.id }) {
                db.notes[i] = n
            } else {
                db.notes.append(n)
            }
        }
    }

    func deleteNote(_ id: UUID) {
        update { $0.notes.removeAll { $0.id == id } }
    }

    func notes(of patientID: UUID) -> [SessionNote] {
        db.notes.filter { $0.patientID == patientID }.sorted { sortDate($0.appointmentID, $0.createdAt) > sortDate($1.appointmentID, $1.createdAt) }
    }

    private func sortDate(_ appointmentID: UUID?, _ fallback: Date) -> Date {
        appointment(appointmentID)?.start ?? fallback
    }

    // MARK: - Tags

    func saveTag(_ tag: Tag) {
        update { db in
            if let i = db.tags.firstIndex(where: { $0.id == tag.id }) { db.tags[i] = tag } else { db.tags.append(tag) }
        }
    }

    func deleteTag(_ id: UUID) {
        update { db in
            db.tags.removeAll { $0.id == id }
            for i in db.appointments.indices where db.appointments[i].tagID == id { db.appointments[i].tagID = nil }
        }
    }

    func moveTags(from: IndexSet, to: Int) {
        update { $0.tags.move(fromOffsets: from, toOffset: to) }
    }

    // MARK: - Pacotes

    func savePackage(_ p: ServicePackage) {
        update { db in
            if let i = db.packages.firstIndex(where: { $0.id == p.id }) { db.packages[i] = p } else { db.packages.append(p) }
        }
    }

    /// Apaga o pacote. Os atendimentos ligados a ele continuam na agenda, agora cobrados um a um.
    func deletePackage(_ id: UUID) {
        update { db in
            db.packages.removeAll { $0.id == id }
            for i in db.appointments.indices where db.appointments[i].packageID == id { db.appointments[i].packageID = nil }
        }
    }

    func setPackagePayment(_ id: UUID, _ status: PaymentStatus?, method: PaymentMethod? = nil) {
        update { db in
            guard let i = db.packages.firstIndex(where: { $0.id == id }) else { return }
            db.packages[i].payment = status
            if let method { db.packages[i].method = method }
            db.packages[i].paidAt = status == .paid ? (db.packages[i].paidAt ?? self.now()) : nil
        }
    }

    // MARK: - Despesas

    func saveExpense(_ e: Expense) {
        update { db in
            if let i = db.expenses.firstIndex(where: { $0.id == e.id }) { db.expenses[i] = e } else { db.expenses.append(e) }
        }
    }

    func deleteExpense(_ id: UUID) {
        update { $0.expenses.removeAll { $0.id == id } }
    }

    // MARK: - Backup

    func makeBackup() throws -> Data {
        try saveNow()
        return try Backup.make(vault: vault, date: now())
    }

    /// Restaura um backup por cima dos dados atuais, mantendo o histórico do registro de acessos.
    func restore(_ file: BackupFile, key backupKey: SymmetricKey) throws {
        try saveNow()
        retired = true
        try Backup.restore(file, key: backupKey, into: vault, currentLog: log.entries)
        let restoredLog = try AuditLog(vault: vault, key: backupKey, anchor: anchor)
        try restoredLog.append(.backupRestored, actor: actor, detail: "Backup de \(Formatters.dateTime.string(from: file.createdAt))", date: now())
    }
}
