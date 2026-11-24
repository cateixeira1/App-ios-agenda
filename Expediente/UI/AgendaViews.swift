import SwiftUI

/// Agenda de um dia aberta por outra tela (ex.: a partir de um aviso).
struct AgendaView: View {
    @State private var day: Date
    init(initialDay: Date) { _day = State(initialValue: initialDay) }

    var body: some View {
        DayAgenda(day: $day)
            .navigationTitle(Formatters.capitalizedFirst(Formatters.weekdayName(day)) + ", " + Formatters.dayMonthLong.string(from: day))
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Semana (faixa de dias)

struct WeekStrip: View {
    @EnvironmentObject var store: Store
    @Binding var day: Date

    var body: some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let holidays = HolidayCalendar(store.db.settings)
        VStack(spacing: 6) {
            HStack {
                Button { shift(-7) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Semana anterior")
                Spacer()
                Text(Formatters.capitalizedFirst(Formatters.monthYear.string(from: day))).font(.subheadline.weight(.semibold))
                Spacer()
                Button { shift(7) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Próxima semana")
            }
            .padding(.horizontal, 4)
            HStack(spacing: 4) {
                ForEach(days, id: \.self) { d in
                    let selected = cal.isDate(d, inSameDayAs: day)
                    let isToday = cal.isDateInToday(d)
                    let count = store.db.appointments(on: d).filter { !$0.isCancelled }.count
                    let off = !holidays.isBusinessDay(d)
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { day = d }
                    } label: {
                        VStack(spacing: 4) {
                            Text(Formatters.weekdayShort.string(from: d).prefix(3).uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(selected ? .white : .secondary)
                            Text("\(cal.component(.day, from: d))")
                                .font(.body.weight(isToday ? .bold : .regular))
                                .foregroundStyle(selected ? .white : (isToday ? Theme.plum : (off ? .secondary : .primary)))
                            Circle().fill(count > 0 ? (selected ? Color.white : Theme.plum) : .clear).frame(width: 5, height: 5)
                        }
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(selected ? Theme.plum : (off ? Color.secondary.opacity(0.10) : Color.clear),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Formatters.longDay.string(from: d)), \(count) atendimentos\(off ? ", sem atendimento" : "")")
                }
            }
        }
        .padding(.top, 6)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { shift(7) } else if v.translation.width > 40 { shift(-7) }
        })
    }

    private func shift(_ days: Int) {
        withAnimation { day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day }
    }
}

// MARK: - Horários do dia

struct DayTimeline: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    let day: Date
    @ObservedObject var actions: AppointmentActions
    var now = Date()

    var body: some View {
        let cal = Calendar.current
        let list = store.db.appointments(on: day)
        let nextID = cal.isDateInToday(day) ? TodayFocus.next(list, now: now)?.id : nil
        let s = store.db.settings
        let breaks = WorkBreaks.on(s, day: day)
        var hours = Set(s.workdayStartHour..<max(s.workdayEndHour, s.workdayStartHour + 1))
        for a in list { hours.insert(cal.component(.hour, from: a.start)) }
        let sorted = hours.sorted()
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(sorted, id: \.self) { hour in
                let slot = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
                let slotEnd = slot.addingTimeInterval(3600)
                let inHour = list.filter { cal.component(.hour, from: $0.start) == hour }
                let busy = list.contains { !$0.isCancelled && $0.start < slotEnd && $0.end > slot }
                // Intervalo que começa nesta hora (aparece uma vez) e hora inteira dentro de um intervalo.
                let breakStarting = breaks.first { $0.start >= slot && $0.start < slotEnd }
                let coveredByBreak = breaks.contains { $0.start <= slot && $0.end >= slotEnd }
                if inHour.isEmpty {
                    if !busy && !coveredByBreak && breakStarting.map({ $0.start > slot }) ?? true {
                        FreeSlotRow(hour: hour) { router.newAppointment(start: slot) }
                    }
                    if let b = breakStarting { BreakRow(slot: b) }
                } else {
                    if let b = breakStarting, b.start <= (inHour.first?.start ?? slot) { BreakRow(slot: b) }
                    ForEach(inHour) { a in AppointmentCard(appointment: a, actions: actions, now: now, isNext: a.id == nextID).id(a.id) }
                    if let b = breakStarting, b.start > (inHour.first?.start ?? slot) { BreakRow(slot: b) }
                }
            }
        }
    }
}

