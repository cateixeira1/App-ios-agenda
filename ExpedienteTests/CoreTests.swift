import CryptoKit
import PDFKit
import XCTest
@testable import Expediente

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("expediente-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Calendário fixo (São Paulo) para os testes não dependerem do fuso do simulador.
let testCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
    c.locale = Locale(identifier: "pt_BR")
    return c
}()

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    testCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

// MARK: - Cofre

final class VaultTests: XCTestCase {
    func testCreateAndUnlockWithPassword() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let created = try vault.create(firstName: "Ana", email: "ana@exemplo.com", password: "senha-forte-1")
        let key = try vault.unlock(email: "ANA@exemplo.com ", password: "senha-forte-1")
        XCTAssertEqual(key.rawData, created.key.rawData)
        XCTAssertEqual(try vault.meta().firstName, "Ana")
    }

    func testWrongPasswordAndEmailAreRejected() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        _ = try vault.create(firstName: "Ana", email: "ana@exemplo.com", password: "senha-forte-1")
        XCTAssertThrowsError(try vault.unlock(email: "ana@exemplo.com", password: "senha-errada")) {
            XCTAssertEqual($0 as? VaultError, .wrongCredentials)
        }
        XCTAssertThrowsError(try vault.unlock(email: "outra@exemplo.com", password: "senha-forte-1")) {
            XCTAssertEqual($0 as? VaultError, .wrongCredentials)
        }
        XCTAssertThrowsError(try vault.unlock(email: "ana@exemplo.com", password: ""))
    }

    func testShortPasswordIsRefused() {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        XCTAssertThrowsError(try vault.create(firstName: "Ana", email: "a@b.c", password: "1234567")) {
            XCTAssertEqual($0 as? VaultError, .weakPassword)
        }
    }

    func testAccentedPasswordNormalization() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        // "é" pré-composto na criação; "e" + acento combinado no acesso.
        _ = try vault.create(firstName: "Ana", email: "a@b.c", password: "caf\u{00E9}-segura")
        XCTAssertNoThrow(try vault.unlock(email: "a@b.c", password: "cafe\u{0301}-segura"))
    }

    func testRecoveryKeyUnlocksAndResetsPassword() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let created = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1")
        XCTAssertEqual(created.recoveryKey.count, 39) // 32 caracteres + 7 hifens
        // Minúsculas, sem hifens e com espaços também valem.
        let typed = created.recoveryKey.lowercased().replacingOccurrences(of: "-", with: " ")
        let key = try vault.unlock(recoveryKey: typed)
        XCTAssertEqual(key.rawData, created.key.rawData)
        try vault.changePassword(key: key, newPassword: "nova-senha-2")
        XCTAssertThrowsError(try vault.unlock(email: "a@b.c", password: "senha-forte-1"))
        XCTAssertNoThrow(try vault.unlock(email: "a@b.c", password: "nova-senha-2"))
        XCTAssertThrowsError(try vault.unlock(recoveryKey: "0000-0000-0000-0000-0000-0000-0000-0000")) {
            XCTAssertEqual($0 as? VaultError, .wrongRecoveryKey)
        }
    }

    func testRegeneratedRecoveryKeyReplacesOldOne() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let created = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1")
        let newKey = try vault.regenerateRecoveryKey(key: created.key)
        XCTAssertNotEqual(newKey, created.recoveryKey)
        XCTAssertThrowsError(try vault.unlock(recoveryKey: created.recoveryKey))
        XCTAssertNoThrow(try vault.unlock(recoveryKey: newKey))
    }

    func testRecoveryKeyEncodingRoundTrip() {
        let bytes = KeyDerivation.randomBytes(20)
        let text = RecoveryKey.format(RecoveryKey.encode(bytes))
        XCTAssertEqual(RecoveryKey.decode(text), bytes)
        XCTAssertNil(RecoveryKey.decode("ABC"))
    }

    func testSealedFilesAreNotReadableWithoutKey() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let created = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1")
        let secret = Data("Paciente relata insônia".utf8)
        try vault.writeSealed(secret, name: "data.bin", key: created.key)
        let onDisk = try Data(contentsOf: vault.url(for: "data.bin"))
        XCTAssertNil(onDisk.range(of: Data("insônia".utf8)), "O texto não pode aparecer no arquivo gravado")
        XCTAssertEqual(try vault.readSealed(name: "data.bin", key: created.key), secret)
        XCTAssertThrowsError(try vault.readSealed(name: "data.bin", key: SymmetricKey(size: .bits256)))
    }

    func testPBKDF2KnownVector() throws {
        // RFC 7914, seção 11: PBKDF2-HMAC-SHA256, "passwd", "salt", 1 iteração.
        let key = try KeyDerivation.pbkdf2(password: "passwd", salt: Data("salt".utf8), iterations: 1)
        let hex = key.rawData.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }
}

