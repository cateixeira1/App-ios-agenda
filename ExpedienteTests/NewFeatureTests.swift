import CryptoKit
import PDFKit
import Security
import XCTest
@testable import Expediente

// Compatibilidade dos dados, calendário real, WhatsApp, máscaras, certificado A1 e NFS-e.

final class CompatibilityTests: XCTestCase {
    /// Dados de uma versão anterior (sem os campos novos) continuam abrindo, e campos desconhecidos são ignorados.
    func testOldDataOpens() throws {
        let json = """
        {"version":1,"professional":{"fullName":"Ana","email":"a@b.c","phone":""},
        "patients":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Marina Lopes","phone":"(11) 98765-4321","email":"","cpf":"","address":"Rua X, 1","guardianName":"","guardianPhone":"","notes":"","medications":[],"createdAt":700000000,"archived":false}],
        "appointments":[{"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","patientID":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":783000000,"durationMinutes":50,"attendance":"scheduled"}],
        "notes":[],"tags":[{"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","name":"Corte","colorHex":"#B39DDB"}],
        "settings":{"patientRowHeight":64,"endOfDayReminder":true,"reminderShowsNames":true,"defaultDurationMinutes":50,"lockAfterSeconds":0,"workdayStartHour":7,"workdayEndHour":21,"includeInDeviceBackup":false},
        "fiscal":{"personType":"individual","legalName":"","document":"","municipalRegistration":"","address":"","city":"","state":"","serviceItem":"","serviceDescription":"","issRate":"","taxRegime":""}}
        """
        let db = try JSONDecoder().decode(Database.self, from: Data(json.utf8))
        XCTAssertEqual(db.professional.occupation, "")
        XCTAssertEqual(db.settings.firstSessionDurationMinutes, 60)
        XCTAssertEqual(db.settings.workDays, [1, 2, 3, 4, 5])
        XCTAssertEqual(db.settings.agendaMode, .day)
        XCTAssertEqual(db.settings.clientTerm, .client)
        XCTAssertEqual(db.settings.reminderMinutesBefore, 0)
        XCTAssertEqual(db.appointments[0].location, "")
        XCTAssertNil(db.appointments[0].packageID)
        XCTAssertTrue(db.packages.isEmpty && db.expenses.isEmpty)
        XCTAssertEqual(db.fiscal.municipalityCode, Nfse.santoAndre)
        let again = try JSONDecoder().decode(Database.self, from: JSONEncoder().encode(db))
        XCTAssertEqual(again, db)
    }

    @MainActor
    func testJSONBackupIsRecognized() throws {
        let vault = Vault(directory: tempDirectory(), iterations: 1_000)
        _ = try vault.create(firstName: "Ana", email: "ana@exemplo.com", password: "senha-forte-1")
        let plist = try Backup.parse(try { () throws -> Data in
            let key = try vault.unlock(email: "ana@exemplo.com", password: "senha-forte-1")
            let store = try Store(vault: vault, key: key, anchor: MemoryAnchorStore(), isDemo: true)
            return try store.makeBackup()
        }())
        let json = try JSONEncoder().encode(plist)
        let parsed = try Backup.parse(json)
        XCTAssertEqual(parsed.meta, plist.meta)
        XCTAssertEqual(parsed.data, plist.data)
    }
}

final class CalendarRuleTests: XCTestCase {
    func testNationalHolidays2026() {
        let days = Set(Holidays.national(2026).map { Formatters.isoDay.string(from: $0.date) })
        for d in ["2026-01-01", "2026-02-16", "2026-02-17", "2026-04-03", "2026-04-21", "2026-05-01", "2026-06-04",
                  "2026-09-07", "2026-10-12", "2026-11-02", "2026-11-15", "2026-11-20", "2026-12-25"] {
            XCTAssertTrue(days.contains(d), d)
        }
    }

    func testWeekendGoesToPreviousBusinessDay() {
        let s = AppSettings()
        let adj = BusinessDayRule.adjust(date(2026, 10, 24, 15), durationMinutes: 50, settings: s, isFree: { _, _ in true },
                                         now: date(2026, 10, 1), calendar: .current)
        XCTAssertEqual(adj.kind, .sameTimeEarlier)
        XCTAssertTrue(Calendar.current.isDate(adj.proposed, inSameDayAs: date(2026, 10, 23)))
        let finados = BusinessDayRule.adjust(date(2026, 11, 2, 9), durationMinutes: 50, settings: s, isFree: { _, _ in true }, now: date(2026, 10, 1))
        XCTAssertEqual(finados.reason, "feriado: Finados")
        XCTAssertTrue(Calendar.current.isDate(finados.proposed, inSameDayAs: date(2026, 10, 30)))
    }

