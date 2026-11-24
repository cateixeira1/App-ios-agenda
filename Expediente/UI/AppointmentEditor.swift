import SwiftUI

/// Novo agendamento ou edição de um horário.
struct AppointmentEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @EnvironmentObject var router: Router
    @Environment(\.dismiss) private var dismiss
    let draft: AppointmentDraft

    @State private var nameQuery = ""
    @State private var patientID: UUID?
    @State private var newPhone = Masks.phonePrefix
    @State private var newPrice = ""
    @State private var day = Date()
    @State private var time = Date()
    @State private var duration = 60
    /// A duração foi mudada à mão (então trocar a tag não muda mais a duração).
    @State private var durationEdited = false
    @State private var tagID: UUID?
    @State private var rule: RepeatRule = .none
    @State private var hasEnd = false
    @State private var until = Date()
    @State private var payment: PaymentStatus?
    @State private var amountText = ""
    @State private var method: PaymentMethod?
    @State private var attendance: Attendance = .scheduled
    @State private var location = ""
    @State private var packageID: UUID?
    @State private var loaded = false
    @State private var confirmDelete = false
    @State private var confirmBreak = false
    @State private var planBox: PlanBox?
    @State private var returning: Appointment?
    @FocusState private var nameFocused: Bool

    private var isNew: Bool { draft.appointmentID == nil }
    private var existing: Appointment? { store.appointment(draft.appointmentID) }
    private var start: Date { Calendar.current.combine(day: day, time: time) }

    var body: some View {
        NavigationStack {
            Form {
                patientSection
                Section("Horário") {
                    DatePicker("Dia", selection: $day, displayedComponents: .date)
                    DatePicker("Início", selection: $time, displayedComponents: .hourAndMinute)
                    DurationPicker("Duração", minutes: Binding(get: { duration }, set: { duration = $0; durationEdited = true }))
                    if !conflicts.isEmpty {
                        Label("Já existe atendimento nesse horário: \(conflicts.compactMap { store.db.patient($0.patientID)?.firstName }.joined(separator: ", ")).",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if let b = breakHit {
                        Label(WorkBreaks.warning(b), systemImage: "fork.knife").font(.footnote).foregroundStyle(.orange)
                    }
                    let holidays = HolidayCalendar(store.db.settings)
                    if !holidays.isBusinessDay(start) {
                        Label("Esse dia é \(BusinessDayRule.reason(for: start, holidays: holidays)).", systemImage: "calendar.badge.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                .environment(\.locale, Formatters.locale)

                if isNew {
                    Section {
                        Picker("Repetir", selection: $rule) {
                            ForEach(RepeatRule.allCases) { Text($0.label).tag($0) }
                        }
                        if rule != .none {
                            Toggle("Data de término", isOn: $hasEnd)
                            if hasEnd {
                                DatePicker("Até", selection: $until, in: day..., displayedComponents: .date)
                                    .environment(\.locale, Formatters.locale)
                            }
                        }
                    } header: {
                        Text("Atendimento recorrente")
                    } footer: {
                        if rule != .none {
                            let count = Recurrence.dates(start: start, rule: rule, until: hasEnd ? until : nil).count
                            Text("\(Recurrence.describe(start: start, rule: rule)). Serão criados \(count) atendimentos\(hasEnd ? "" : " (12 meses)"). As que caírem em fim de semana, feriado ou dia sem atendimento seguem a regra de dias úteis, com a sua aprovação.")
                        }
                    }
                }

                Section("Tag") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button { pickTag(nil) } label: { TagChip(tag: nil, selected: tagID == nil) }
                                .buttonStyle(.plain)
                            ForEach(store.db.tags) { t in
                                Button { pickTag(t.id) } label: { TagChip(tag: t, selected: tagID == t.id) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    TextField(defaultPlace.isEmpty ? "Endereço, Online ou link da reunião" : defaultPlace, text: $location, axis: .vertical)
                        .textInputAutocapitalization(.sentences)
                        .lineLimit(1...3)
                } header: {
                    Text("Local")
                } footer: {
                    Text(defaultPlace.isEmpty
                         ? "Opcional. Endereço abre no Mapas; link (Meet, Zoom, Teams) abre direto. Dá para usar {local} na mensagem do WhatsApp."
                         : "Vazio = o local padrão de Ajustes › Agenda.")
                }

                if !packageOptions.isEmpty || packageID != nil {
                    Section {
                        Picker("Pacote", selection: $packageID) {
                            Text("Cobrar avulso").tag(UUID?.none)
                            ForEach(packageOptions) { p in
                                Text("\(p.title) · \(Packages.remaining(p, in: store.db)) restantes").tag(UUID?.some(p.id))
                            }
                        }
                    } header: {
                        Text("Pacote")
                    } footer: {
                        Text("No pacote, o atendimento não é cobrado sozinho: o pagamento é o do pacote, e o saldo diminui.")
                    }
                }

                Section {
                    if inPackage {
                        Label("Atendimento do pacote: não pede pagamento e não entra sozinho no financeiro nem nas notas fiscais.",
                              systemImage: "square.stack.3d.up").font(.subheadline)
                    } else if noCharge {
                        Label("Retorno sem custo: o atendimento não pede pagamento e não entra no financeiro nem nas notas fiscais.",
                              systemImage: "checkmark.seal").font(.subheadline)
                    } else {
                        HStack {
                            Spacer()
                            PaymentField(status: payment) { payment = $0 }
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    }
                    if !inPackage {
                        HStack {
                            Text("Valor")
                            Spacer()
                            MoneyField(placeholderPrice, text: $amountText)
                        }
                    }
                    if !noCharge && !inPackage {
                        Picker("Forma", selection: $method) {
                            Text("Não informada").tag(PaymentMethod?.none)
                            ForEach(PaymentMethod.allCases) { Text($0.label).tag(PaymentMethod?.some($0)) }
                        }
                    }
                } header: {
                    Text("Pagamento")
                } footer: {
                    if isReturnTag {
                        Text("O retorno não tem custo, a não ser que você digite um valor aqui ou defina um valor para a tag em Ajustes › Tags.")
                    }
                }

                if !isNew, let a = existing {
                    Section("Presença") {
                        Picker("Situação", selection: $attendance) {
                            ForEach(Attendance.allCases) { Text($0.shortLabel).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        if attendance == .cancelled {
                            Text("Cancelado com aviso: continua no histórico, não conta como falta e o horário fica livre (e não gasta o pacote).")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        Button { returning = a } label: { Label("Agendar retorno", systemImage: "arrow.uturn.forward.circle") }
                        Button("Desmarcar este horário", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "Agendar" : "Editar atendimento")
            .navigationBarTitleDisplayMode(.inline)
            .routeDestinations()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Agendar" : "Salvar") {
                        if breakHit != nil { confirmBreak = true } else { save() }
                    }
                    .disabled(resolvedPatient == nil && nameQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("Horário no intervalo", isPresented: $confirmBreak) {
                Button("Marcar mesmo assim") { save() }
                Button("Escolher outro horário", role: .cancel) {}
            } message: { Text(breakHit.map(WorkBreaks.warning) ?? "") }
            .confirmationDialog("Desmarcar este atendimento?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Registrar como cancelado com aviso") {
                    if let id = draft.appointmentID { store.cancelWithNotice(id) }
                    toaster.show("Atendimento registrado como cancelado com aviso.")
                    dismiss()
                }
                Button("Apagar e liberar o horário", role: .destructive) {
                    if let id = draft.appointmentID { store.cancel(id, scope: .single) }
                    toaster.show("Horário liberado.")
                    dismiss()
                }
                if existing?.seriesID != nil {
                    Button("Apagar este e os próximos da série", role: .destructive) {
                        if let id = draft.appointmentID { store.cancel(id, scope: .thisAndFollowing) }
                        toaster.show("Horários liberados.")
                        dismiss()
                    }
                }
                Button("Manter agendamento", role: .cancel) {}
            } message: {
                Text("Cancelado com aviso: continua no histórico do \(Term.client), sem contar como falta. Apagar: o atendimento sai da agenda; as anotações continuam no cadastro.")
            }
            .sheet(item: $planBox) { box in
                SeriesApprovalSheet(plan: box.items) { approved in
                    planBox = nil
                    finishSeries(approved)
                }
            }
            .sheet(item: $returning) { a in
                ReturnSheet(from: a) { created in
                    returning = nil
                    toaster.show("Retorno agendado para \(Formatters.dateTime.string(from: created.start)).")
                    dismiss()
                }
                .environmentObject(store)
            }
            .onAppear(perform: load)
        }
    }

    /// O atendimento é de um pacote.
    private var inPackage: Bool { packageID != nil && store.db.package(packageID) != nil }

    private var defaultPlace: String { store.db.settings.defaultLocation.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Pacotes do cliente com saldo (mais o pacote já escolhido, mesmo sem saldo).
    private var packageOptions: [ServicePackage] {
        guard let p = resolvedPatient else { return [] }
        var list = Packages.available(for: p.id, in: store.db)
        if let current = store.db.package(packageID), current.patientID == p.id, !list.contains(where: { $0.id == current.id }) {
            list.insert(current, at: 0)
        }
        return list
    }

    /// O atendimento tem a tag de retorno.
    private var isReturnTag: Bool {
        guard let tagID, let r = store.db.returnTag() else { return false }
        return r.id == tagID
    }

    /// Retorno sem valor (nem no atendimento, nem na tag): não tem custo.
    private var noCharge: Bool {
        guard isReturnTag, let r = store.db.returnTag() else { return false }
        return (Formatters.parseMoney(amountText) ?? store.db.tagPrice(r) ?? 0) == 0
    }

    private var breakHit: WorkBreaks.Slot? { WorkBreaks.hit(store.db.settings, start: start, minutes: duration) }

    private func pickTag(_ id: UUID?) {
        tagID = id
        // A duração acompanha o tipo de serviço (tag), a não ser que tenha sido mudada à mão.
        if !durationEdited { duration = store.db.duration(for: id) }
    }

    // MARK: - Cliente com sugestões

    private var resolvedPatient: Patient? {
        if let patientID, let p = store.db.patient(patientID), NameMatcher.normalize(p.name) == NameMatcher.normalize(nameQuery) { return p }
        return NameMatcher.exactMatch(for: nameQuery, in: store.activePatients)
    }

    @ViewBuilder
    private var patientSection: some View {
        let linked = resolvedPatient
        let suggestions = nameQuery.isEmpty || linked != nil ? [] : NameMatcher.suggestions(for: nameQuery, in: store.activePatients)
        let typed = nameQuery.trimmingCharacters(in: .whitespaces)
        Section {
            HStack {
                TextField("Nome do \(Term.client)", text: $nameQuery)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                    .font(.body.weight(linked == nil ? .regular : .semibold))
                if let linked {
                    NavigationLink(value: Route.patient(linked.id)) {
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Theme.paid)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Abrir o cadastro de \(linked.name)")
                }
            }
            ForEach(suggestions) { p in
                Button {
                    patientID = p.id
                    nameQuery = p.name
                    nameFocused = false
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle").foregroundStyle(Theme.plum)
                        Text(p.name).foregroundStyle(.primary)
                        Spacer()
                        Text("Usar").font(.subheadline).foregroundStyle(Theme.plum)
                    }
                    .frame(minHeight: 34)
                }
            }
            if linked == nil && !typed.isEmpty {
                PhoneField(title: "Telefone", text: $newPhone)
                if store.db.settings.priceByClient {
                    HStack {
                        Text("Valor do atendimento")
                        Spacer()
                        MoneyField(Formatters.moneyPlaceholder(store.db.settings.defaultPriceCents), text: $newPrice)
                    }
                }
            }
        } header: {
            Text(Term.Client)
        } footer: {
            if linked != nil {
                Text("Anotações e financeiro deste horário ficam ligados a este \(Term.client).")
            } else if !suggestions.isEmpty {
                Text("Toque no nome certo para vincular, ou continue para cadastrar “\(typed)” como \(Term.client) novo.")
            } else if !typed.isEmpty {
                Text("“\(typed)” será cadastrado como \(Term.client) novo, com este telefone. O botão do WhatsApp usa o telefone do cadastro.")
            }
        }
    }

    private var placeholderPrice: String {
        if isReturnTag {
            let r = store.db.tagPrice(store.db.returnTag()) ?? 0
            return r > 0 ? Formatters.moneyMasked(r) : "Sem custo"
        }
        let p = store.db.tagPrice(store.db.tag(tagID)) ?? resolvedPatient?.sessionPriceCents ?? store.db.settings.defaultPriceCents
        return Formatters.moneyPlaceholder(p)
    }

    private var conflicts: [Appointment] {
        Conflicts.overlapping(start: start, durationMinutes: duration, in: store.db.appointments, excluding: draft.appointmentID)
    }

    // MARK: - Carregar e salvar

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let a = existing {
            patientID = a.patientID
            nameQuery = store.db.patient(a.patientID)?.name ?? ""
            day = a.start
            time = a.start
            duration = a.durationMinutes
            durationEdited = true
            tagID = a.tagID
            payment = a.payment
            amountText = Formatters.moneyMasked(a.amountCents)
            method = a.method
            attendance = a.attendance
            location = a.location
            packageID = store.db.package(a.packageID) == nil ? nil : a.packageID
        } else {
            let s = draft.start ?? nextRoundHour()
            day = s
            time = s
            duration = store.db.duration(for: nil)
            until = Calendar.current.date(byAdding: .month, value: 6, to: s) ?? s
            if let pid = draft.patientID, let p = store.db.patient(pid) {
                patientID = p.id
                nameQuery = p.name
                packageID = Packages.available(for: p.id, in: store.db).first?.id
            } else if DemoNavigator.consume("suggest") {
                nameQuery = "Mari"
            } else if DemoNavigator.consume("new-patient") {
                nameQuery = "Paula Mendes"
                newPhone = "+55 (11) 91234-5678"
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { nameFocused = true }
            }
        }
    }

    private func nextRoundHour() -> Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return cal.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private func resolvePatientForSave() -> Patient? {
        if let p = resolvedPatient { return p }
        let name = nameQuery.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var p = Patient(name: name)
        p.phone = Masks.phoneToSave(newPhone)
        if store.db.settings.priceByClient { p.sessionPriceCents = Formatters.parseMoney(newPrice) }
        return store.addPatient(p)
    }

    private func save() {
        let amount = noCharge || inPackage ? nil : Formatters.parseMoney(amountText)
        let pkg = packageOptions.contains { $0.id == packageID } ? packageID : nil
        if var a = existing {
            guard let patient = resolvePatientForSave() else { return }
            a.patientID = patient.id
            if a.start != start, a.attendance == .cancelled, attendance == .cancelled { attendance = .scheduled }
            a.start = start
            a.durationMinutes = duration
            a.tagID = tagID
            a.amountCents = amount
            a.method = method
            a.attendance = attendance
            a.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
            a.packageID = pkg
            store.updateAppointment(a)
            store.setPayment(a.id, noCharge || pkg != nil ? nil : payment)
            toaster.show("Atendimento atualizado.")
            dismiss()
            return
        }
        if rule != .none {
            let p = RecurrencePlanner.plan(start: start, rule: rule, until: hasEnd ? until : nil, settings: store.db.settings,
                                           booked: store.db.appointments, now: Date(), durationMinutes: duration)
            if p.contains(where: \.adjusted) {
                planBox = PlanBox(items: p)
                return
            }
            finishSeries(p)
            return
        }
        finishSeries([PlannedOccurrence(original: start, date: start, adjusted: false)])
    }

    private func finishSeries(_ approved: [PlannedOccurrence]) {
        guard let patient = resolvePatientForSave() else { return }
        var a = Appointment(patientID: patient.id, start: start, durationMinutes: duration)
        a.tagID = tagID
        let pkg = Packages.available(for: patient.id, in: store.db).contains { $0.id == packageID } ? packageID : nil
        a.packageID = pkg
        a.amountCents = noCharge || pkg != nil ? nil : Formatters.parseMoney(amountText)
        a.method = method
        a.location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = store.schedule(a, dates: RecurrencePlanner.dates(approved))
        if let first = created.first, payment != nil, !noCharge, pkg == nil { store.setPayment(first.id, payment) }
        let outside = created.filter { pkg != nil && $0.packageID == nil }.count
        if outside > 0 {
            toaster.show("\(created.count) atendimentos agendados. \(outside) não couberam no pacote e serão cobrados avulsos.")
        } else {
            toaster.show(created.count == 1 ? "Atendimento agendado." : "\(created.count) atendimentos agendados.")
        }
        dismiss()
    }
}

private struct PlanBox: Identifiable {
    let id = UUID()
    var items: [PlannedOccurrence]
}

/// Aprovação dos atendimentos da série que caíram em folga: proposta, dia original ou não agendar.
struct SeriesApprovalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var plan: [PlannedOccurrence]
    let onApprove: ([PlannedOccurrence]) -> Void

    var body: some View {
        let adjusted = plan.indices.filter { plan[$0].adjusted }
        NavigationStack {
            List {
                Section {
                    Text("\(adjusted.count) \(adjusted.count == 1 ? "atendimento cai" : "atendimentos caem") em fim de semana, feriado ou dia sem atendimento. Escolha o que fazer com cada uma. As demais \(plan.count - adjusted.count) ficam como estão.")
                        .font(.subheadline)
                }
                ForEach(adjusted, id: \.self) { i in
                    let o = plan[i]
                    Section {
                        Label("\(Formatters.capitalizedFirst(Formatters.weekdayName(o.original))), \(Formatters.dateTime.string(from: o.original)) · \(o.adjustment?.reason ?? "")",
                              systemImage: "calendar.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                        if let adj = o.adjustment { Text(adj.explanation).font(.footnote).foregroundStyle(.secondary) }
                        Picker("Agendar", selection: Binding(get: { plan[i].choice }, set: { plan[i].resolve($0) })) {
                            if o.adjustment?.kind != .noSlot, let p = o.adjustment?.proposed {
                                Text("Na proposta: \(Formatters.weekdayName(p)), \(Formatters.dateTime.string(from: p))").tag(OccurrenceChoice.useProposal)
                            }
                            Text("No dia original").tag(OccurrenceChoice.keepOriginal)
                            Text("Não agendar esta").tag(OccurrenceChoice.skip)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle("Atendimentos em folga")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Voltar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agendar \(plan.filter(\.included).count)") { onApprove(plan) }
                }
            }
            .onAppear {
                for i in plan.indices where plan[i].adjusted && plan[i].adjustment?.kind == .noSlot { plan[i].resolve(.keepOriginal) }
            }
        }
    }
}