// MARK: - Registro de acessos

final class AuditLogTests: XCTestCase {
    private func makeLog() throws -> (AuditLog, Vault, SymmetricKey, MemoryAnchorStore) {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let key = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1").key
        let anchor = MemoryAnchorStore()
        return (try AuditLog(vault: vault, key: key, anchor: anchor), vault, key, anchor)
    }

    func testChainIsIntactAndPersists() throws {
        let (log, vault, key, anchor) = try makeLog()
        try log.append(.loginPassword, actor: "Ana")
        try log.append(.reportExported, actor: "Ana", detail: "Cliente X")
        XCTAssertEqual(log.verify(), .intact)
        let reopened = try AuditLog(vault: vault, key: key, anchor: anchor)
        XCTAssertEqual(reopened.entries.count, 2)
        XCTAssertEqual(reopened.verify(), .intact)
        XCTAssertEqual(reopened.entries[1].previousHash, reopened.entries[0].hash)
    }

    func testEditedEntryIsDetected() throws {
        let (log, _, _, anchor) = try makeLog()
        try log.append(.loginPassword, actor: "Ana")
        try log.append(.loginPassword, actor: "Ana")
        var entries = log.entries
        entries[0].actor = "Outra pessoa"
        XCTAssertFalse(AuditLog.verify(entries: entries, anchor: anchor.load()).isIntact)
    }

    func testRemovedEntryIsDetected() throws {
        let (log, _, _, anchor) = try makeLog()
        for _ in 0..<3 { try log.append(.loginPassword, actor: "Ana") }
        // Remover o último item mantém a cadeia, mas a âncora acusa.
        let truncated = Array(log.entries.dropLast())
        XCTAssertEqual(AuditLog.verify(entries: truncated, anchor: nil), .intact)
        XCTAssertFalse(AuditLog.verify(entries: truncated, anchor: anchor.load()).isIntact)
        // Remover do meio quebra a numeração.
        var middle = log.entries
        middle.remove(at: 1)
        XCTAssertFalse(AuditLog.verify(entries: middle, anchor: nil).isIntact)
    }

    func testDeletedFileIsDetected() throws {
        let (log, vault, key, anchor) = try makeLog()
        try log.append(.loginPassword, actor: "Ana")
        try FileManager.default.removeItem(at: vault.url(for: AuditLog.fileName))
        let reopened = try AuditLog(vault: vault, key: key, anchor: anchor)
        XCTAssertFalse(reopened.verify().isIntact)
    }

    func testPendingFailuresEnterTheChain() throws {
        let (log, vault, _, _) = try makeLog()
        AuditLog.recordPendingFailure(in: vault, detail: "E-mail ou senha incorretos")
        AuditLog.recordPendingFailure(in: vault, detail: "E-mail ou senha incorretos")
        XCTAssertEqual(AuditLog.pendingFailures(in: vault).count, 2)
        log.flushPendingFailures(actor: "Ana")
        XCTAssertEqual(log.entries.filter { $0.event == .loginFailed }.count, 2)
        XCTAssertTrue(AuditLog.pendingFailures(in: vault).isEmpty)
        XCTAssertEqual(log.verify(), .intact)
    }
}

// MARK: - Agenda