    func testBreaksAndMonthlySeries() {
        var s = AppSettings()
        s.breaks = [WorkBreak()]
        XCTAssertNotNil(WorkBreaks.hit(s, start: localDate(2026, 10, 23, 12, 30), minutes: 30))
        XCTAssertNil(WorkBreaks.hit(s, start: localDate(2026, 10, 23, 13), minutes: 30))
        let monthly = Recurrence.dates(start: date(2026, 1, 31, 10), rule: .monthly, until: date(2026, 4, 30))
        XCTAssertEqual(monthly.map { Calendar.current.component(.day, from: $0) }, [31, 28, 31, 30])
    }

    func testSeriesPlanAdjustsHolidays() {
        // Toda segunda a partir de 26/10/2026: a de 2/11 (Finados) volta para sexta, 30/10.
        let plan = RecurrencePlanner.plan(start: date(2026, 10, 26, 9), rule: .weekly, until: date(2026, 11, 9), settings: AppSettings(),
                                          booked: [], now: date(2026, 10, 1), durationMinutes: 50)
        XCTAssertEqual(plan.count, 3)
        XCTAssertTrue(plan[1].adjusted)
        XCTAssertTrue(Calendar.current.isDate(plan[1].date, inSameDayAs: date(2026, 10, 30)))
    }

    func testTagDurationAndFirstSession() {
        var db = Database()
        let first = db.firstSessionTag()!
        XCTAssertEqual(first.name, "Primeiro atendimento")
        XCTAssertEqual(db.duration(for: first.id), 60)
        db.settings.firstSessionDurationMinutes = 80
        XCTAssertEqual(db.duration(for: first.id), 80)
        var t = db.tags[1]
        t.durationMinutes = 40
        db.tags[1] = t
        XCTAssertEqual(db.duration(for: t.id), 40)
        XCTAssertEqual(db.duration(for: nil), 60)
    }

    func testPatientHistoryBadges() {
        let now = date(2026, 10, 23, 12)
        var a = Appointment(patientID: UUID(), start: date(2026, 10, 20, 9))
        XCTAssertEqual(SessionHistory.badge(a, now: now), .presence)
        a.attendance = .cancelled
        XCTAssertEqual(SessionHistory.badge(a, now: now), .cancelled)
        a.attendance = .missed
        XCTAssertEqual(SessionHistory.badge(a, now: now), .absence)
        a.attendance = .scheduled
        a.start = date(2026, 10, 30, 9)
        XCTAssertEqual(SessionHistory.badge(a, now: now), .scheduled)
    }
}

/// Data no fuso do aparelho (para textos com horário).
func localDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

final class WhatsAppAndMaskTests: XCTestCase {
    func testDefaultMessageAndLink() {
        let now = localDate(2026, 10, 23, 8)
        XCTAssertEqual(WhatsAppMessage.compose(nil, firstName: "Ana", start: localDate(2026, 10, 23, 14), now: now),
                       "Olá, Ana! Confirmando nosso horário hoje às 14:00. Até logo!")
        XCTAssertEqual(WhatsAppMessage.compose(nil, firstName: "Ana", start: localDate(2026, 10, 24, 9), now: now),
                       "Olá, Ana! Confirmando nosso horário amanhã às 09:00. Até logo!")
        XCTAssertEqual(WhatsAppMessage.compose("{Primeiro nome}, {data} às {hora} em {local}.", firstName: "Ana",
                                               start: localDate(2026, 10, 27, 9), place: "Rua A, 1", now: now),
                       "Ana, na terça, 27/10 às 09:00 em Rua A, 1.")
        XCTAssertEqual(WhatsAppMessage.relativeDay(localDate(2026, 10, 31, 9), now: now), "no sábado, 31/10")
        XCTAssertEqual(WhatsAppMessage.linkPhone("+55 (11) 98765-4321"), "5511987654321")
        XCTAssertNil(WhatsAppMessage.linkPhone("98765-4321"))
        XCTAssertEqual(WhatsAppMessage.link(phone: "5511987654321", text: "Olá, Ana!")?.absoluteString,
                       "https://wa.me/5511987654321?text=Ol%C3%A1%2C%20Ana%21")
        var p = Patient(name: "Ana Souza")
        p.phone = "+55"
        Term.kind = .client
        XCTAssertEqual(WhatsAppMessage.blockReason(p), "Sem telefone no cadastro do cliente.")
        Term.kind = .student
        XCTAssertEqual(WhatsAppMessage.blockReason(p), "Sem telefone no cadastro do aluno.")
        Term.kind = .client
    }

