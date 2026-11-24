import SwiftUI

// MARK: - Pacotes

struct PackageRow: View {
    @EnvironmentObject var store: Store
    let package: ServicePackage

    var body: some View {
        let p = package
        let now = Date()
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.db.patient(p.patientID)?.name ?? Term.Client).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text("\(p.title) · \(Packages.usageLabel(p, in: store.db))").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    if p.closed {
                        StatusBadge(text: "Encerrado", color: .secondary)
                    } else if p.isExpired(now: now) {
                        StatusBadge(text: "Vencido", color: .orange)
                    } else if Packages.remaining(p, in: store.db) == 0 {
                        StatusBadge(text: "Concluído", color: Theme.attended)
                    }
                    if let e = p.expiresAt, !p.closed { Text("Validade \(Formatters.shortDate.string(from: e))").font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Formatters.money(p.priceCents)).font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                PaymentSeal(status: p.payment ?? .unpaid)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Todos os pacotes, ou só os de um cliente.
struct PackagesListView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    let patientID: UUID?
    @State private var editing: ServicePackage?
    @State private var pickingPatient = false
    @State private var showFinished = false

    var body: some View {
        let now = Date()
        let all = patientID.map { Packages.of($0, in: store.db) } ?? store.db.packages.sorted { $0.purchasedAt > $1.purchasedAt }
        let active = all.filter { Packages.isAvailable($0, in: store.db, now: now) }
        let finished = all.filter { !Packages.isAvailable($0, in: store.db, now: now) }
        List {
            if all.isEmpty {
                EmptyStateView(symbol: "square.stack.3d.up", title: "Nenhum pacote",
                               message: "Venda vários atendimentos de uma vez (ex.: 10 aulas, 4 sessões). O \(Term.client) paga o pacote, e cada atendimento marcado nele desconta do saldo.")
                    .listRowBackground(Color.clear)
            }
            if !active.isEmpty {
                Section("Com saldo") {
                    ForEach(active) { p in
                        Button { router.open(.package(p.id)) } label: { PackageRow(package: p) }.buttonStyle(.plain)
                    }
                }
            }
            if !finished.isEmpty {
                Section {
                    if showFinished || patientID != nil {
                        ForEach(finished) { p in
                            Button { router.open(.package(p.id)) } label: { PackageRow(package: p) }.buttonStyle(.plain)
                        }
                    } else {
                        Button("Mostrar \(finished.count) concluídos, vencidos ou encerrados") { showFinished = true }
                    }
                } header: {
                    Text("Sem saldo")
                }
            }
        }
        .navigationTitle(patientID.flatMap { store.db.patient($0)?.firstName }.map { "Pacotes de \($0)" } ?? "Pacotes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let patientID { editing = newPackage(for: patientID) } else { pickingPatient = true }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Vender pacote")
            }
        }
        .sheet(isPresented: $pickingPatient) {
            PatientPickerSheet(title: "Pacote para") { p in
                pickingPatient = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { editing = newPackage(for: p.id) }
            }
            .environmentObject(store)
        }
        .sheet(item: $editing) { p in
            PackageEditor(package: p, isNew: store.db.package(p.id) == nil) { saved in
                store.savePackage(saved)
                toaster.show("Pacote salvo.")
            }
            .environmentObject(store)
        }
    }

    private func newPackage(for patientID: UUID) -> ServicePackage {
        var p = ServicePackage(patientID: patientID)
        // Sugere o valor: o da tag mais usada pelo cliente (ou o padrão) vezes a quantidade.
        let tags = store.db.appointments(of: patientID).compactMap(\.tagID)
        let common = Dictionary(grouping: tags, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        p.tagID = common
        let unit = store.db.tagPrice(store.db.tag(common)) ?? store.db.patient(patientID)?.sessionPriceCents ?? store.db.settings.defaultPriceCents ?? 0
        p.priceCents = unit * p.totalSessions
        return p
    }
}