final class SchedulingTests: XCTestCase {
    func testWeeklyRecurrenceKeepsWeekdayAndTime() {
        let start = date(2026, 10, 20, 16) // terça
        let dates = Recurrence.dates(start: start, rule: .weekly, until: date(2026, 11, 17), calendar: testCalendar)
        XCTAssertEqual(dates.count, 5)
        for d in dates {
            XCTAssertEqual(testCalendar.component(.weekday, from: d), 3)
            XCTAssertEqual(testCalendar.component(.hour, from: d), 16)
        }
        XCTAssertEqual(Recurrence.describe(start: start, rule: .weekly, calendar: testCalendar), "Toda terça às 16:00")
        XCTAssertEqual(Recurrence.describe(start: date(2026, 10, 24, 10), rule: .weekly, calendar: testCalendar), "Todo sábado às 10:00")
    }

    func testBiweeklyAndDefaultSpan() {
        let start = date(2026, 1, 5, 9)
        XCTAssertEqual(Recurrence.dates(start: start, rule: .biweekly, until: date(2026, 2, 2), calendar: testCalendar).count, 3)
        let year = Recurrence.dates(start: start, rule: .weekly, until: nil, calendar: testCalendar)
        XCTAssertEqual(year.count, 53)
        XCTAssertEqual(Recurrence.dates(start: start, rule: .none, until: nil).count, 1)
    }

    func testConflicts() {
        let p = UUID()
        let a = Appointment(patientID: p, start: date(2026, 10, 20, 16), durationMinutes: 50)
        XCTAssertEqual(Conflicts.overlapping(start: date(2026, 10, 20, 16, 30), durationMinutes: 50, in: [a]).count, 1)
        XCTAssertEqual(Conflicts.overlapping(start: date(2026, 10, 20, 16, 50), durationMinutes: 50, in: [a]).count, 0)
        XCTAssertEqual(Conflicts.overlapping(start: a.start, durationMinutes: 50, in: [a], excluding: a.id).count, 0)
    }

    func testNameMatcher() {
        let patients = ["Marina Lopes", "Mariana Souza", "João Álvares", "Rafael Monteiro"].map { Patient(name: $0) }
        XCTAssertEqual(NameMatcher.suggestions(for: "joao", in: patients).first?.name, "João Álvares")
        XCTAssertEqual(NameMatcher.suggestions(for: "Marina", in: patients).first?.name, "Marina Lopes")
        XCTAssertEqual(NameMatcher.suggestions(for: "mari", in: patients).count, 2)
        XCTAssertEqual(NameMatcher.suggestions(for: "monteiro", in: patients).first?.name, "Rafael Monteiro")
        // Erro de digitação.
        XCTAssertEqual(NameMatcher.suggestions(for: "Rafaek", in: patients).first?.name, "Rafael Monteiro")
        XCTAssertTrue(NameMatcher.suggestions(for: "Zuleica", in: patients).isEmpty)
        XCTAssertEqual(NameMatcher.exactMatch(for: " joão  álvares ", in: patients)?.name, "João Álvares")
        XCTAssertEqual(NameMatcher.levenshtein("kitten", "sitting"), 3)
    }

