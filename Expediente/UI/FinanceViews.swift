import SwiftUI

/// Mês escolhido com setas.
struct MonthStepper: View {
    @Binding var month: Date
    var body: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Mês anterior")
            Spacer()
            Text(Formatters.capitalizedFirst(Formatters.monthYear.string(from: month))).font(.headline)
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Próximo mês")
        }
        .padding(.vertical, 4)
    }
    private func shift(_ n: Int) { month = Calendar.current.date(byAdding: .month, value: n, to: month) ?? month }
}

struct StatTile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardStyle()
    }
}

// MARK: - Financeiro

struct FinanceView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var month = Date()
    @State private var receiptAppointment: Appointment?
    @State private var receiptPackage: ServicePackage?
    @State private var exportingReceipt = false

    var body: some View {
        let now = Date()
        let interval = Calendar.current.monthInterval(containing: month)
        let s = Finance.summary(store.db, interval: interval, now: now)
        let open = Finance.open(store.db, interval: interval, now: now)
        let received = Finance.received(store.db, interval: interval)
        let paidPackages = Finance.paidPackages(store.db, interval: interval)
        let openPackages = Finance.openPackages(store.db, now: now)
        let olderOpen = Finance.open(store.db, now: now).filter { $0.start < interval.start }
        List {
            Section {
                MonthStepper(month: $month)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    StatTile(title: "Recebido", value: Formatters.money(s.receivedCents), detail: "\(s.receivedCount) \(s.receivedCount == 1 ? "pagamento" : "pagamentos")", color: Theme.paid)
                    StatTile(title: "Despesas", value: Formatters.money(s.expensesCents), detail: "\(s.expensesCount) \(s.expensesCount == 1 ? "lançamento" : "lançamentos")")
                    StatTile(title: "Resultado", value: Formatters.money(s.netCents), detail: "Recebido − despesas", color: s.netCents < 0 ? Theme.unpaid : .primary)
                    StatTile(title: "Em aberto", value: Formatters.money(s.openCents), detail: "\(s.openCount) no mês", color: s.openCents > 0 ? Theme.unpaid : .primary)
                    StatTile(title: "Inadimplência", value: Formatters.percent(s.delinquencyRate), detail: "\(s.delinquentPatientCount) \(s.delinquentPatientCount == 1 ? Term.client : Term.clients)")
                    StatTile(title: "Previsto", value: Formatters.money(s.expectedCents), detail: "\(s.expectedCount) atendimentos futuros")
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
            }

            Section {
                if open.isEmpty { Text("Nada em aberto neste mês.").foregroundStyle(.secondary) }
                ForEach(open) { a in FinanceRow(appointment: a) }
            } header: {
                Text("Atendimentos em aberto")
            } footer: {
                Text("Atendimentos já realizados marcados como não pagos ou sem pagamento informado. Faltas e cancelamentos sem pagamento informado não entram, nem retornos sem custo e atendimentos de pacote. Use Cobrar para mandar o valor (e o Pix) pelo WhatsApp.")
            }

            if !olderOpen.isEmpty {
                Section("Em aberto de meses anteriores") {
                    ForEach(olderOpen) { a in FinanceRow(appointment: a) }
                }
            }

            if !openPackages.isEmpty {
                Section("Pacotes não pagos") {
                    ForEach(openPackages) { p in
                        Button { router.open(.package(p.id)) } label: { PackageRow(package: p) }.buttonStyle(.plain)
                    }
                }
            }

            Section("Recebidos") {
                if received.isEmpty && paidPackages.isEmpty { Text("Nenhum pagamento confirmado neste mês.").foregroundStyle(.secondary) }
                ForEach(paidPackages) { p in
                    HStack {
                        Button { router.open(.package(p.id)) } label: { PackageRow(package: p) }.buttonStyle(.plain)
                        Button { receiptPackage = p; receiptAppointment = nil; exportingReceipt = true } label: { Image(systemName: "doc.text") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Recibo do pacote")
                    }
                }
                ForEach(received) { a in
                    HStack {
                        FinanceRow(appointment: a)
                        Button { receiptAppointment = a; receiptPackage = nil; exportingReceipt = true } label: { Image(systemName: "doc.text") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Recibo")
                    }
                }
            }

            if !s.byMethod.isEmpty {
                Section("Por forma de pagamento") {
                    ForEach(s.byMethod.sorted { $0.value > $1.value }, id: \.key) { item in
                        LabeledContent(item.key.label, value: Formatters.money(item.value))
                    }
                }
            }

            Section {
                Button { router.open(.expenses) } label: { Label("Despesas do mês", systemImage: "cart") }
                Button { router.open(.packages) } label: { Label("Pacotes", systemImage: "square.stack.3d.up") }
            }
        }
        .navigationTitle("Financeiro")
        .navigationBarTitleDisplayMode(.inline)
        .exportFlow(isPresented: $exportingReceipt, allowsPassword: false, fileName: receiptName(), makeData: {
            if let p = receiptPackage, let patient = store.db.patient(p.patientID) {
                let text = PDFExporter.receiptDocument(patient: patient, items: [(p.title, p.priceCents)],
                                                       paidAt: p.paidAt ?? p.purchasedAt, method: p.method, db: store.db)
                return PDFExporter.render(text, footer: "Recibo", letterhead: PDFExporter.letterhead(store))
            }
            guard let a = receiptAppointment.flatMap({ store.appointment($0.id) }), let patient = store.db.patient(a.patientID) else { return nil }
            let text = PDFExporter.receiptDocument(patient: patient, items: PDFExporter.receiptItems([a], db: store.db),
                                                   paidAt: a.paidAt ?? a.start, method: a.method, db: store.db)
            return PDFExporter.render(text, footer: "Recibo", letterhead: PDFExporter.letterhead(store))
        }, onExported: {
            store.audit(.reportExported, "Recibo")
        })
    }

    private func receiptName() -> String {
        let pid = receiptPackage?.patientID ?? receiptAppointment?.patientID
        let date = receiptPackage?.paidAt ?? receiptAppointment?.start ?? Date()
        return "Recibo-\(FileNames.safe(store.db.patient(pid)?.name ?? Term.client))-\(Formatters.isoDay.string(from: date)).pdf"
    }
}

struct FinanceRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    let appointment: Appointment

    var body: some View {
        let a = store.appointment(appointment.id) ?? appointment
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                PatientNameLink(patientID: a.patientID, font: .body.weight(.medium), lineLimit: 1)
                Text("\(Formatters.dateTime.string(from: a.start))\(a.method.map { " · \($0.label)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { router.edit(a.id) }
            Spacer()
            Text(Formatters.money(store.db.price(of: a))).font(.subheadline.monospacedDigit())
            PaymentField(status: a.payment, compact: true) { store.setPayment(a.id, $0) }
        }
        .contextMenu {
            if a.payment != .paid, let url = WhatsAppMessage.chargeLink(for: [a], in: store.db) {
                Button { UIApplication.shared.open(url) } label: { Label("Cobrar pelo WhatsApp", systemImage: "brazilianrealsign.circle") }
            }
        }
    }
}