    func testButtonFromTodayOn() {
        let now = localDate(2026, 10, 23, 18)
        var a = Appointment(patientID: UUID(), start: localDate(2026, 10, 23, 14))
        XCTAssertTrue(WhatsAppMessage.showsButton(a, now: now))
        a.attendance = .cancelled
        XCTAssertFalse(WhatsAppMessage.showsButton(a, now: now))
        a.attendance = .scheduled
        a.start = localDate(2026, 10, 24, 14)
        XCTAssertTrue(WhatsAppMessage.showsButton(a, now: now))
        a.start = localDate(2026, 10, 22, 14)
        XCTAssertFalse(WhatsAppMessage.showsButton(a, now: now))
    }

    func testMasks() {
        XCTAssertEqual(Masks.phone("5511987654321"), "+55 (11) 98765-4321")
        XCTAssertEqual(Masks.phone("+5511"), "+55 (11")
        XCTAssertEqual(Masks.phoneToSave("+55"), "")
        XCTAssertEqual(Masks.cpf("52998224725"), "529.982.247-25")
        XCTAssertTrue(Masks.isValidCNPJ("12.ABC.345/01DE-35"))
        XCTAssertEqual(Masks.problem(.cpf, "529.982.247-26"), "CPF inválido: os dígitos verificadores não conferem.")
    }

    /// O retorno parte do princípio de que não tem custo, mas aceita um valor (no atendimento ou na tag).
    func testReturnHasNoChargeUnlessPriced() {
        var db = Database()
        var a = Appointment(patientID: UUID(), start: date(2026, 10, 1, 9))
        a.tagID = db.returnTag()?.id
        db.appointments = [a]
        XCTAssertEqual(db.price(of: a), 0)
        XCTAssertTrue(Billing.isNoCharge(a, in: db))
        XCTAssertFalse(Finance.isOpen(a, in: db, now: date(2026, 10, 2)))
        // Valor digitado na própria sessão.
        a.amountCents = 30_000
        XCTAssertFalse(Billing.isNoCharge(a, in: db))
        XCTAssertEqual(db.price(of: a), 30_000)
        // Valor definido na tag de retorno.
        a.amountCents = nil
        if let i = db.tags.firstIndex(where: { $0.id == a.tagID }) { db.tags[i].defaultPriceCents = 12_000 }
        XCTAssertFalse(Billing.isNoCharge(a, in: db))
        XCTAssertEqual(db.price(of: a), 12_000)
    }

    func testTagPriceComesBeforePatientAndDefaultPrice() {
        var db = Database()
        var p = Patient(name: "Ana")
        p.sessionPriceCents = 15_000
        db.patients = [p]
        db.settings.defaultPriceCents = 10_000
        var a = Appointment(patientID: p.id, start: date(2026, 10, 1, 9))
        db.appointments = [a]
        XCTAssertEqual(db.price(of: a), 15_000)
        let tag = db.tags[0]
        a.tagID = tag.id
        db.tags[0].defaultPriceCents = 25_000
        XCTAssertEqual(db.price(of: a), 25_000)
        a.amountCents = 5_000
        XCTAssertEqual(db.price(of: a), 5_000)
    }