    func testEndOfDayReminder() {
        var db = Database()
        db.settings.endOfDayReminder = true
        let ana = Patient(name: "Ana Prado"), bruno = Patient(name: "Bruno Lima"), carla = Patient(name: "Carla Dias")
        db.patients = [ana, bruno, carla]
        let a1 = Appointment(patientID: ana.id, start: date(2026, 10, 20, 9))
        let a2 = Appointment(patientID: bruno.id, start: date(2026, 10, 20, 14))
        let a3 = Appointment(patientID: carla.id, start: date(2026, 10, 20, 20), durationMinutes: 60)
        db.appointments = [a1, a2, a3]
        // Anotação vazia não conta; anotação com texto conta.
        db.notes = [SessionNote(patientID: ana.id, appointmentID: a1.id, body: RichText(format: Data(), plain: "  \n")),
                    SessionNote(patientID: bruno.id, appointmentID: a2.id, body: RichText(format: Data(), plain: "Relata melhora"))]
        let now = date(2026, 10, 20, 12)
        var reminders = Documentation.reminders(for: db, now: now, days: 1, calendar: testCalendar)
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(reminders[0].fireDate, date(2026, 10, 20, 21, 5))
        XCTAssertEqual(reminders[0].body, "Sem anotação: Ana e Carla.")

        db.notes.append(SessionNote(patientID: carla.id, appointmentID: a3.id, body: RichText(format: Data(), plain: "Corte e escova")))
        reminders = Documentation.reminders(for: db, now: now, days: 1, calendar: testCalendar)
        XCTAssertEqual(reminders.first?.body, "Sem anotação: Ana.")

        db.settings.reminderShowsNames = false
        XCTAssertEqual(Documentation.reminders(for: db, now: now, days: 1, calendar: testCalendar).first?.body, "1 atendimento de hoje está sem anotação.")
        db.settings.endOfDayReminder = false
        XCTAssertTrue(Documentation.reminders(for: db, now: now, days: 1, calendar: testCalendar).isEmpty)
        // Depois do horário do aviso, nada é agendado para o dia.
        db.settings.endOfDayReminder = true
        XCTAssertTrue(Documentation.reminders(for: db, now: date(2026, 10, 20, 21, 6), days: 1, calendar: testCalendar).isEmpty)
    }

    func testMissedSessionsDoNotNeedNotes() {
        var db = Database()
        let ana = Patient(name: "Ana")
        db.patients = [ana]
        var a = Appointment(patientID: ana.id, start: date(2026, 10, 20, 9))
        a.attendance = .missed
        db.appointments = [a]
        XCTAssertTrue(Documentation.undocumented(on: a.start, in: db, calendar: testCalendar).isEmpty)
        XCTAssertTrue(Documentation.reminders(for: db, now: date(2026, 10, 20, 8), days: 1, calendar: testCalendar).isEmpty)
    }
}

// MARK: - Financeiro

final class FinanceTests: XCTestCase {
    func testSummary() {
        var db = Database()
        db.settings.defaultPriceCents = 15_000
        var ana = Patient(name: "Ana")
        ana.sessionPriceCents = 20_000
        let bruno = Patient(name: "Bruno")
        db.patients = [ana, bruno]
        var paid = Appointment(patientID: ana.id, start: date(2026, 10, 5, 10))
        paid.payment = .paid
        paid.method = .pix
        var unpaid = Appointment(patientID: bruno.id, start: date(2026, 10, 6, 10))
        unpaid.payment = .unpaid
        let notInformed = Appointment(patientID: bruno.id, start: date(2026, 10, 7, 10))
        var missed = Appointment(patientID: bruno.id, start: date(2026, 10, 8, 10))
        missed.attendance = .missed
        var future = Appointment(patientID: ana.id, start: date(2026, 10, 25, 10))
        future.amountCents = 25_000
        db.appointments = [paid, unpaid, notInformed, missed, future]

        let month = testCalendar.monthInterval(containing: date(2026, 10, 15))
        let s = Finance.summary(db, interval: month, now: date(2026, 10, 15))
        XCTAssertEqual(s.receivedCents, 20_000)
        XCTAssertEqual(s.byMethod[.pix], 20_000)
        XCTAssertEqual(s.openCents, 30_000)
        XCTAssertEqual(s.openCount, 2)
        XCTAssertEqual(s.expectedCents, 25_000)
        XCTAssertEqual(s.delinquentPatientCount, 1)
        XCTAssertEqual(s.delinquencyRate, 0.6, accuracy: 0.0001)
        XCTAssertEqual(Finance.open(db, now: date(2026, 10, 15)).count, 2)
    }

    func testMoneyParsing() {
        XCTAssertEqual(Formatters.parseMoney("180"), 18_000)
        XCTAssertEqual(Formatters.parseMoney("180,5"), 18_050)
        XCTAssertEqual(Formatters.parseMoney("R$ 1.200,00"), 120_000)
        XCTAssertEqual(Formatters.parseMoney("99.90"), 9_990)
        XCTAssertNil(Formatters.parseMoney(""))
        XCTAssertNil(Formatters.parseMoney("abc"))
        XCTAssertEqual(Formatters.moneyInput(18_005), "180,05")
        XCTAssertEqual(Formatters.list(["Ana", "Bruno", "Carla"]), "Ana, Bruno e Carla")
    }
}

