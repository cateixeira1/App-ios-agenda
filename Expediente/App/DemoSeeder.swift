import CryptoKit
import Foundation
import UIKit

/// Dados de demonstração usados só nas capturas de tela automáticas (argumento "-demo").
/// No app instalado, sem esse argumento, nada aqui é executado.
enum DemoSeeder {
    static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-demo")
        #else
        return false
        #endif
    }

    static var startScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-screen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var ids: [String: UUID] = [:]

    @MainActor
    static func makeAppState() -> AppState {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString)")
        let vault = Vault(directory: dir, iterations: 1_000)
        switch startScreen {
        case "cadastro", "area", "lgpd", "chave":
            return AppState(vault: vault, anchor: MemoryAnchorStore())
        case "bloqueio":
            _ = try? vault.create(firstName: "Caio", email: "caio@exemplo.com", password: "demonstracao")
            return AppState(vault: vault, anchor: MemoryAnchorStore())
        default:
            break
        }
        let key = (try? vault.create(firstName: "Caio", email: "caio@exemplo.com", password: "demonstracao"))?.key
            ?? SymmetricKey(size: .bits256)
        let store = try! Store(vault: vault, key: key, anchor: MemoryAnchorStore(), isDemo: true)
        seed(store)
        return AppState(demoStore: store)
    }

    // MARK: - Dados

    @MainActor
    static func seed(_ store: Store) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let d = cal.date(byAdding: .day, value: dayOffset, to: today)!
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
        }

        store.update { db in
            db.professional = Professional(fullName: "Caio Teixeira", email: "caio@exemplo.com", phone: "")
            db.professional.occupation = "Cabeleireiro"
            db.settings.defaultPriceCents = 12_000
            db.settings.breaks = [WorkBreak()]
            db.settings.workDays = [2, 3, 4, 5, 6]
            db.settings.workdayStartHour = 9
            db.settings.workdayEndHour = 20
            db.settings.defaultLocation = "Rua das Figueiras, 100 – Santo André"
            db.settings.reminderMinutesBefore = 30
            db.settings.pixKey = "caio@exemplo.com"
            db.settings.pixName = "Caio Teixeira"
            db.settings.pixCity = "Santo Andre"
            if (startScreen ?? "") == "semana" { db.settings.agendaMode = .week }
            if (startScreen ?? "") == "mes" { db.settings.agendaMode = .month }
            db.fiscal = FiscalProfile(personType: .individual, legalName: "Caio Teixeira", document: "000.000.000-00",
                                      municipalRegistration: "0.000.000-0", address: "Rua das Figueiras, 100", city: "Santo André",
                                      state: "SP", serviceItem: "06.01 – Barbearia, cabeleireiros, manicuros, pedicuros e congêneres",
                                      serviceDescription: "Serviços de cabeleireiro", issRate: "2%", taxRegime: "MEI")
        }
        store.applyBusinessArea(.beauty)
        store.update { db in
            for name in ["Corte", "Escova", "Sobrancelha"] {
                if let i = db.tags.firstIndex(where: { $0.name == name }) { db.tags[i].defaultPriceCents = name == "Corte" ? 12_000 : (name == "Escova" ? 8_000 : 5_000) }
            }
            if let i = db.tags.firstIndex(where: { $0.name == "Coloração" }) { db.tags[i].defaultPriceCents = 28_000 }
        }
        let tags = store.db.tags
        func tag(_ name: String) -> UUID? { tags.first { $0.name == name }?.id }

        var marina = Patient(name: "Marina Lopes")
        marina.phone = "+55 (11) 98765-4321"
        marina.email = "marina@exemplo.com"
        marina.cpf = "000.000.000-00"
        marina.notes = "Prefere horários de manhã. Sensível a amônia: usar coloração sem amônia."
        let names = ["Rafael Monteiro", "Helena Prado", "Joana Alves", "Beatriz Nogueira", "Lucas Andrade",
                     "Mariana Souza", "Fernanda Ribeiro", "Gustavo Martins", "Ana Clara Duarte"]
        store.addPatient(marina)
        var patients: [String: Patient] = ["Marina Lopes": marina]
        for n in names {
            var p = Patient(name: n)
            // Lucas fica sem telefone, para mostrar o aviso do botão do WhatsApp.
            p.phone = n == "Lucas Andrade" ? "" : "+55 (11) 9\(Int.random(in: 1000...9999))-\(Int.random(in: 1000...9999))"
            patients[n] = store.addPatient(p)
        }
        try? store.attachConsent(demoConsentPDF(), fileName: "Ficha de anamnese - Marina Lopes.pdf", to: marina.id)

        // Pacote de escovas da Marina, pago.
        var pkg = ServicePackage(patientID: marina.id, name: "Pacote 4 escovas", totalSessions: 4, priceCents: 28_000,
                                 tagID: tag("Escova"), purchasedAt: at(-15, 10))
        pkg.payment = .paid
        pkg.method = .pix
        pkg.paidAt = at(-15, 10)
        store.savePackage(pkg)
        ids["package"] = pkg.id
        // Pacote da Helena, ainda não pago.
        store.savePackage(ServicePackage(patientID: patients["Helena Prado"]!.id, name: "Pacote 5 manicures", totalSessions: 5,
                                         priceCents: 30_000, tagID: tag("Manicure e pedicure"), purchasedAt: at(-2, 15)))

        func appt(_ name: String, _ start: Date, tag t: String?, paid: PaymentStatus? = nil, amount: Int? = nil,
                  method: PaymentMethod? = nil, attendance: Attendance = .scheduled, invoice: String? = nil, duration: Int? = nil,
                  package: UUID? = nil) -> Appointment {
            let tagID = t.flatMap(tag)
            var a = Appointment(patientID: patients[name]!.id, start: start, durationMinutes: duration ?? store.db.duration(for: tagID))
            a.tagID = tagID
            a.payment = paid
            a.amountCents = amount
            a.method = method
            a.attendance = attendance
            a.invoiceNumber = invoice
            a.invoiceIssuedAt = invoice == nil ? nil : start
            a.paidAt = paid == .paid ? start : nil
            a.packageID = package
            return a
        }

        var list: [Appointment] = []
        // Hoje
        let todayMarina = appt("Marina Lopes", at(0, 9), tag: "Escova", package: pkg.id)
        let todayRafael = appt("Rafael Monteiro", at(0, 10), tag: "Corte", paid: .unpaid, attendance: .attended)
        list += [todayMarina, todayRafael,
                 appt("Helena Prado", at(0, 11), tag: "Manicure e pedicure", amount: 6_000),
                 appt("Joana Alves", at(0, 14), tag: "Coloração", paid: .paid, method: .credit),
                 appt("Lucas Andrade", at(0, 17), tag: "Corte")]
        ids["todayMarina"] = todayMarina.id
        ids["todayRafael"] = todayRafael.id
        // Semanas anteriores
        for w in 1...4 {
            list.append(appt("Marina Lopes", at(-7 * w, 9), tag: w <= 2 ? "Escova" : "Corte", paid: w <= 2 ? nil : .paid,
                             method: .pix, attendance: .attended, invoice: w == 3 ? "1041" : nil, package: w <= 2 ? pkg.id : nil))
            list.append(appt("Helena Prado", at(-7 * w, 11), tag: "Manicure e pedicure", paid: w == 2 ? nil : .paid, amount: 6_000,
                             method: .transfer, attendance: w == 2 ? .missed : .attended))
            list.append(appt("Joana Alves", at(-7 * w, 14), tag: "Escova", paid: w == 1 ? .unpaid : .paid,
                             method: .credit, attendance: .attended))
        }
        list.append(appt("Rafael Monteiro", at(-3, 16), tag: "Corte", paid: .unpaid, attendance: .attended))
        list.append(appt("Fernanda Ribeiro", at(-2, 11), tag: "Sobrancelha", paid: .paid, method: .cash, attendance: .attended))
        list.append(appt("Gustavo Martins", at(-1, 17), tag: "Corte", attendance: .attended))
        list.append(appt("Marina Lopes", at(-21, 15), tag: "Sobrancelha", attendance: .cancelled))
        ids["marinaLastWeek"] = list.first { $0.patientID == marina.id && cal.isDate($0.start, inSameDayAs: at(-7, 9)) }?.id
        store.update { $0.appointments.append(contentsOf: list) }

        // Série recorrente: Beatriz, toda semana no mesmo horário de amanhã.
        let series = appt("Beatriz Nogueira", at(1, 16), tag: "Escova")
        store.schedule(series, rule: .weekly, until: at(56, 16))
        store.schedule(appt("Marina Lopes", at(7, 9), tag: "Escova", package: pkg.id), rule: .none, until: nil)
        var online = appt("Mariana Souza", at(2, 9), tag: "Corte")
        online.location = "Atendimento em domicílio – Rua Itu, 45"
        store.schedule(online, rule: .none, until: nil)

        // Despesas do mês
        store.saveExpense(Expense(date: at(-5, 9), title: "Aluguel da cadeira", amountCents: 35_000, category: .rent, method: .pix))
        store.saveExpense(Expense(date: at(-3, 9), title: "Tintas e oxidantes", amountCents: 23_500, category: .supplies, method: .debit))
        store.saveExpense(Expense(date: at(-1, 9), title: "Impulsionamento no Instagram", amountCents: 5_000, category: .marketing, method: .credit))

        // Anotações
        func rich(_ s: String) -> RichText {
            let m = NSMutableAttributedString(string: s, attributes: RichTextCodec.defaultAttributes)
            if let r = s.range(of: "\n") {
                let len = s.distance(from: s.startIndex, to: r.lowerBound)
                m.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: RichTextCodec.baseFontSize), range: NSRange(location: 0, length: len))
            }
            return RichTextCodec.encode(m)
        }
        if let id = ids["marinaLastWeek"] {
            store.saveNote(SessionNote(patientID: marina.id, appointmentID: id,
                                       body: rich("Escova\n• Usou o protetor térmico novo.\n• Pediu para testar ondas na próxima.")))
        }
        store.saveNote(SessionNote(patientID: marina.id, appointmentID: todayMarina.id,
                                   body: rich("Hoje\nQuer marcar coloração para o mês que vem.\n1. Tom: castanho médio, mecha 6.0.\n2. Fazer teste de mecha antes.")))

        store.audit(.accountCreated)
        store.audit(.loginPassword)
        store.audit(.biometricsEnabled)
        store.audit(.loginBiometrics)
        try? store.saveNow()
    }

    static func demoConsentPDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { ctx in
            ctx.beginPage()
            ("Ficha de anamnese capilar (modelo de demonstração)" as NSString)
                .draw(in: CGRect(x: 50, y: 60, width: 495, height: 60), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 16)])
        }
    }
}