// MARK: - Relatórios

struct ReportsView: View {
    @EnvironmentObject var store: Store
    @State private var kind: ReportKind = .finance
    @State private var period: ReportPeriod = .thisMonth
    @State private var from = Calendar.current.monthInterval(containing: Date()).start
    @State private var to = Date()
    @State private var patientID: UUID?
    @State private var showPicker = false
    @State private var exporting = false

    private var interval: DateInterval {
        if period == .custom {
            let cal = Calendar.current
            let start = cal.startOfDay(for: min(from, to))
            let end = cal.endOfDay(max(from, to)).addingTimeInterval(1)
            return DateInterval(start: start, end: end)
        }
        return period.interval()
    }

    var body: some View {
        let now = Date()
        Form {
            Section("Relatório") {
                Picker("Tipo", selection: $kind) {
                    ForEach(ReportKind.allCases) { Text($0.label).tag($0) }
                }
                if kind == .patientSessions {
                    Button { showPicker = true } label: {
                        LabeledContent(Term.Client, value: store.db.patient(patientID)?.name ?? "Escolher")
                    }
                    .foregroundStyle(.primary)
                }
                Picker("Período", selection: $period) {
                    ForEach(ReportPeriod.allCases) { Text($0.label).tag($0) }
                }
                if period == .custom {
                    DatePicker("De", selection: $from, displayedComponents: .date)
                    DatePicker("Até", selection: $to, displayedComponents: .date)
                }
            }
            .environment(\.locale, Formatters.locale)

            if kind == .finance {
                financeSection(now: now)
            } else if let p = store.db.patient(patientID) {
                sessionsSection(p, now: now)
            }

            Section {
                Button { exporting = true } label: { Label("Exportar PDF", systemImage: "square.and.arrow.up") }
                    .disabled(kind == .patientSessions && patientID == nil)
            }
        }
        .navigationTitle("Relatórios")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPicker) {
            PatientPickerSheet(title: "Escolher \(Term.client)") { p in
                patientID = p.id
                showPicker = false
            }
        }
        .exportFlow(isPresented: $exporting, fileName: fileName(), makeData: {
            let text: NSAttributedString
            if kind == .finance {
                text = PDFExporter.financeReport(interval: interval, db: store.db)
            } else if let p = store.db.patient(patientID) {
                text = PDFExporter.patientSessionsReport(p, interval: interval, db: store.db)
            } else {
                return nil
            }
            return PDFExporter.render(text, footer: "Relatório · \(store.db.professional.fullName)", letterhead: PDFExporter.letterhead(store))
        }, onExported: {
            store.audit(.reportExported, kind.label)
        })
    }

    @ViewBuilder
    private func financeSection(now: Date) -> some View {
        let s = Finance.summary(store.db, interval: interval, now: now)
        Section("Resumo") {
            LabeledContent("Recebido", value: "\(Formatters.money(s.receivedCents)) (\(s.receivedCount))")
            LabeledContent("Despesas", value: Formatters.money(s.expensesCents))
            LabeledContent("Resultado", value: Formatters.money(s.netCents))
            LabeledContent("Em aberto", value: "\(Formatters.money(s.openCents)) (\(s.openCount))")
            LabeledContent("Inadimplência", value: Formatters.percent(s.delinquencyRate))
            LabeledContent("\(Term.Clients) com valores em aberto", value: "\(s.delinquentPatientCount)")
            LabeledContent("Previsto (atendimentos futuros)", value: Formatters.money(s.expectedCents))
        }
        if !s.expensesByCategory.isEmpty {
            Section("Despesas por categoria") {
                ForEach(s.expensesByCategory.sorted { $0.value > $1.value }, id: \.key) { item in
                    LabeledContent(item.key.label, value: Formatters.money(item.value))
                }
            }
        }
        if !s.openByPatient.isEmpty {
            Section("Em aberto por \(Term.client)") {
                ForEach(s.openByPatient.sorted { $0.value > $1.value }, id: \.key) { item in
                    LabeledContent(store.db.patient(item.key)?.name ?? "—", value: Formatters.money(item.value))
                }
            }
        }
    }

    @ViewBuilder
    private func sessionsSection(_ p: Patient, now: Date) -> some View {
        let list = store.db.appointments(of: p.id).filter { interval.contains($0.start) }
        Section("\(list.count) atendimentos no período") {
            if list.isEmpty { Text("Nenhum atendimento no período.").foregroundStyle(.secondary) }
            ForEach(list) { a in HistoryRow(appointment: a, now: now) }
        }
    }

    private func fileName() -> String {
        let stamp = Formatters.isoDay.string(from: interval.start)
        if kind == .finance { return "Relatorio-financeiro-\(stamp).pdf" }
        return "Relatorio-atendimentos-\(FileNames.safe(store.db.patient(patientID)?.name ?? Term.client))-\(stamp).pdf"
    }
}