    /// Com "valor por cliente" ligado, o valor do cadastro do cliente vale em qualquer tag; o retorno segue sem custo.
    func testPriceByClientIgnoresTagPrice() {
        var db = Database()
        var p = Patient(name: "Ana")
        p.sessionPriceCents = 15_000
        db.patients = [p]
        db.settings.defaultPriceCents = 10_000
        db.tags[0].defaultPriceCents = 25_000
        var a = Appointment(patientID: p.id, start: date(2026, 10, 1, 9))
        a.tagID = db.tags[0].id
        XCTAssertEqual(db.price(of: a), 25_000)
        db.settings.priceByClient = true
        XCTAssertEqual(db.price(of: a), 15_000)
        db.patients[0].sessionPriceCents = nil
        XCTAssertEqual(db.price(of: a), 10_000)
        // Valor digitado na sessão continua valendo.
        a.amountCents = 5_000
        XCTAssertEqual(db.price(of: a), 5_000)
        // O retorno continua sem custo, mesmo com valor na tag.
        var r = Appointment(patientID: p.id, start: date(2026, 10, 2, 9))
        r.tagID = db.returnTag()?.id
        if let i = db.tags.firstIndex(where: { $0.id == r.tagID }) { db.tags[i].defaultPriceCents = 12_000 }
        XCTAssertTrue(Billing.isNoCharge(r, in: db))
        db.settings.priceByClient = false
        XCTAssertFalse(Billing.isNoCharge(r, in: db))
    }

    func testMoneyMask() {
        XCTAssertEqual(Formatters.moneyMask(""), "")
        XCTAssertEqual(Formatters.moneyMask("1"), "0,01")
        XCTAssertEqual(Formatters.moneyMask("18"), "0,18")
        XCTAssertEqual(Formatters.moneyMask("180"), "1,80")
        XCTAssertEqual(Formatters.moneyMask("18000"), "180,00")
        XCTAssertEqual(Formatters.moneyMask("120000"), "1.200,00")
        XCTAssertEqual(Formatters.moneyMask("1.200,000"), "12.000,00")
        XCTAssertEqual(Formatters.moneyMask("0,0"), "")
        XCTAssertEqual(Formatters.moneyMask("R$ 18000"), "180,00")
        XCTAssertEqual(Formatters.parseMoney(Formatters.moneyMask("120050")), 120_050)
        XCTAssertEqual(Formatters.moneyMasked(18_005), "180,05")
        XCTAssertEqual(Formatters.moneyMasked(nil), "")
        XCTAssertEqual(Formatters.moneyPlaceholder(nil), "0,00")
    }

    func testWhatsAppMessageComesFromTagWhenSet() {
        var db = Database()
        var p = Patient(name: "Ana Souza")
        p.phone = "+55 (11) 98765-4321"
        db.patients = [p]
        var a = Appointment(patientID: p.id, start: localDate(2026, 10, 23, 14))
        a.tagID = db.tags[0].id
        let now = localDate(2026, 10, 23, 8)
        XCTAssertEqual(WhatsAppMessage.message(for: a, in: db, now: now), "Olá, Ana! Confirmando nosso horário hoje às 14:00. Até logo!")
        db.tags[0].whatsAppMessage = "Oi, {nome}! Seu primeiro atendimento é às {horário}, em {local}."
        db.settings.defaultLocation = "Rua B, 2"
        XCTAssertEqual(WhatsAppMessage.message(for: a, in: db, now: now), "Oi, Ana! Seu primeiro atendimento é às 14:00, em Rua B, 2.")
        a.location = "https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(WhatsAppMessage.message(for: a, in: db, now: now), "Oi, Ana! Seu primeiro atendimento é às 14:00, em https://meet.google.com/abc-defg-hij.")
        db.tags[0].whatsAppMessage = "   "
        XCTAssertEqual(WhatsAppMessage.message(for: a, in: db, now: now), "Olá, Ana! Confirmando nosso horário hoje às 14:00. Até logo!")
    }

    func testTodayFocusFollowsTheClock() {
        let p = UUID()
        func session(_ h: Int, _ m: Int = 0, cancelled: Bool = false) -> Appointment {
            var a = Appointment(patientID: p, start: localDate(2026, 10, 23, h, m), durationMinutes: 50)
            if cancelled { a.attendance = .cancelled }
            return a
        }
        let a9 = session(9), a10 = session(10), a11cancelled = session(11, cancelled: true), a14 = session(14)
        let list = [a9, a10, a11cancelled, a14]
        // Antes da primeira: a primeira.
        XCTAssertEqual(TodayFocus.focus(list, now: localDate(2026, 10, 23, 7))?.id, a9.id)
        // Em andamento: o atendimento atual, e o próximo é o seguinte.
        XCTAssertEqual(TodayFocus.focus(list, now: localDate(2026, 10, 23, 9, 30))?.id, a9.id)
        XCTAssertEqual(TodayFocus.next(list, now: localDate(2026, 10, 23, 9, 30))?.id, a10.id)
        // Entre atendimentos: o próximo (o cancelado não conta).
        XCTAssertEqual(TodayFocus.focus(list, now: localDate(2026, 10, 23, 10, 55))?.id, a14.id)
        // Depois da última: a última do dia.
        XCTAssertEqual(TodayFocus.focus(list, now: localDate(2026, 10, 23, 18))?.id, a14.id)
        XCTAssertNil(TodayFocus.next(list, now: localDate(2026, 10, 23, 18)))
        XCTAssertNil(TodayFocus.focus([], now: localDate(2026, 10, 23, 18)))
    }
}