/// Abre a tela pedida nas capturas de tela automáticas.
@MainActor
enum DemoNavigator {
    static var pending: Set<String> = []

    static var startScreen: String? { DemoSeeder.startScreen }

    static func consume(_ action: String) -> Bool {
        guard DemoSeeder.isActive, pending.contains(action) else { return false }
        pending.remove(action)
        return true
    }

    static func apply(router: Router, store: Store) {
        guard DemoSeeder.isActive, let screen = DemoSeeder.startScreen else { return }
        let today = Date()
        let marina = store.db.patients.first { $0.name == "Marina Lopes" }?.id ?? UUID()
        switch screen {
        case "agenda": router.path = [.agenda(today)]
        case "menu": pending.insert("menu")
        case "retorno": pending.insert("return")
        case "whatsapp-sem-telefone": pending.insert("whatsapp-blocked")
        case "agendar-cliente-novo":
            pending.insert("new-patient")
            let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: today)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { router.newAppointment(start: start) }
        case "historico": router.path = [.patientSessions(marina)]
        case "perfil": router.path = [.settings, .profile]
        case "dias-feriados": router.path = [.settings, .agendaSettings]
        case "certificados": router.path = [.settings, .certificates]
        case "mensagem-whatsapp": router.path = [.settings, .whatsAppMessage]
        case "pix": router.path = [.settings, .pixSettings]
        case "nfse-ajustes": router.path = [.settings, .nfseSettings]
        case "nfse": pending.insert("nfse"); router.path = [.invoices]
        case "cabecalho": router.path = [.settings, .documentLayout]
        case "desmarcar": pending.insert("cancel")
        case "remarcar": pending.insert("reschedule")
        case "agendar":
            pending.insert("suggest")
            let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: today)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { router.newAppointment(start: start) }
        case "clientes": router.path = [.patients]
        case "cliente": router.path = [.patients, .patient(marina)]
        case "anotacao": if let id = DemoSeeder.ids["todayMarina"] { router.path = [.agenda(today), .noteForAppointment(id)] }
        case "anotacoes": router.path = [.notes]
        case "financeiro": router.path = [.finance]
        case "pacotes": router.path = [.packages]
        case "pacote": if let id = DemoSeeder.ids["package"] { router.path = [.packages, .package(id)] }
        case "despesas": router.path = [.expenses]
        case "relatorios": router.path = [.reports]
        case "notas": router.path = [.invoices]
        case "ajustes": router.path = [.settings]
        case "registro": router.path = [.settings, .auditLog]
        case "tags": router.path = [.settings, .tags]
        default: break
        }
    }
}