struct PackageEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var package: ServicePackage
    let isNew: Bool
    let onSave: (ServicePackage) -> Void
    @State private var priceText = ""
    @State private var hasExpiry = false
    @State private var expiry = Date()

    init(package: ServicePackage, isNew: Bool, onSave: @escaping (ServicePackage) -> Void) {
        _package = State(initialValue: package)
        self.isNew = isNew
        self.onSave = onSave
        _priceText = State(initialValue: Formatters.moneyMasked(package.priceCents))
        _hasExpiry = State(initialValue: package.expiresAt != nil)
        _expiry = State(initialValue: package.expiresAt ?? (Calendar.current.date(byAdding: .month, value: 3, to: package.purchasedAt) ?? Date()))
    }

    var body: some View {
        let used = Packages.used(package, in: store.db)
        NavigationStack {
            Form {
                Section {
                    LabeledContent(Term.Client, value: store.db.patient(package.patientID)?.name ?? "")
                    TextField("Nome (ex.: Pacote 10 aulas)", text: $package.name)
                    Stepper("Atendimentos: \(package.totalSessions)", value: $package.totalSessions, in: max(1, used)...200)
                    Picker("Serviço", selection: $package.tagID) {
                        Text("Qualquer").tag(UUID?.none)
                        ForEach(store.db.tags) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    HStack {
                        Text("Valor do pacote")
                        Spacer()
                        MoneyField("0,00", text: $priceText)
                    }
                    if let cents = Formatters.parseMoney(priceText), cents > 0, package.totalSessions > 1 {
                        Text("\(Formatters.money(cents / package.totalSessions)) por atendimento").font(.caption).foregroundStyle(.secondary)
                    }
                } footer: {
                    if !isNew { Text("\(used) já \(used == 1 ? "usado" : "usados"). A quantidade não pode ficar abaixo disso.") }
                }
                Section {
                    DatePicker("Vendido em", selection: $package.purchasedAt, displayedComponents: .date)
                    Toggle("Validade", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("Vale até", selection: $expiry, in: package.purchasedAt..., displayedComponents: .date)
                    }
                } footer: {
                    Text("Depois da validade, o saldo não aparece mais no agendamento.")
                }
                .environment(\.locale, Formatters.locale)
                Section("Pagamento") {
                    HStack {
                        Spacer()
                        PaymentField(status: package.payment) { s in
                            package.payment = s
                            package.paidAt = s == .paid ? (package.paidAt ?? Date()) : nil
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    Picker("Forma", selection: $package.method) {
                        Text("Não informada").tag(PaymentMethod?.none)
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag(PaymentMethod?.some($0)) }
                    }
                }
                Section("Observações") {
                    TextField("Ex.: parcelado em 2x", text: $package.notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .navigationTitle(isNew ? "Novo pacote" : "Editar pacote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        package.priceCents = Formatters.parseMoney(priceText) ?? 0
                        package.expiresAt = hasExpiry ? Calendar.current.endOfDay(expiry) : nil
                        package.name = package.name.trimmingCharacters(in: .whitespaces)
                        onSave(package)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct PackageDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    let packageID: UUID
    @State private var editing: ServicePackage?
    @State private var confirmDelete = false
    @State private var exportingReceipt = false
    @State private var blocked: String?

    var body: some View {
        if let p = store.db.package(packageID) {
            content(p)
        } else {
            EmptyStateView(symbol: "square.stack.3d.up", title: "Pacote não encontrado")
        }
    }

    private func content(_ p: ServicePackage) -> some View {
        let now = Date()
        let list = Packages.usedAppointments(p, in: store.db)
        let remaining = Packages.remaining(p, in: store.db)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    PatientNameLink(patientID: p.patientID, font: .title3.bold())
                    Text(p.title).font(.headline)
                    ProgressView(value: Double(p.totalSessions - remaining), total: Double(max(p.totalSessions, 1)))
                        .tint(Theme.plum)
                    Text(Packages.usageLabel(p, in: store.db)).font(.subheadline).foregroundStyle(.secondary)
                    if let t = store.db.tag(p.tagID) { Text("Serviço: \(t.name)").font(.caption).foregroundStyle(.secondary) }
                    if let e = p.expiresAt {
                        Text(p.isExpired(now: now) ? "Venceu em \(Formatters.shortDate.string(from: e))" : "Vale até \(Formatters.shortDate.string(from: e))")
                            .font(.caption).foregroundStyle(p.isExpired(now: now) ? .orange : .secondary)
                    }
                }
                .padding(.vertical, 4)
                if Packages.isAvailable(p, in: store.db, now: now) {
                    Button { router.newAppointment(patientID: p.patientID) } label: {
                        Label("Agendar no pacote", systemImage: "calendar.badge.plus")
                    }
                }
            }
            Section("Pagamento") {
                HStack {
                    Text(Formatters.money(p.priceCents)).font(.headline.monospacedDigit())
                    Spacer()
                    PaymentField(status: p.payment, compact: true) { store.setPackagePayment(p.id, $0) }
                }
                if let m = p.method { LabeledContent("Forma", value: m.label) }
                if p.isPaid {
                    if let d = p.paidAt { LabeledContent("Pago em", value: Formatters.shortDate.string(from: d)) }
                    Button { exportingReceipt = true } label: { Label("Recibo em PDF", systemImage: "doc.text") }
                } else if p.priceCents > 0 {
                    Button {
                        if let url = WhatsAppMessage.chargeLink(for: p, in: store.db) {
                            UIApplication.shared.open(url)
                        } else {
                            blocked = WhatsAppMessage.blockReason(store.db.patient(p.patientID)) ?? ""
                        }
                    } label: { Label("Cobrar pelo WhatsApp", systemImage: "brazilianrealsign.circle") }
                }
            }
            Section("Atendimentos do pacote") {
                if list.isEmpty { Text("Nenhum atendimento ainda.").foregroundStyle(.secondary) }
                ForEach(list) { a in
                    Button { router.edit(a.id) } label: { HistoryRow(appointment: a, now: now) }.buttonStyle(.plain)
                }
            }
            if !p.notes.isEmpty {
                Section("Observações") { Text(p.notes) }
            }
            Section {
                Button {
                    var q = p
                    q.closed.toggle()
                    store.savePackage(q)
                    toaster.show(q.closed ? "Pacote encerrado." : "Pacote reaberto.")
                } label: { Label(p.closed ? "Reabrir pacote" : "Encerrar pacote", systemImage: "archivebox") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Excluir pacote", systemImage: "trash") }
            } footer: {
                Text("Encerrar: o saldo não aparece mais no agendamento (ex.: pacote devolvido). Excluir: os atendimentos continuam na agenda e passam a ser cobrados um a um.")
            }
        }
        .navigationTitle("Pacote")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Editar") { editing = p } } }
        .sheet(item: $editing) { q in
            PackageEditor(package: q, isNew: false) { saved in store.savePackage(saved) }.environmentObject(store)
        }
        .confirmationDialog("Excluir este pacote?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir pacote", role: .destructive) {
                store.deletePackage(p.id)
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        }
        .alert("Não dá para abrir o WhatsApp", isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(blocked ?? "") }
        .exportFlow(isPresented: $exportingReceipt, allowsPassword: false,
                    fileName: "Recibo-\(FileNames.safe(store.db.patient(p.patientID)?.name ?? Term.client))-pacote.pdf", makeData: {
            guard let patient = store.db.patient(p.patientID) else { return nil }
            let text = PDFExporter.receiptDocument(patient: patient, items: [(p.title, p.priceCents)],
                                                   paidAt: p.paidAt ?? p.purchasedAt, method: p.method, db: store.db)
            return PDFExporter.render(text, footer: "Recibo", letterhead: PDFExporter.letterhead(store))
        }, onExported: { store.audit(.reportExported, "Recibo de pacote") })
    }
}

// MARK: - Despesas

struct ExpensesView: View {
    @EnvironmentObject var store: Store
    @State private var month = Date()
    @State private var editing: Expense?

    var body: some View {
        let interval = Calendar.current.monthInterval(containing: month)
        let list = Finance.expenses(store.db, interval: interval)
        let total = list.reduce(0) { $0 + $1.amountCents }
        let byCategory = Dictionary(grouping: list, by: \.category).mapValues { $0.reduce(0) { $0 + $1.amountCents } }
        List {
            Section {
                MonthStepper(month: $month)
                StatTile(title: "Despesas do mês", value: Formatters.money(total), detail: "\(list.count) \(list.count == 1 ? "lançamento" : "lançamentos")")
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            if list.isEmpty {
                EmptyStateView(symbol: "cart", title: "Nenhuma despesa", message: "Registre aluguel, material, transporte e o que mais sair do caixa para ver o resultado do mês no Financeiro.")
                    .listRowBackground(Color.clear)
            } else {
                Section("Lançamentos") {
                    ForEach(list) { e in
                        Button { editing = e } label: {
                            HStack(spacing: 10) {
                                Image(systemName: e.category.symbol).foregroundStyle(Theme.plum).frame(width: 26)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(e.title.isEmpty ? e.category.label : e.title).foregroundStyle(.primary)
                                    Text("\(Formatters.shortDate.string(from: e.date)) · \(e.category.label)\(e.method.map { " · \($0.label)" } ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Formatters.money(e.amountCents)).font(.subheadline.monospacedDigit()).foregroundStyle(.primary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in idx.map { list[$0].id }.forEach(store.deleteExpense) }
                }
                Section("Por categoria") {
                    ForEach(byCategory.sorted { $0.value > $1.value }, id: \.key) { item in
                        LabeledContent(item.key.label, value: Formatters.money(item.value))
                    }
                }
            }
        }
        .navigationTitle("Despesas")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = newExpense(interval) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nova despesa")
            }
        }
        .sheet(item: $editing) { e in
            ExpenseEditor(expense: e, isNew: !store.db.expenses.contains { $0.id == e.id }) { saved in store.saveExpense(saved) }
        }
    }

    private func newExpense(_ interval: DateInterval) -> Expense {
        let now = Date()
        return Expense(date: interval.contains(now) ? now : interval.start)
    }
}

struct ExpenseEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var expense: Expense
    let isNew: Bool
    let onSave: (Expense) -> Void
    @State private var amountText = ""

    init(expense: Expense, isNew: Bool, onSave: @escaping (Expense) -> Void) {
        _expense = State(initialValue: expense)
        self.isNew = isNew
        self.onSave = onSave
        _amountText = State(initialValue: Formatters.moneyMasked(expense.amountCents))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Descrição (ex.: Aluguel da sala)", text: $expense.title)
                    HStack {
                        Text("Valor")
                        Spacer()
                        MoneyField("0,00", text: $amountText)
                    }
                    DatePicker("Data", selection: $expense.date, displayedComponents: .date)
                        .environment(\.locale, Formatters.locale)
                    Picker("Categoria", selection: $expense.category) {
                        ForEach(ExpenseCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Forma", selection: $expense.method) {
                        Text("Não informada").tag(PaymentMethod?.none)
                        ForEach(PaymentMethod.allCases) { Text($0.label).tag(PaymentMethod?.some($0)) }
                    }
                }
                Section("Observações") {
                    TextField("Opcional", text: $expense.notes, axis: .vertical).lineLimit(2...5)
                }
            }
            .navigationTitle(isNew ? "Nova despesa" : "Despesa")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        expense.amountCents = Formatters.parseMoney(amountText) ?? 0
                        expense.title = expense.title.trimmingCharacters(in: .whitespaces)
                        onSave(expense)
                        dismiss()
                    }
                    .disabled((Formatters.parseMoney(amountText) ?? 0) == 0)
                }
            }
        }
        .presentationDetents([.large])
    }
}
