import PDFKit
import XCTest
@testable import Expediente

// Funções novas do Expediente: Pix, pacotes, despesas, cobrança, lembretes, local, área de atuação e recibo.

final class PixTests: XCTestCase {
    /// Exemplo do Manual de Padrões para Iniciação do Pix (Banco Central): chave aleatória, sem valor.
    func testCentralBankExample() {
        let code = Pix.payload(key: "123e4567-e12b-12d1-a456-426655440000", name: "Fulano de Tal", city: "BRASILIA", amountCents: nil)
        XCTAssertEqual(code, "00020126580014br.gov.bcb.pix0136123e4567-e12b-12d1-a456-4266554400005204000053039865802BR5913Fulano de Tal6008BRASILIA62070503***63041D3D")
    }

    func testAmountNameAndCityAreNormalized() throws {
        let code = try XCTUnwrap(Pix.payload(key: "+55 (11) 98765-4321", name: "José Antônio da Conceição Ribeiro Filho",
                                             city: "São Bernardo do Campo", amountCents: 15_050))
        XCTAssertTrue(code.contains("0114+5511987654321"))
        XCTAssertTrue(code.contains("5406150.50"))
        XCTAssertTrue(code.contains("5925Jose Antonio da Conceicao"), code)
        XCTAssertTrue(code.contains("6015Sao Bernardo do"), code)
        // O CRC do fim confere com o resto do código.
        let body = String(code.dropLast(4))
        XCTAssertEqual(String(code.suffix(4)), Pix.crc16(body))
    }

    func testKeyRecognition() {
        XCTAssertEqual(Pix.normalizeKey("529.982.247-25")?.kind, .cpf)
        XCTAssertEqual(Pix.normalizeKey("529.982.247-25")?.key, "52998224725")
        XCTAssertEqual(Pix.normalizeKey("11.222.333/0001-81")?.kind, .cnpj)
        XCTAssertEqual(Pix.normalizeKey("(11) 98765-4321")?.key, "+5511987654321")
        XCTAssertEqual(Pix.normalizeKey("Ana@Exemplo.com")?.key, "ana@exemplo.com")
        XCTAssertEqual(Pix.normalizeKey("123E4567-E12B-12D1-A456-426655440000")?.kind, .random)
        XCTAssertNil(Pix.normalizeKey("abc"))
        XCTAssertNil(Pix.normalizeKey(""))
        XCTAssertNil(Pix.payload(key: "ana@exemplo.com", name: "", city: "Santo André", amountCents: 100))
    }
}

final class PackageTests: XCTestCase {
    private func makeDB() -> (Database, Patient, ServicePackage) {
        var db = Database()
        let ana = Patient(name: "Ana Prado")
        db.patients = [ana]
        db.settings.defaultPriceCents = 10_000
        var pkg = ServicePackage(patientID: ana.id, name: "", totalSessions: 3, priceCents: 27_000, purchasedAt: date(2026, 10, 1))
        pkg.payment = .paid
        pkg.paidAt = date(2026, 10, 2)
        pkg.method = .pix
        db.packages = [pkg]
        return (db, ana, pkg)
    }

    func testPackageAppointmentsAreNotChargedAndUseTheBalance() {
        var (db, ana, pkg) = makeDB()
        XCTAssertEqual(pkg.title, "Pacote de 3")
        var a1 = Appointment(patientID: ana.id, start: date(2026, 10, 5, 10))
        a1.packageID = pkg.id
        a1.attendance = .attended
        var a2 = Appointment(patientID: ana.id, start: date(2026, 10, 12, 10))
        a2.packageID = pkg.id
        a2.attendance = .cancelled
        var a3 = Appointment(patientID: ana.id, start: date(2026, 10, 19, 10))
        a3.packageID = pkg.id
        a3.attendance = .missed
        db.appointments = [a1, a2, a3]
        XCTAssertTrue(Billing.isNoCharge(a1, in: db))
        XCTAssertEqual(db.price(of: a1), 0)
        XCTAssertFalse(Finance.isOpen(a1, in: db, now: date(2026, 10, 30)))
        // Cancelado com aviso não gasta o pacote; falta gasta.
        XCTAssertEqual(Packages.used(pkg, in: db), 2)
        XCTAssertEqual(Packages.remaining(pkg, in: db), 1)
        XCTAssertEqual(Packages.usageLabel(pkg, in: db), "2 de 3 usados · 1 restante")
        XCTAssertTrue(Packages.isAvailable(pkg, in: db, now: date(2026, 10, 20)))
        pkg.expiresAt = date(2026, 10, 15)
        db.packages = [pkg]
        XCTAssertFalse(Packages.isAvailable(pkg, in: db, now: date(2026, 10, 20)))
        XCTAssertTrue(Packages.available(for: ana.id, in: db, now: date(2026, 10, 20)).isEmpty)
    }