/// Saída de teste para conferir fora do app (o GitHub valida o XML com o Java).
func writeCIOutput(_ data: Data, name: String) {
    let dir = URL(fileURLWithPath: "/tmp/expediente-ci", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent(name))
}

final class CertificateAndSigningTests: XCTestCase {
    func testOpensLegacyAndModernPfx() throws {
        for p12 in [TestCertificates.legacyP12, TestCertificates.modernP12] {
            let c = try CertificateKeys.open(pfx: p12, password: TestCertificates.password)
            XCTAssertEqual(c.info.holderName, "MARIA DA SILVA")
            XCTAssertEqual(c.info.documents.cpf, "52998224725")
            XCTAssertEqual(c.info.thumbprint, TestCertificates.thumbprint)
            XCTAssertTrue(c.info.isIcpBrasil)
        }
        XCTAssertThrowsError(try CertificateKeys.open(pfx: TestCertificates.legacyP12, password: "errada")) {
            XCTAssertEqual($0 as? CertificateError, .wrongPassword)
        }
    }

    func testDpsIsSignedAndVerifies() throws {
        let c = try CertificateKeys.open(pfx: TestCertificates.legacyP12, password: TestCertificates.password)
        var d = DpsData()
        d.issuedAt = date(2026, 10, 23, 10)
        d.competence = date(2026, 10, 22)
        d.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        d.number = 15
        d.providerCnpj = "11222333000181"
        d.takerCpf = "52998224725"
        d.takerName = "Marina Lopes"
        d.description = "Serviços de cabeleireiro em 22/10/2026."
        d.taxCode = "060101"
        d.valueCents = 25_000
        let xml = try NfseDps.build(d)
        try NfseDps.sign(xml, identity: c)
        let text = NfseDps.xmlString(xml)
        XCTAssertTrue(text.contains("<infDPS Id=\"DPS354780921122233300018100001000000000000015\">"))
        // Confere a assinatura do SignedInfo com a chave pública do certificado.
        let si = NfseDps.signedInfo(referenceID: d.id, digest: String(text.components(separatedBy: "<DigestValue>")[1].prefix { $0 != "<" }))
        let value = Data(base64Encoded: String(text.components(separatedBy: "<SignatureValue>")[1].prefix { $0 != "<" }))!
        let pub = SecCertificateCopyKey(c.certificate)!
        XCTAssertTrue(SecKeyVerifySignature(pub, .rsaSignatureMessagePKCS1v15SHA1, Data(si.canonical(namespace: NfseDps.dsigNamespace).utf8) as CFData,
                                            value as CFData, nil))
        writeCIOutput(Data(text.utf8), name: "dps.xml")
        writeCIOutput(c.info.der, name: "cert.der")
    }

    func testRejectsInvalidDps() {
        var d = DpsData()
        d.providerCnpj = "11222333000182"
        XCTAssertThrowsError(try NfseDps.build(d)) { e in
            guard case .validation(let problems)? = e as? NfseError else { return XCTFail() }
            XCTAssertTrue(problems.contains("CNPJ do prestador inválido (Notas fiscais › Seus dados fiscais)."))
        }
    }

    func testGzipRoundTrip() {
        let text = String(repeating: "<DPS>teste ç ã</DPS>", count: 200)
        let gz = Gzip.compress(Data(text.utf8))
        XCTAssertEqual(gz.prefix(2), Data([0x1F, 0x8B]))
        XCTAssertEqual(Gzip.decompress(gz), Data(text.utf8))
    }
}