// MARK: - PDF e backup

final class RecordAndExportTests: XCTestCase {
    func testRichTextRoundTrip() {
        let text = NSMutableAttributedString(string: "Negrito e normal", attributes: RichTextCodec.defaultAttributes)
        text.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 17), range: NSRange(location: 0, length: 7))
        let rich = RichTextCodec.encode(text)
        XCTAssertFalse(rich.format.isEmpty)
        let back = RichTextCodec.decode(rich)
        XCTAssertEqual(back.string, "Negrito e normal")
        let font = back.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
    }

    func testPDFAndPassword() throws {
        var db = Database()
        let patient = Patient(name: "Ana Prado")
        db.patients = [patient]
        db.professional = Professional(fullName: "Caio Teste")
        let note = SessionNote(patientID: patient.id, appointmentID: nil,
                               body: RichTextCodec.plain(String(repeating: "Texto longo do atendimento. ", count: 400)))
        var letterhead = PDFExporter.Letterhead()
        letterhead.headerText = "Caio Teste · Rua das Flores, 100"
        letterhead.footerText = "contato@exemplo.com"
        let data = PDFExporter.render(PDFExporter.noteDocument(note, db: db), footer: "Teste", letterhead: letterhead)
        let doc = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(doc.pageCount, 1)
        XCTAssertTrue(doc.string?.contains("Ana Prado") ?? false)
        XCTAssertTrue(doc.string?.contains("Rua das Flores") ?? false)
        let protected = try XCTUnwrap(PDFExporter.protect(data, password: "1234"))
        let locked = try XCTUnwrap(PDFDocument(data: protected))
        XCTAssertTrue(locked.isLocked)
        XCTAssertTrue(locked.unlock(withPassword: "1234"))
    }

    @MainActor
    func testBackupRoundTrip() throws {
        let dir = tempDirectory()
        let vault = Vault(directory: dir, iterations: 1_000)
        let created = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1")
        let store = try Store(vault: vault, key: created.key, anchor: MemoryAnchorStore())
        let p = store.addPatient(Patient(name: "Cliente Backup"))
        try store.attachConsent(Data("PDF do contrato".utf8), fileName: "contrato.pdf", to: p.id)
        store.audit(.loginPassword)
        let backup = try store.makeBackup()
        XCTAssertNil(backup.range(of: Data("Cliente Backup".utf8)), "O backup sai cifrado")

        let file = try Backup.parse(backup)
        XCTAssertThrowsError(try Backup.unlock(file, email: "a@b.c", password: "errada-123"))
        let key = try Backup.unlock(file, recoveryKey: created.recoveryKey)

        let other = Vault(directory: tempDirectory(), iterations: 1_000)
        try Backup.restore(file, key: key, into: other, currentLog: nil)
        let anchor = MemoryAnchorStore()
        let restored = try Store(vault: other, key: key, anchor: anchor)
        restored.resetAuditAnchor()
        XCTAssertEqual(restored.db.patients.first?.name, "Cliente Backup")
        let att = try XCTUnwrap(restored.db.patients.first?.consent)
        XCTAssertEqual(try restored.consentData(att), Data("PDF do contrato".utf8))
        XCTAssertTrue(restored.auditEntries.contains { $0.event == .loginPassword })
        XCTAssertEqual(restored.auditIntegrity(), .intact)
        XCTAssertThrowsError(try Backup.parse(Data("não é backup".utf8)))
    }
}

// MARK: - Store

@MainActor
final class StoreTests: XCTestCase {
    private func makeStore() throws -> Store {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let key = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1").key
        return try Store(vault: vault, key: key, anchor: MemoryAnchorStore())
    }