// MARK: - Notas fiscais

struct InvoicesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @State private var month = Date()
    @State private var editingFiscal = false
    @State private var selected: Appointment?

    var body: some View {
        let interval = Calendar.current.monthInterval(containing: month)
        let paid = Finance.received(store.db, interval: interval)
        let pending = paid.filter { !$0.hasInvoice }
        let fiscal = store.db.fiscal
        List {
            Section {
                Button { editingFiscal = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fiscal.legalName.isEmpty ? "Preencher dados fiscais" : fiscal.legalName).foregroundStyle(.primary)
                            Text(fiscal.document.isEmpty ? "CPF ou CNPJ, inscrição municipal e serviço" : "\(fiscal.personType == .individual ? "CPF" : "CNPJ") \(fiscal.document) · \(fiscal.serviceItem)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Seus dados fiscais")
            }

            Section {
                MonthStepper(month: $month)
                if paid.isEmpty { Text("Nenhum atendimento pago neste mês.").foregroundStyle(.secondary) }
                ForEach(paid) { a in
                    Button { selected = a } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.db.patient(a.patientID)?.name ?? "").foregroundStyle(.primary)
                                Text("\(Formatters.dateTime.string(from: a.start)) · \(Formatters.money(store.db.price(of: a)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if a.hasInvoice {
                                StatusBadge(text: "NF \(a.invoiceNumber ?? "")", color: Theme.attended)
                            } else if let n = a.nfse, n.state == .unknown {
                                StatusBadge(text: "Conferir", color: .orange)
                            } else if let n = a.nfse, n.state == .issued, n.environment == .homologation {
                                StatusBadge(text: "Teste \(n.number ?? "")", color: .secondary)
                            } else {
                                StatusBadge(text: "Pendente", color: .orange)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Atendimentos pagos")
            } footer: {
                Text(pending.isEmpty ? "Todos os atendimentos pagos do mês têm nota registrada." : "\(pending.count) atendimentos pagos sem nota registrada.")
            }

            Section {
                NavigationLink(value: Route.nfseSettings) { Label("Ajustes da NFS-e (CNPJ, ambiente, série)", systemImage: "gearshape") }
                NavigationLink(value: Route.certificates) { Label("Certificado digital A1", systemImage: "checkmark.seal") }
                Link(destination: URL(string: "https://www.nfse.gov.br/EmissorNacional")!) {
                    Label("Abrir o Emissor Nacional da NFS-e", systemImage: "safari")
                }
            } footer: {
                Text("Toque num atendimento para emitir a NFS-e pelo app (Sistema Nacional, \(Nfse.santoAndreName), com certificado A1) ou registrar uma nota emitida fora dele. Retornos sem custo e atendimentos de pacote não aparecem aqui.")
            }
        }
        .navigationTitle("Notas fiscais")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingFiscal) {
            FiscalProfileEditor(profile: store.db.fiscal) { p in store.update { $0.fiscal = p } }
        }
        .sheet(item: $selected) { a in
            InvoiceSheet(appointment: a).environmentObject(store).environmentObject(toaster)
        }
        .onAppear { if DemoNavigator.consume("nfse"), let a = Finance.received(store.db, interval: Calendar.current.monthInterval(containing: month)).first { selected = a } }
    }
}