struct FreeSlotRow: View {
    let hour: Int
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Text(String(format: "%02d:00", hour)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Rectangle().fill(Color.secondary.opacity(0.18)).frame(height: 1)
                Image(systemName: "plus.circle").foregroundStyle(.tertiary)
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Agendar às \(hour) horas")
    }
}

/// Intervalo do expediente (ex.: almoço), listrado.
struct BreakRow: View {
    let slot: WorkBreaks.Slot
    var body: some View {
        HStack(spacing: 10) {
            Text(Formatters.time.string(from: slot.start)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Label("\(slot.workBreak.title) · \(slot.workBreak.timeRange)", systemImage: "fork.knife")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Stripes().opacity(0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Fundo listrado dos intervalos.
struct Stripes: View {
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                x += 8
            }
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Horário agendado: cliente (nome clicável), tag, local, pagamento e atalhos para anotações e WhatsApp.
struct AppointmentCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    let appointment: Appointment
    @ObservedObject var actions: AppointmentActions
    /// Hora do aparelho, passada pela agenda para o "Agora" e o "Próxima" acompanharem o relógio.
    var now = Date()
    var isNext = false

    var body: some View {
        let a = store.appointment(appointment.id) ?? appointment
        let tag = store.db.tag(a.tagID)
        let documented = Documentation.isDocumented(a, in: store.db)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.time.string(from: a.start)).font(.headline.monospacedDigit())
                    Text(Formatters.time.string(from: a.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    PatientNameLink(patientID: a.patientID)
                        .strikethrough(a.isCancelled)
                    HStack(spacing: 6) {
                        if let tag { Text(tag.name).font(.caption).foregroundStyle(.secondary) }
                        if a.seriesID != nil { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                        if a.attendance == .missed { StatusBadge(text: "Faltou", color: Theme.missed) }
                        if a.attendance == .attended { StatusBadge(text: "Realizado", color: Theme.attended) }
                        if a.isCancelled { StatusBadge(text: "Cancelado", color: Theme.cancelled) }
                        if a.start <= now && a.end > now && !a.isCancelled { StatusBadge(text: "Agora", color: Theme.plum) }
                        if isNext && !a.isCancelled { StatusBadge(text: "Próximo", color: Theme.attended) }
                    }
                    let place = store.db.location(of: a)
                    if !place.isEmpty {
                        PlaceLine(place: place)
                    }
                }
                Spacer(minLength: 4)
                PaymentOrNoCharge(appointment: a)
            }
            HStack(spacing: 6) {
                Button { router.open(.noteForAppointment(a.id)) } label: {
                    Label("Anotações", systemImage: documented ? "checkmark.circle.fill" : "square.and.pencil")
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if Billing.isBillable(a, in: store.db) && a.payment != .paid && a.start <= now && !a.isCancelled {
                    Button {
                        if let url = WhatsAppMessage.chargeLink(for: [a], in: store.db) {
                            UIApplication.shared.open(url)
                        } else {
                            actions.whatsAppBlocked = WhatsAppBlock(appointment: a, reason: WhatsAppMessage.blockReason(store.db.patient(a.patientID)) ?? "")
                        }
                    } label: {
                        Label("Cobrar", systemImage: "brazilianrealsign.circle")
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Cobrar pelo WhatsApp")
                }
                if WhatsAppMessage.showsButton(a, now: now) {
                    WhatsAppButton(appointment: a) { reason in actions.whatsAppBlocked = WhatsAppBlock(appointment: a, reason: reason) }
                }
                AppointmentMenu(appointment: a, actions: actions)
            }
            .tint(Theme.plum)
        }
        .padding(12)
        .opacity(a.isCancelled ? 0.7 : 1)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                .fill(tag.map { Color(hex: $0.colorHex).opacity(Theme.appointmentTint) } ?? Color.clear)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        )
        .contentShape(Rectangle())
        .onTapGesture { router.edit(a.id) }
        .contextMenu { AppointmentMenuItems(appointment: a, actions: actions) }
    }
}

/// Botão "…" do atendimento.
struct AppointmentMenu: View {
    let appointment: Appointment
    @ObservedObject var actions: AppointmentActions
    var body: some View {
        Menu {
            AppointmentMenuItems(appointment: appointment, actions: actions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Mais opções")
    }
}

struct AppointmentMenuItems: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    let appointment: Appointment
    @ObservedObject var actions: AppointmentActions

    var body: some View {
        let a = appointment
        Button { actions.rescheduleTarget = a } label: { Label("Remarcar", systemImage: "calendar.badge.clock") }
        Button { actions.returnTarget = a } label: { Label("Retorno", systemImage: "arrow.uturn.forward.circle") }
        Button { router.edit(a.id) } label: { Label("Editar", systemImage: "pencil") }
        Menu {
            ForEach(Attendance.allCases) { att in
                Button { store.setAttendance(a.id, att) } label: {
                    if a.attendance == att { Label(att.label, systemImage: "checkmark") } else { Text(att.label) }
                }
            }
        } label: { Label("Presença", systemImage: "person.fill.checkmark") }
        if Billing.isBillable(a, in: store.db) && a.payment != .paid {
            Button {
                if let url = WhatsAppMessage.chargeLink(for: [a], in: store.db) { UIApplication.shared.open(url) }
            } label: { Label("Cobrar pelo WhatsApp", systemImage: "brazilianrealsign.circle") }
            .disabled(WhatsAppMessage.chargeLink(for: [a], in: store.db) == nil)
        }
        if let pkg = Packages.available(for: a.patientID, in: store.db).first, a.packageID == nil {
            Button {
                var c = a
                c.packageID = pkg.id
                c.payment = nil
                c.paidAt = nil
                store.updateAppointment(c)
            } label: { Label("Usar o \(pkg.title.lowercasedFirst)", systemImage: "square.stack.3d.up") }
        }
        Divider()
        Button(role: .destructive) { actions.cancelTarget = a } label: { Label("Desmarcar", systemImage: "calendar.badge.minus") }
    }
}

// MARK: - Ações do atendimento (desmarcar, remarcar, retorno, aviso do WhatsApp)

struct WhatsAppBlock: Identifiable {
    let id = UUID()
    var appointment: Appointment
    var reason: String
}

@MainActor
final class AppointmentActions: ObservableObject {
    @Published var cancelTarget: Appointment?
    @Published var rescheduleTarget: Appointment?
    @Published var returnTarget: Appointment?
    @Published var whatsAppBlocked: WhatsAppBlock?
    @Published var editingPatient: Patient?
}

private struct AppointmentActionsModifier: ViewModifier {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @ObservedObject var actions: AppointmentActions
    var day: Binding<Date>?

    func body(content: Content) -> some View {
        content
            .sheet(item: $actions.rescheduleTarget) { a in
                RescheduleSheet(appointment: a) { newStart in
                    store.reschedule(a.id, to: newStart)
                    actions.rescheduleTarget = nil
                    day?.wrappedValue = newStart
                    toaster.show("Atendimento remarcado para \(Formatters.dateTime.string(from: newStart)).")
                }
                .environmentObject(store)
            }
            .sheet(item: $actions.returnTarget) { a in
                ReturnSheet(from: a) { created in
                    actions.returnTarget = nil
                    toaster.show("Retorno agendado para \(Formatters.dateTime.string(from: created.start)).")
                }
                .environmentObject(store)
            }
            .sheet(item: $actions.editingPatient) { p in
                PatientEditor(patient: p, isNew: false).environmentObject(store).environmentObject(toaster)
            }
            .confirmationDialog("Desmarcar este atendimento?", isPresented: Binding(
                get: { actions.cancelTarget != nil }, set: { if !$0 { actions.cancelTarget = nil } }),
                titleVisibility: .visible, presenting: actions.cancelTarget) { a in
                Button("Registrar como cancelado com aviso") {
                    store.cancelWithNotice(a.id)
                    toaster.show("Atendimento registrado como cancelado com aviso.")
                }
                Button("Apagar e liberar o horário", role: .destructive) {
                    store.cancel(a.id, scope: .single)
                    toaster.show("Horário liberado.")
                }
                if a.seriesID != nil {
                    Button("Apagar este e os próximos da série", role: .destructive) {
                        store.cancel(a.id, scope: .thisAndFollowing)
                        toaster.show("Horários liberados.")
                    }
                }
                Button("Manter agendamento", role: .cancel) {}
            } message: { a in
                Text("\(store.db.patient(a.patientID)?.name ?? Term.Client), \(Formatters.dateTime.string(from: a.start)).\n\nCancelado com aviso: continua no histórico do \(Term.client), sem contar como falta, e o horário fica livre. Apagar: o atendimento sai da agenda; as anotações já escritas continuam no cadastro do \(Term.client).")
            }
            .alert("Não dá para abrir o WhatsApp", isPresented: Binding(
                get: { actions.whatsAppBlocked != nil }, set: { if !$0 { actions.whatsAppBlocked = nil } }),
                presenting: actions.whatsAppBlocked) { block in
                Button("Editar o cadastro") {
                    if let p = store.db.patient(block.appointment.patientID) { actions.editingPatient = p }
                }
                Button("Fechar", role: .cancel) {}
            } message: { block in
                Text("\(block.reason) O botão usa o telefone do cadastro do \(Term.client), com o +55 e o DDD.")
            }
            .onAppear {
                guard let day = day?.wrappedValue else { return }
                let list = store.db.appointments(on: day)
                if DemoNavigator.consume("cancel"), let first = list.first { actions.cancelTarget = first }
                if DemoNavigator.consume("reschedule"), let first = list.first { actions.rescheduleTarget = first }
                if DemoNavigator.consume("return"), let first = list.first { actions.returnTarget = first }
                if DemoNavigator.consume("whatsapp-blocked"), let a = list.first(where: { store.db.patient($0.patientID)?.phone.isEmpty ?? false }) {
                    actions.whatsAppBlocked = WhatsAppBlock(appointment: a, reason: WhatsAppMessage.blockReason(store.db.patient(a.patientID)) ?? "")
                }
            }
    }
}

extension View {
    func appointmentActions(_ actions: AppointmentActions, day: Binding<Date>? = nil) -> some View {
        modifier(AppointmentActionsModifier(actions: actions, day: day))
    }
}

// MARK: - Remarcar

struct RescheduleSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let appointment: Appointment
    let onConfirm: (Date) -> Void
    @State private var newDay: Date
    @State private var newTime: Date
    @State private var confirmBreak = false

    init(appointment: Appointment, onConfirm: @escaping (Date) -> Void) {
        self.appointment = appointment
        self.onConfirm = onConfirm
        _newDay = State(initialValue: appointment.start)
        _newTime = State(initialValue: appointment.start)
    }

    var body: some View {
        let target = Calendar.current.combine(day: newDay, time: newTime)
        let conflicts = Conflicts.overlapping(start: target, durationMinutes: appointment.durationMinutes,
                                              in: store.db.appointments, excluding: appointment.id)
        let breakHit = WorkBreaks.hit(store.db.settings, start: target, minutes: appointment.durationMinutes)
        let holidays = HolidayCalendar(store.db.settings)
        NavigationStack {
            Form {
                Section {
                    LabeledContent(Term.Client, value: store.db.patient(appointment.patientID)?.name ?? "")
                    LabeledContent("Horário atual", value: Formatters.dateTime.string(from: appointment.start))
                }
                Section("Novo dia e horário") {
                    DatePicker("Dia", selection: $newDay, displayedComponents: .date)
                    DatePicker("Horário", selection: $newTime, displayedComponents: .hourAndMinute)
                }
                .environment(\.locale, Formatters.locale)
                if !conflicts.isEmpty {
                    Section {
                        Label("Já existe atendimento nesse horário: \(conflicts.compactMap { store.db.patient($0.patientID)?.firstName }.joined(separator: ", ")).",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                if let breakHit {
                    Section { Label(WorkBreaks.warning(breakHit), systemImage: "fork.knife").foregroundStyle(.orange) }
                }
                if !holidays.isBusinessDay(target) {
                    Section {
                        Label("Esse dia é \(BusinessDayRule.reason(for: target, holidays: holidays)).", systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Text("Anotações, pagamento, local e tag vão junto para o novo horário, e o horário atual fica livre.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Remarcar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remarcar") {
                        if breakHit != nil { confirmBreak = true } else { onConfirm(target) }
                    }
                    .disabled(target == appointment.start)
                }
            }
            .alert("Horário no intervalo", isPresented: $confirmBreak) {
                Button("Marcar mesmo assim") { onConfirm(target) }
                Button("Escolher outro horário", role: .cancel) {}
            } message: { Text(breakHit.map(WorkBreaks.warning) ?? "") }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Retorno

/// Retorno com qualquer intervalo. Se a data cair em folga, a regra de dias úteis propõe outra e o profissional aprova.
struct ReturnSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let from: Appointment
    let onDone: (Appointment) -> Void
    @State private var value = 30
    @State private var unit: ReturnUnit = .days
    @State private var duration = 60
    @State private var customDay = Date()
    @State private var customTime = Date()
    @State private var choosingOther = false
    @State private var loaded = false

    var body: some View {
        let interval = ReturnInterval(value: value, unit: unit)
        let plan = ReturnPlanner.plan(from: from, interval: interval, durationMinutes: duration, db: store.db, now: Date())
        NavigationStack {
            Form {
                Section {
                    LabeledContent(Term.Client, value: store.db.patient(from.patientID)?.name ?? "")
                    LabeledContent("Atendimento de origem", value: Formatters.dateTime.string(from: from.start))
                }
                Section("Retorno daqui a") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ReturnInterval.shortcuts, id: \.self) { s in
                                Button { value = s.value; unit = s.unit } label: {
                                    Text(s.label).font(.subheadline)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(interval == s ? Theme.plum.opacity(0.25) : Color(uiColor: .tertiarySystemFill)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Stepper(value: $value, in: 1...ReturnInterval.maxValue) {
                        HStack {
                            Text("\(value)").monospacedDigit().font(.headline)
                            Picker("Unidade", selection: $unit) {
                                ForEach(ReturnUnit.allCases) { Text($0.label(value)).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }
                    DurationPicker("Duração", minutes: $duration)
                }
                Section {
                    if plan.moved {
                        Label("A data cai em \(plan.reason) (\(Formatters.shortDate.string(from: plan.original))).", systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(.orange)
                        Text(plan.explanation).font(.subheadline)
                    }
                    if plan.kind != .noSlot && !choosingOther {
                        LabeledContent(plan.moved ? "Proposta" : "Data", value: Formatters.capitalizedFirst(Formatters.weekdayName(plan.proposed)) + ", " + Formatters.dateTime.string(from: plan.proposed))
                    }
                    if plan.kind == .noSlot || choosingOther {
                        DatePicker("Dia", selection: $customDay, displayedComponents: .date)
                        DatePicker("Horário", selection: $customTime, displayedComponents: .hourAndMinute)
                    } else if plan.moved {
                        Button("Escolher outro dia e horário") {
                            customDay = plan.original
                            customTime = plan.original
                            choosingOther = true
                        }
                    }
                } header: {
                    Text("Quando")
                } footer: {
                    Text("O atendimento entra com a tag \(store.db.returnTag()?.name ?? "Retorno")\((store.db.returnTag()?.defaultPriceCents ?? 0) == 0 ? ", sem custo" : ""). Nada é agendado sem a sua confirmação.")
                }
                .environment(\.locale, Formatters.locale)
            }
            .navigationTitle("Retorno")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Agendar") {
                        let start = plan.kind == .noSlot || choosingOther ? Calendar.current.combine(day: customDay, time: customTime) : plan.proposed
                        store.update { db in
                            db.settings.returnIntervalValue = value
                            db.settings.returnIntervalUnit = unit
                        }
                        let created = store.scheduleReturn(from: from, start: start, durationMinutes: duration)
                        onDone(created)
                    }
                    .disabled(!interval.isValid)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                value = store.db.settings.returnIntervalValue
                unit = store.db.settings.returnIntervalUnit
                duration = store.db.duration(for: store.db.returnTag()?.id)
            }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Atendimentos do cliente

/// Todos os atendimentos do cliente, do mais recente para o mais antigo, com selo de presença, falta ou cancelado.
struct PatientSessionsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    let patientID: UUID
    @State private var period: HistoryPeriod = .all

    var body: some View {
        let now = Date()
        let list = SessionHistory.list(store.db, patientID: patientID, period: period, now: now)
        let counts = SessionHistory.count(list, now: now)
        let groups = Dictionary(grouping: list) { Calendar.current.dateInterval(of: .month, for: $0.start)?.start ?? $0.start }
        let months = groups.keys.sorted(by: >)
        let asBlocks = store.db.settings.sessionsAsBlocks
        List {
            Section {
                Picker("Período", selection: $period) {
                    ForEach(HistoryPeriod.allCases) { Text($0.label).tag($0) }
                }
                HStack(spacing: 8) {
                    SessionBadgeView(badge: .presence)
                    Text("\(counts.presence)").monospacedDigit()
                    SessionBadgeView(badge: .absence)
                    Text("\(counts.absence)").monospacedDigit()
                    SessionBadgeView(badge: .cancelled)
                    Text("\(counts.cancelled)").monospacedDigit()
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                Picker("Exibir", selection: Binding(get: { asBlocks }, set: { v in store.update { $0.settings.sessionsAsBlocks = v } })) {
                    Text("Lista").tag(false)
                    Text("Blocos").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if list.isEmpty {
                EmptyStateView(symbol: "calendar", title: "Nenhum atendimento", message: "Os atendimentos deste \(Term.client) no período aparecem aqui.")
                    .listRowBackground(Color.clear)
            }
            ForEach(months, id: \.self) { m in
                Section(Formatters.capitalizedFirst(Formatters.monthYear.string(from: m))) {
                    if asBlocks {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            ForEach(groups[m] ?? []) { a in
                                Button { router.edit(a.id) } label: { SessionBlock(appointment: a, now: now) }.buttonStyle(.plain)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    } else {
                        ForEach(groups[m] ?? []) { a in
                            Button { router.edit(a.id) } label: { HistoryRow(appointment: a, now: now) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle(store.db.patient(patientID)?.name ?? "Atendimentos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.newAppointment(patientID: patientID) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Agendar atendimento")
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var store: Store
    let appointment: Appointment
    let now: Date

    var body: some View {
        let a = appointment
        let badge = SessionHistory.badge(a, now: now)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Formatters.capitalizedFirst(Formatters.weekdayName(a.start)) + ", " + Formatters.dateTime.string(from: a.start))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    SessionBadgeView(badge: badge)
                    if let t = store.db.tag(a.tagID) { Text(t.name).font(.caption).foregroundStyle(.secondary) }
                    if a.end <= now && Documentation.needsNote(a) && !Documentation.isDocumented(a, in: store.db) {
                        StatusBadge(text: "Sem anotação", color: .orange)
                    }
                }
            }
            Spacer()
            if Billing.isNoCharge(a, in: store.db) {
                Text(a.packageID != nil ? "Pacote" : "Sem custo").font(.caption).foregroundStyle(.secondary)
            } else { PaymentSeal(status: a.payment) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// O mesmo atendimento, em bloco (exibição em blocos).
struct SessionBlock: View {
    @EnvironmentObject var store: Store
    let appointment: Appointment
    let now: Date
    var body: some View {
        let a = appointment
        let tag = store.db.tag(a.tagID)
        VStack(alignment: .leading, spacing: 6) {
            Text(Formatters.capitalizedFirst(Formatters.weekdayShort.string(from: a.start)) + " " + Formatters.dayMonth.string(from: a.start))
                .font(.subheadline.weight(.semibold))
            Text(Formatters.time.string(from: a.start) + "–" + Formatters.time.string(from: a.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            SessionBadgeView(badge: SessionHistory.badge(a, now: now))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(tag.map { Color(hex: $0.colorHex).opacity(0.2) } ?? Color(uiColor: .tertiarySystemFill)))
    }
}

// MARK: - Escolher cliente

struct PatientPickerSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (Patient) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let all = store.activePatients
            let list = query.isEmpty ? all : NameMatcher.suggestions(for: query, in: all, limit: 50)
            List(list) { p in
                Button { onPick(p) } label: {
                    Text(p.name).foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar \(Term.client)")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
    }
}

/// Local do atendimento no cartão da agenda. Link (https) abre no navegador; endereço abre no Mapas.
struct PlaceLine: View {
    let place: String

    var body: some View {
        let url = Places.url(for: place)
        Group {
            if let url {
                Link(destination: url) { label }
            } else {
                label
            }
        }
        .font(.caption)
    }

    private var label: some View {
        Label(place, systemImage: Places.isLink(place) ? "video" : (Places.isOnline(place) ? "laptopcomputer" : "mappin.and.ellipse"))
            .lineLimit(1)
            .foregroundStyle(.secondary)
    }
}