    func testFinanceCountsPackagePaymentAndExpenses() {
        var (db, ana, pkg) = makeDB()
        var single = Appointment(patientID: ana.id, start: date(2026, 10, 6, 10))
        single.payment = .paid
        var inPackage = Appointment(patientID: ana.id, start: date(2026, 10, 7, 10))
        inPackage.packageID = pkg.id
        db.appointments = [single, inPackage]
        var open = ServicePackage(patientID: ana.id, totalSessions: 2, priceCents: 15_000, purchasedAt: date(2026, 10, 10))
        open.payment = nil
        db.packages.append(open)
        db.expenses = [Expense(date: date(2026, 10, 3), title: "Aluguel", amountCents: 20_000, category: .rent),
                       Expense(date: date(2026, 11, 3), title: "Outro mês", amountCents: 99_000, category: .other)]
        let month = testCalendar.monthInterval(containing: date(2026, 10, 15))
        let s = Finance.summary(db, interval: month, now: date(2026, 10, 15))
        XCTAssertEqual(s.receivedCents, 10_000 + 27_000)
        XCTAssertEqual(s.packagesReceivedCents, 27_000)
        XCTAssertEqual(s.byMethod[.pix], 27_000)
        XCTAssertEqual(s.openCents, 15_000)
        XCTAssertEqual(s.packagesOpenCount, 1)
        XCTAssertEqual(s.expensesCents, 20_000)
        XCTAssertEqual(s.expensesByCategory[.rent], 20_000)
        XCTAssertEqual(s.netCents, 37_000 - 20_000)
        XCTAssertEqual(Finance.openPackages(db, now: date(2026, 10, 15)).map(\.id), [open.id])
        _ = pkg
    }

    @MainActor
    func testScheduleSeriesFillsOnlyThePackageBalance() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let key = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1").key
        let store = try Store(vault: vault, key: key, anchor: MemoryAnchorStore())
        let p = store.addPatient(Patient(name: "Bruno"))
        let pkg = ServicePackage(patientID: p.id, totalSessions: 2, priceCents: 20_000)
        store.savePackage(pkg)
        var template = Appointment(patientID: p.id, start: date(2026, 10, 20, 16))
        template.packageID = pkg.id
        let created = store.schedule(template, rule: .weekly, until: date(2026, 11, 10))
        XCTAssertEqual(created.count, 4)
        XCTAssertEqual(created.filter { $0.packageID == pkg.id }.count, 2)
        XCTAssertEqual(Packages.remaining(pkg, in: store.db), 0)
        // Excluir o pacote: os atendimentos ficam e passam a ser cobrados um a um.
        store.deletePackage(pkg.id)
        XCTAssertEqual(store.db.appointments.count, 4)
        XCTAssertTrue(store.db.appointments.allSatisfy { $0.packageID == nil })
    }
}

final class ChargeAndReminderTests: XCTestCase {
    func testChargeMessageCarriesTotalAndPix() {
        var db = Database()
        var ana = Patient(name: "Ana Prado")
        ana.phone = "+55 (11) 98765-4321"
        db.patients = [ana]
        var a1 = Appointment(patientID: ana.id, start: localDate(2026, 10, 20, 9))
        a1.amountCents = 8_000
        var a2 = Appointment(patientID: ana.id, start: localDate(2026, 10, 27, 9))
        a2.amountCents = 7_000
        db.appointments = [a1, a2]
        let plain = WhatsAppMessage.chargeMessage(for: [a1], in: db)
        XCTAssertEqual(plain, "Olá, Ana! O valor do atendimento de 20/10 ficou em \(Formatters.money(8_000)).")
        db.settings.pixKey = "ana.profissional@exemplo.com"
        db.settings.pixName = "Profissional"
        db.settings.pixCity = "Santo André"
        let withPix = WhatsAppMessage.chargeMessage(for: [a2, a1], in: db)
        XCTAssertTrue(withPix.hasPrefix("Olá, Ana! O valor dos atendimentos de 20/10 e 27/10 ficou em \(Formatters.money(15_000))."), withPix)
        XCTAssertTrue(withPix.contains("Pix copia e cola:\n000201"))
        XCTAssertTrue(withPix.contains("5406150.00"))
        XCTAssertNotNil(WhatsAppMessage.chargeLink(for: [a1, a2], in: db))
        db.settings.chargeTemplate = "{nome}, deu {valor}. {pix}"
        XCTAssertTrue(WhatsAppMessage.chargeMessage(for: [a1], in: db).hasPrefix("Ana, deu \(Formatters.money(8_000)). 000201"))
    }

