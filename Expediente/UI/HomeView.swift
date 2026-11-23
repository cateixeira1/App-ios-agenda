import SwiftUI

/// Tela inicial: a agenda em tela cheia (dia, semana ou mês). O ícone de menu (☰), no canto superior direito,
/// abre os blocos de funções.
struct HomeView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @State private var day = Date()
    @State private var showCalendar = false

    private var mode: AgendaMode { store.db.settings.agendaMode }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Exibição", selection: Binding(get: { mode }, set: { m in store.update { $0.settings.agendaMode = m } })) {
                ForEach(AgendaMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
            .background(Theme.background)

            switch mode {
            case .day:
                DayAgenda(day: $day)
            case .week:
                WeekGrid(day: $day)
            case .month:
                MonthGrid(day: $day) { picked in
                    day = picked
                    store.update { $0.settings.agendaMode = .day }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Hoje") { withAnimation { day = Date() } }
                    .disabled(isShowingToday)
            }
            ToolbarItem(placement: .principal) {
                Button { showCalendar = true } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.headline).foregroundStyle(.primary)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Escolher data: \(title)")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { router.newAppointment(start: defaultStart()) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Agendar")
                Button { router.showsMenu = true } label: { Image(systemName: "line.3.horizontal") }
                    .accessibilityLabel("Menu de funções")
            }
        }
        .sheet(isPresented: $showCalendar) {
            NavigationStack {
                DatePicker("Data", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .environment(\.locale, Formatters.locale)
                    .padding()
                    .navigationTitle("Escolher data")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("OK") { showCalendar = false } }
                        ToolbarItem(placement: .cancellationAction) { Button("Hoje") { day = Date(); showCalendar = false } }
                    }
                Spacer()
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            if DemoNavigator.consume("menu") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { router.showsMenu = true } }
        }
    }

    private var isShowingToday: Bool {
        let cal = Calendar.current
        switch mode {
        case .day: return cal.isDateInToday(day)
        case .week: return cal.isDate(day, equalTo: Date(), toGranularity: .weekOfYear)
        case .month: return cal.isDate(day, equalTo: Date(), toGranularity: .month)
        }
    }

    private var title: String {
        switch mode {
        case .day:
            if Calendar.current.isDateInToday(day) { return "Hoje, " + Formatters.dayMonthLong.string(from: day) }
            return Formatters.capitalizedFirst(Formatters.weekdayName(day)) + ", " + Formatters.dayMonthLong.string(from: day)
        case .week:
            let cal = Calendar.current
            let start = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? day
            let end = cal.date(byAdding: .day, value: 6, to: start) ?? day
            return "\(Formatters.dayMonth.string(from: start)) a \(Formatters.dayMonth.string(from: end))"
        case .month:
            return Formatters.capitalizedFirst(Formatters.monthYear.string(from: day))
        }
    }

    private func defaultStart() -> Date {
        let cal = Calendar.current
        let hour = cal.isDateInToday(day) ? min(cal.component(.hour, from: Date()) + 1, 22) : store.db.settings.workdayStartHour + 1
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }
}

// MARK: - Blocos de funções