    func testScheduleCancelAndReschedule() throws {
        let store = try makeStore()
        let p = store.addPatient(Patient(name: "Marina Lopes"))
        var template = Appointment(patientID: p.id, start: date(2026, 10, 20, 16))
        template.payment = .paid
        let series = store.schedule(template, rule: .weekly, until: date(2026, 11, 10))
        XCTAssertEqual(series.count, 4)
        XCTAssertNotNil(series[0].seriesID)
        XCTAssertEqual(series[0].payment, .paid)
        XCTAssertNil(series[1].payment, "Pagamento não é copiado para as próximas")

        // Remarcar leva tudo para o novo horário e libera o antigo.
        store.saveNote(SessionNote(patientID: p.id, appointmentID: series[1].id, body: RichText(format: Data(), plain: "Anotação")))
        store.reschedule(series[1].id, to: date(2026, 10, 28, 10))
        XCTAssertEqual(store.appointment(series[1].id)?.start, date(2026, 10, 28, 10))
        XCTAssertNil(store.appointment(series[1].id)?.seriesID)
        XCTAssertNotNil(store.note(for: series[1].id))
        XCTAssertTrue(store.db.appointments(on: date(2026, 10, 27), calendar: testCalendar).isEmpty)

        // Desmarcar "este e os próximos" apaga do terceiro em diante, mas não o remarcado.
        store.cancel(series[2].id, scope: .thisAndFollowing)
        XCTAssertEqual(store.db.appointments.count, 2)
        store.cancel(series[0].id, scope: .single)
        XCTAssertEqual(store.db.appointments.count, 1)
    }

    func testPaymentFillsPrice() throws {
        let store = try makeStore()
        var p = Patient(name: "Ana")
        p.sessionPriceCents = 18_000
        store.addPatient(p)
        let a = store.schedule(Appointment(patientID: p.id, start: date(2026, 10, 1, 9)), rule: .none, until: nil)[0]
        store.setPayment(a.id, .paid)
        XCTAssertEqual(store.appointment(a.id)?.amountCents, 18_000)
        XCTAssertNotNil(store.appointment(a.id)?.paidAt)
        store.setPayment(a.id, .unpaid)
        XCTAssertNil(store.appointment(a.id)?.paidAt)
    }

    func testDataSurvivesReopen() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let key = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1").key
        let anchor = MemoryAnchorStore()
        let store = try Store(vault: vault, key: key, anchor: anchor)
        store.addPatient(Patient(name: "Persistente"))
        try store.saveNow()
        let again = try Store(vault: vault, key: key, anchor: anchor)
        XCTAssertEqual(again.db.patients.map(\.name), ["Persistente"])
        XCTAssertEqual(again.db.tags.count, Tag.presets.count)
    }
}

// MARK: - Editor

final class RichTextFormatTests: XCTestCase {
    func testFontsStylesAndColorsRoundTrip() {
        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "Serifada ", attributes: [.font: RichTextCodec.font(family: "New York", size: 17, bold: true, italic: false)]))
        text.append(NSAttributedString(string: "Georgia itálico ", attributes: [.font: RichTextCodec.font(family: "Georgia", size: 20, bold: false, italic: true),
                                                                               .underlineStyle: NSUnderlineStyle.single.rawValue]))
        text.append(NSAttributedString(string: "vermelho", attributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor(hex: "#D32F2F")!]))
        let back = RichTextCodec.decode(RichTextCodec.encode(text))
        XCTAssertEqual(back.string, text.string)
        let runs = RichTextCodec.runs(of: back)
        XCTAssertEqual(runs.map(\.font), ["New York", "Georgia", nil])
        XCTAssertTrue(runs[0].bold)
        XCTAssertTrue(runs[1].italic && runs[1].underline)
        XCTAssertEqual(runs[1].size, 20)
        XCTAssertEqual(runs[2].color, "#D32F2F")
        XCTAssertNil(RichTextCodec.runs(of: NSAttributedString(string: "x", attributes: RichTextCodec.defaultAttributes))[0].color)
    }

    func testListPrefixes() {
        XCTAssertEqual(ListFormatting.prefix(of: "• item")?.next, "• ")
        XCTAssertEqual(ListFormatting.prefix(of: "9. item")?.next, "10. ")
        XCTAssertNil(ListFormatting.prefix(of: "2026 foi bom"))
    }
}