    func testRemindersBeforeEachAppointment() {
        var db = Database()
        let ana = Patient(name: "Ana Prado")
        db.patients = [ana]
        let a1 = Appointment(patientID: ana.id, start: date(2026, 10, 20, 9))
        var a2 = Appointment(patientID: ana.id, start: date(2026, 10, 20, 14))
        a2.attendance = .cancelled
        let a3 = Appointment(patientID: ana.id, start: date(2026, 10, 21, 9))
        db.appointments = [a1, a2, a3]
        let now = date(2026, 10, 20, 8, 45)
        XCTAssertTrue(Documentation.upcomingReminders(for: db, now: now).isEmpty, "Desligado por padrão")
        db.settings.reminderMinutesBefore = 30
        let list = Documentation.upcomingReminders(for: db, now: now)
        // O de 9:00 já passou do horário do aviso (8:30); o cancelado não avisa.
        XCTAssertEqual(list.map(\.appointmentIDs), [[a3.id]])
        XCTAssertEqual(list.first?.fireDate, date(2026, 10, 21, 8, 30))
        XCTAssertEqual(list.first?.title, "Em 30 min: Ana Prado")
        db.settings.reminderShowsNames = false
        XCTAssertEqual(Documentation.upcomingReminders(for: db, now: now).first?.title, "Em 30 min: Próximo atendimento")
    }

    func testPlaces() {
        XCTAssertTrue(Places.isLink("https://meet.google.com/abc"))
        XCTAssertTrue(Places.isLink("zoom.us/j/123"))
        XCTAssertEqual(Places.url(for: "zoom.us/j/123")?.absoluteString, "https://zoom.us/j/123")
        XCTAssertTrue(Places.isOnline("On-line"))
        XCTAssertNil(Places.url(for: "Online"))
        XCTAssertEqual(Places.url(for: "Rua A, 1")?.host, "maps.apple.com")
    }
}

final class AreaAndReceiptTests: XCTestCase {
    @MainActor
    func testBusinessAreaReplacesUnusedTagsAndSetsTerm() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        let key = try vault.create(firstName: "Ana", email: "a@b.c", password: "senha-forte-1").key
        let store = try Store(vault: vault, key: key, anchor: MemoryAnchorStore())
        let p = store.addPatient(Patient(name: "Bruno"))
        let used = store.db.tags[1]
        store.schedule(Appointment(patientID: p.id, start: date(2026, 10, 20, 9), tagID: used.id), rule: .none, until: nil)
        store.applyBusinessArea(.classes)
        XCTAssertEqual(store.db.settings.clientTerm, .student)
        XCTAssertEqual(Term.Clients, "Alunos")
        XCTAssertTrue(store.db.tags.contains { $0.id == used.id }, "Tag usada na agenda fica")
        XCTAssertTrue(store.db.tags.contains { $0.name == "Aula experimental" })
        XCTAssertFalse(store.db.tags.contains { $0.name == "Primeiro atendimento" })
        store.update { $0.settings.clientTerm = .client }
        XCTAssertEqual(Term.client, "cliente")
    }

    func testEveryAreaHasTagsAndReturnOrReplacement() {
        for area in BusinessArea.allCases {
            XCTAssertGreaterThanOrEqual(area.presetTags.count, 5, area.label)
            XCTAssertEqual(Set(area.presetTags.map(\.name)).count, area.presetTags.count, area.label)
        }
    }

    func testNumberWords() {
        XCTAssertEqual(NumberWords.words(1), "um")
        XCTAssertEqual(NumberWords.words(21), "vinte e um")
        XCTAssertEqual(NumberWords.words(100), "cem")
        XCTAssertEqual(NumberWords.words(150), "cento e cinquenta")
        XCTAssertEqual(NumberWords.words(1_000), "mil")
        XCTAssertEqual(NumberWords.words(1_100), "mil e cem")
        XCTAssertEqual(NumberWords.words(2_350), "dois mil trezentos e cinquenta")
        XCTAssertEqual(PDFExporter.moneyInWords(15_030), "cento e cinquenta reais e trinta centavos")
        XCTAssertEqual(PDFExporter.moneyInWords(100), "um real")
    }

    func testReceiptPDF() throws {
        var db = Database()
        db.professional = Professional(fullName: "Caio Teixeira")
        db.professional.occupation = "Cabeleireiro"
        db.fiscal.document = "529.982.247-25"
        var ana = Patient(name: "Ana Prado")
        ana.cpf = "000.000.000-00"
        db.patients = [ana]
        var a = Appointment(patientID: ana.id, start: date(2026, 10, 20, 9))
        a.amountCents = 15_000
        a.payment = .paid
        db.appointments = [a]
        let text = PDFExporter.receiptDocument(patient: ana, items: PDFExporter.receiptItems([a], db: db),
                                               paidAt: date(2026, 10, 20, 10), method: .pix, db: db)
        let doc = try XCTUnwrap(PDFDocument(data: PDFExporter.render(text, footer: "Recibo")))
        let s = doc.string ?? ""
        XCTAssertTrue(s.contains("Recibo"))
        XCTAssertTrue(s.contains("Ana Prado"))
        XCTAssertTrue(s.contains("150,00"))
        XCTAssertTrue(s.contains("CPF 529.982.247-25"))
    }
}