struct InvoiceSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    let appointment: Appointment
    @State private var number = ""
    @State private var issued = Date()
    @State private var useGuardian = false
    @State private var working = false
    @State private var outcome: String?
    @State private var askPassword = false
    @State private var password = ""
    @State private var pendingAction: NfseAction?
    @State private var cancelReason = 1
    @State private var cancelText = ""
    @State private var showCancel = false
    @State private var shareXML = false

    enum NfseAction { case issue, cancel }

    var body: some View {
        let a = store.appointment(appointment.id) ?? appointment
        let p = store.db.patient(a.patientID)
        let taker = takerFor(p)
        let problems = NfseService.check(store.db, a, taker: taker, now: Date())
        NavigationStack {
            Form {
                nfseSection(a, patient: p, taker: taker, problems: problems)
                Section("Dados para a nota (emissão fora do app)") {
                    let summary = invoiceText(p, a)
                    Text(summary).font(.callout).textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = summary
                        toaster.show("Dados copiados.")
                    } label: { Label("Copiar dados", systemImage: "doc.on.doc") }
                    if (p?.cpf ?? "").isEmpty {
                        Label("CPF do \(Term.client) não cadastrado.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
                    }
                }
                Section {
                    TextField("Número da NFS-e", text: $number).keyboardType(.numbersAndPunctuation)
                    DatePicker("Emitida em", selection: $issued, displayedComponents: .date).environment(\.locale, Formatters.locale)
                    Button("Salvar registro manual") { save(number: number) }.disabled(number.trimmingCharacters(in: .whitespaces).isEmpty)
                    if a.hasInvoice && a.nfse?.state != .issued {
                        Button("Remover registro da nota", role: .destructive) { save(number: nil) }
                    }
                } header: {
                    Text("Nota emitida fora do app")
                } footer: {
                    Text("Para notas emitidas no Emissor Nacional ou no sistema da prefeitura.")
                }
            }
            .navigationTitle("Nota fiscal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
            .onAppear {
                number = appointment.invoiceNumber ?? ""
                issued = appointment.invoiceIssuedAt ?? Date()
            }
            .alert("Senha do certificado", isPresented: $askPassword) {
                SecureField("Senha", text: $password)
                Button("Continuar") { run(pendingAction, password: password) }
                Button("Cancelar", role: .cancel) {}
            } message: { Text("A NFS-e é assinada e enviada com o seu certificado A1.") }
            .alert("NFS-e", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(outcome ?? "") }
            .sheet(isPresented: $showCancel) { cancelSheet }
            .exportFlow(isPresented: $shareXML, allowsPassword: false, fileName: "NFS-e-\(a.nfse?.number ?? "nota").xml", makeData: {
                NfseService(store: store).xml(store.appointment(appointment.id) ?? appointment)
            }, onExported: {})
        }
        .presentationDetents([.large])
    }

    private func takerFor(_ p: Patient?) -> NfseTaker? {
        guard let p else { return nil }
        if useGuardian, let g = NfseTaker.forGuardian(p) { return g }
        return NfseTaker.forPatient(p)
    }

    @ViewBuilder
    private func nfseSection(_ a: Appointment, patient p: Patient?, taker: NfseTaker?, problems: [String]) -> some View {
        Section {
            if let n = a.nfse, !(Nfse.isTestLeftover(n, fiscal: store.db.fiscal)) {
                LabeledContent("Situação", value: n.state.label)
                if let num = n.number { LabeledContent("Número", value: num) }
                LabeledContent("Ambiente", value: n.environment.shortLabel)
                if let key = n.accessKey {
                    Text("Chave de acesso: \(key)").font(.caption.monospaced()).textSelection(.enabled)
                }
                if let err = n.lastError, n.state != .issued { Text(err).font(.footnote).foregroundStyle(Theme.unpaid) }
                if n.state == .issued {
                    if n.xmlAttachmentID != nil { Button { shareXML = true } label: { Label("Enviar o XML da nota", systemImage: "square.and.arrow.up") } }
                    Link(destination: URL(string: Nfse.publicConsultURL)!) { Label("Consulta pública da NFS-e", systemImage: "safari") }
                    Button("Cancelar esta NFS-e", role: .destructive) { cancelText = ""; showCancel = true }
                } else if n.state == .unknown {
                    Button { check() } label: { Label("Conferir no Sistema Nacional", systemImage: "arrow.clockwise") }
                }
            }
            if a.nfse?.state != .issued || Nfse.isTestLeftover(a.nfse, fiscal: store.db.fiscal) {
                if let p, NfseTaker.forGuardian(p) != nil {
                    Picker("Tomador", selection: $useGuardian) {
                        Text(Term.Client).tag(false)
                        Text("Responsável").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if problems.isEmpty, let taker {
                    Text(NfseService.summary(store.db, a, taker: taker)).font(.footnote)
                    Button { start(.issue) } label: {
                        if working { ProgressView() } else { Label("Emitir NFS-e (\(store.db.fiscal.environment.shortLabel))", systemImage: "paperplane") }
                    }
                    .disabled(working || a.nfse?.state == .unknown)
                } else {
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange) }
                }
            }
        } header: {
            Text("NFS-e Nacional")
        } footer: {
            Text("Emissão pela API do Sistema Nacional da NFS-e, com o seu certificado A1. Cada atendimento tem uma identificação própria de DPS: uma nova tentativa nunca gera nota em dobro.")
        }
    }

    private var cancelSheet: some View {
        NavigationStack {
            Form {
                Picker("Motivo", selection: $cancelReason) {
                    Text(NfseDps.cancellationReasonLabel(1)).tag(1)
                    Text(NfseDps.cancellationReasonLabel(2)).tag(2)
                    Text(NfseDps.cancellationReasonLabel(9)).tag(9)
                }
                Section {
                    TextField("Explique o motivo (15 a 255 caracteres)", text: $cancelText, axis: .vertical).lineLimit(3...6)
                } footer: {
                    Text("\(cancelText.count) caracteres")
                }
            }
            .navigationTitle("Cancelar NFS-e")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Voltar") { showCancel = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cancelar a nota", role: .destructive) {
                        showCancel = false
                        start(.cancel)
                    }
                    .disabled(cancelText.trimmingCharacters(in: .whitespaces).count < 15)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func certificateEntry() -> CertificateEntry? {
        store.certificate(store.db.fiscal.certificateID).flatMap { $0.canSignOnThisDevice ? $0 : nil } ?? store.defaultCertificate()
    }

    private func start(_ action: NfseAction) {
        guard let entry = certificateEntry() else {
            outcome = CertificateError.missing.localizedDescription
            return
        }
        pendingAction = action
        if CertificateKeys.savedPassword(for: entry.id) != nil {
            run(action, password: nil)
        } else {
            password = ""
            askPassword = true
        }
    }

    private func run(_ action: NfseAction?, password: String?) {
        guard let action, let entry = certificateEntry() else { return }
        let a = store.appointment(appointment.id) ?? appointment
        let taker = takerFor(store.db.patient(a.patientID))
        working = true
        Task {
            defer { working = false }
            do {
                let cert = try CertificateKeys.open(entry, store: store, password: password)
                let transport = NfseURLSessionTransport(certificate: cert)
                defer { transport.finish() }
                let service = NfseService(store: store)
                switch action {
                case .issue:
                    guard let taker else { return }
                    outcome = try await service.issue(a.id, taker: taker, identity: cert, transport: transport).message
                case .cancel:
                    outcome = try await service.cancel(a.id, reasonCode: cancelReason, reason: cancelText, identity: cert, transport: transport).message
                }
            } catch {
                outcome = error.localizedDescription
            }
        }
    }

    private func check() {
        guard let entry = certificateEntry() else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let cert = try CertificateKeys.open(entry, store: store, password: nil)
                let transport = NfseURLSessionTransport(certificate: cert)
                defer { transport.finish() }
                outcome = await NfseService(store: store).checkPending(appointment.id, transport: transport).message
            } catch {
                pendingAction = .issue
                outcome = "Para conferir, digite a senha do certificado em Emitir. \(error.localizedDescription)"
            }
        }
    }

    private func invoiceText(_ p: Patient?, _ a: Appointment) -> String {
        let f = store.db.fiscal
        var lines: [String] = []
        lines.append("Tomador: \(p?.name ?? "")")
        if let cpf = p?.cpf, !cpf.isEmpty { lines.append("CPF do tomador: \(cpf)") }
        if let addr = p?.address, !addr.isEmpty { lines.append("Endereço: \(addr)") }
        lines.append("Serviço: \(f.serviceItem)")
        lines.append("Descrição: \(NfseService.description(store.db, a))")
        lines.append("Valor: \(Formatters.money(store.db.price(of: a)))")
        if !f.issRate.isEmpty { lines.append("Alíquota ISS: \(f.issRate)") }
        return lines.joined(separator: "\n")
    }

    private func save(number: String?) {
        var a = store.appointment(appointment.id) ?? appointment
        let n = number?.trimmingCharacters(in: .whitespaces)
        a.invoiceNumber = (n?.isEmpty ?? true) ? nil : n
        a.invoiceIssuedAt = a.invoiceNumber == nil ? nil : issued
        store.updateAppointment(a)
        toaster.show(a.invoiceNumber == nil ? "Registro removido." : "Nota registrada.")
    }
}