/// Os blocos de funções, todos do mesmo tamanho, em duas colunas.
struct FunctionMenu: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var pickingPatient = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let now = Date()
        let pending = Documentation.pending(in: store.db, now: now, days: 7)
        let open = Finance.open(store.db, now: now)
        let activePackages = store.db.packages.filter { Packages.isAvailable($0, in: store.db, now: now) }.count
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Greeting(firstName: store.db.professional.firstName)
                    LazyVGrid(columns: columns, spacing: 12) {
                        MenuTile(title: "Agendar", symbol: "plus", color: Theme.paid) { router.newAppointment() }
                        MenuTile(title: Term.Clients, symbol: "person.2.fill", color: .orange,
                                 count: "\(store.activePatients.count)") { router.open(.patients) }
                        MenuTile(title: "Anotações", symbol: "square.and.pencil", color: .indigo,
                                 count: pending.isEmpty ? nil : "\(pending.count)") { router.open(.notes) }
                        MenuTile(title: "Financeiro", symbol: "brazilianrealsign", color: .teal,
                                 count: open.isEmpty ? nil : "\(open.count)") { router.open(.finance) }
                        MenuTile(title: "Pacotes", symbol: "square.stack.3d.up.fill", color: .mint,
                                 count: activePackages == 0 ? nil : "\(activePackages)") { router.open(.packages) }
                        MenuTile(title: "Despesas", symbol: "cart.fill", color: .red) { router.open(.expenses) }
                        MenuTile(title: "Atendimentos do \(Term.client)", symbol: "list.bullet.rectangle.portrait.fill", color: .pink) { pickingPatient = true }
                        MenuTile(title: "Relatórios", symbol: "chart.bar.doc.horizontal.fill", color: .purple) { router.open(.reports) }
                        MenuTile(title: "Notas fiscais", symbol: "doc.text.fill", color: .brown) { router.open(.invoices) }
                        MenuTile(title: "Ajustes", symbol: "gearshape.fill", color: .gray) { router.open(.settings) }
                    }
                    Button {
                        router.showsMenu = false
                        app.lock()
                    } label: {
                        Label("Bloquear o app", systemImage: "lock").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.plum)
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Funções")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { router.showsMenu = false } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fechar o menu")
                }
            }
            .sheet(isPresented: $pickingPatient) {
                PatientPickerSheet(title: "Atendimentos do \(Term.client)") { p in
                    pickingPatient = false
                    router.open(.patientSessions(p.id))
                }
                .environmentObject(store)
            }
        }
    }
}

// MARK: - Dia

/// Agenda de um dia: semana em cima e os horários do dia, com o botão do WhatsApp nos atendimentos de hoje em diante.
struct DayAgenda: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @Environment(\.scenePhase) private var scenePhase
    @Binding var day: Date
    @StateObject private var actions = AppointmentActions()
    /// Relógio do aparelho, atualizado a cada 30 segundos: a agenda de hoje rola sozinha conforme o dia avança.
    @State private var now = Date()
    @State private var lastFocus: UUID?
    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            WeekStrip(day: $day)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .background(Theme.background)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        DayNotice(day: day)
                        DayTimeline(day: day, actions: actions, now: now)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .background(Theme.background)
                .gesture(DragGesture(minimumDistance: 40).onEnded { v in
                    guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
                    let step = v.translation.width < 0 ? 1 : -1
                    withAnimation { day = Calendar.current.date(byAdding: .day, value: step, to: day) ?? day }
                })
                .onAppear { followClock(proxy, force: true) }
                .onReceive(tick) { _ in
                    now = Date()
                    followClock(proxy, force: false)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    now = Date()
                    followClock(proxy, force: true)
                }
                .onChange(of: day) { _, _ in
                    lastFocus = nil
                    followClock(proxy, force: true)
                }
            }
        }
        .appointmentActions(actions, day: $day)
    }

    /// Só no dia de hoje: leva o atendimento em andamento (ou o próximo) para o alto da tela. Depois disso, só rola de novo
    /// quando o atendimento em foco muda, para não puxar a tela de volta enquanto você olha outro horário.
    private func followClock(_ proxy: ScrollViewProxy, force: Bool) {
        let cal = Calendar.current
        guard cal.isDateInToday(day), let target = TodayFocus.focus(store.db.appointments(on: day), now: now)?.id else { return }
        guard force || target != lastFocus else { return }
        lastFocus = target
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .top) }
        }
    }
}

/// Aviso de feriado ou de dia sem atendimento.
struct DayNotice: View {
    @EnvironmentObject var store: Store
    let day: Date

    var body: some View {
        let cal = HolidayCalendar(store.db.settings)
        if let h = cal.name(of: day) {
            Label("Feriado: \(h)", systemImage: "flag").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        } else if !cal.isWorkDay(day) {
            Label("Dia sem atendimento", systemImage: "moon.zzz").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