struct FiscalProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: FiscalProfile
    let onSave: (FiscalProfile) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Prestador") {
                    Picker("Tipo", selection: $profile.personType) {
                        ForEach(PersonType.allCases) { Text($0.label).tag($0) }
                    }
                    TextField(profile.personType == .individual ? "Nome completo" : "Razão social", text: $profile.legalName)
                    TextField(profile.personType == .individual ? "CPF" : "CNPJ", text: $profile.document).keyboardType(.numbersAndPunctuation)
                    TextField("Inscrição municipal", text: $profile.municipalRegistration).keyboardType(.numbersAndPunctuation)
                    TextField("Regime tributário (ex.: Simples Nacional)", text: $profile.taxRegime)
                }
                Section("Endereço") {
                    TextField("Endereço", text: $profile.address, axis: .vertical)
                    TextField("Município", text: $profile.city)
                    TextField("UF", text: $profile.state).textInputAutocapitalization(.characters)
                }
                Section {
                    TextField("Item da lista de serviços (ex.: 06.01)", text: $profile.serviceItem)
                    TextField("Descrição do serviço", text: $profile.serviceDescription)
                    TextField("Alíquota do ISS (ex.: 2%)", text: $profile.issRate)
                } header: {
                    Text("Serviço")
                } footer: {
                    Text("O item vem da lista da Lei Complementar 116/2003 e depende do serviço que você presta. Confirme o código e a alíquota com seu contador ou com a prefeitura.")
                }
            }
            .navigationTitle("Dados fiscais")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { onSave(profile); dismiss() } }
            }
        }
    }
}
