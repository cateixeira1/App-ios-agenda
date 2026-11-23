import SwiftUI

// MARK: - Semana em grade

/// Semana em grade: os sete dias lado a lado, com as sessões pintadas na cor da tag, o intervalo listrado,
/// os dias sem atendimento sombreados e a linha vermelha da hora atual.
struct WeekGrid: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @Binding var day: Date

    private let hourHeight: CGFloat = 56
    private let labelWidth: CGFloat = 38

    var body: some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: day)?.start ?? cal.startOfDay(for: day)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        let s = store.db.settings
        let firstHour = max(0, min(s.workdayStartHour, earliestHour(days) ?? s.workdayStartHour))
        let lastHour = min(24, max(s.workdayEndHour, latestHour(days) ?? s.workdayEndHour))
        let holidays = HolidayCalendar(s)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button { shift(-7) } label: { Image(systemName: "chevron.left").frame(width: labelWidth, height: 44) }
                    .accessibilityLabel("Semana anterior")
                ForEach(days, id: \.self) { d in
                    let today = cal.isDateInToday(d)
                    VStack(spacing: 2) {
                        Text(Formatters.weekdayShort.string(from: d).prefix(3).uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(cal.component(.day, from: d))")
                            .font(.subheadline.weight(today ? .bold : .regular))
                            .foregroundStyle(today ? .white : (holidays.isBusinessDay(d) ? .primary : .secondary))
                            .frame(width: 26, height: 26)
                            .background(today ? Theme.plum : .clear, in: Circle())
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        day = d
                        store.update { $0.settings.agendaMode = .day }
                    }
                }
                Button { shift(7) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 44) }
                    .accessibilityLabel("Próxima semana")
            }
            .padding(.bottom, 4)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(firstHour..<lastHour, id: \.self) { h in
                                Text(String(format: "%02d", h))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelWidth, height: hourHeight, alignment: .topTrailing)
                                    .padding(.trailing, 4)
                                    .id(h)
                            }
                        }
                        GeometryReader { geo in
                            let colWidth = geo.size.width / 7
                            ZStack(alignment: .topLeading) {
                                // Linhas das horas.
                                ForEach(firstHour..<lastHour, id: \.self) { h in
                                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                                        .offset(y: CGFloat(h - firstHour) * hourHeight)
                                }
                                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                                    let x = CGFloat(i) * colWidth
                                    // Dia sem atendimento ou feriado.
                                    if !holidays.isBusinessDay(d) {
                                        Rectangle().fill(Color.secondary.opacity(0.08))
                                            .frame(width: colWidth, height: CGFloat(lastHour - firstHour) * hourHeight)
                                            .offset(x: x)
                                    }
                                    // Toque no espaço vazio agenda naquele horário.
                                    Color.clear
                                        .frame(width: colWidth, height: CGFloat(lastHour - firstHour) * hourHeight)
                                        .contentShape(Rectangle())
                                        .offset(x: x)
                                        .onTapGesture(coordinateSpace: .local) { p in
                                            let minutes = Int(p.y / hourHeight * 60) / 30 * 30
                                            let base = cal.date(bySettingHour: firstHour, minute: 0, second: 0, of: d) ?? d
                                            router.newAppointment(start: base.addingTimeInterval(TimeInterval(minutes * 60)))
                                        }
                                    ForEach(WorkBreaks.on(s, day: d), id: \.start) { b in
                                        Stripes()
                                            .frame(width: colWidth - 2, height: height(b.start, b.end))
                                            .offset(x: x + 1, y: y(b.start, firstHour: firstHour))
                                            .allowsHitTesting(false)
                                    }
                                    ForEach(store.db.appointments(on: d)) { a in
                                        WeekBlock(appointment: a, width: colWidth - 2, height: max(18, height(a.start, a.end)))
                                            .offset(x: x + 1, y: y(a.start, firstHour: firstHour))
                                            .onTapGesture { router.edit(a.id) }
                                    }
                                    if cal.isDateInToday(d) {
                                        Rectangle().fill(Theme.unpaid).frame(width: colWidth, height: 2)
                                            .offset(x: x, y: y(Date(), firstHour: firstHour))
                                            .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                        .frame(height: CGFloat(lastHour - firstHour) * hourHeight)
                        .padding(.trailing, 8)
                    }
                    .padding(.top, 6)
                }
                .onAppear {
                    let now = cal.component(.hour, from: Date())
                    proxy.scrollTo(min(max(now - 1, firstHour), lastHour - 1), anchor: .top)
                }
            }
        }
        .gesture(DragGesture(minimumDistance: 40).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            shift(v.translation.width < 0 ? 7 : -7)
        })
    }

    private func y(_ date: Date, firstHour: Int) -> CGFloat {
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: date)
        return CGFloat((c.hour ?? 0) - firstHour) * hourHeight + CGFloat(c.minute ?? 0) / 60 * hourHeight
    }

    private func height(_ start: Date, _ end: Date) -> CGFloat { CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight }

    private func earliestHour(_ days: [Date]) -> Int? {
        days.flatMap { store.db.appointments(on: $0) }.map { Calendar.current.component(.hour, from: $0.start) }.min()
    }

    private func latestHour(_ days: [Date]) -> Int? {
        days.flatMap { store.db.appointments(on: $0) }.map { a -> Int in
            let c = Calendar.current.dateComponents([.hour, .minute], from: a.end)
            return (c.hour ?? 0) + ((c.minute ?? 0) > 0 ? 1 : 0)
        }.max()
    }

    private func shift(_ days: Int) {
        withAnimation { day = Calendar.current.date(byAdding: .day, value: days, to: day) ?? day }
    }
}

/// Sessão na grade da semana.
struct WeekBlock: View {
    @EnvironmentObject var store: Store
    let appointment: Appointment
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let a = appointment
        let color = store.db.tag(a.tagID).map { Color(hex: $0.colorHex) } ?? Color.gray
        VStack(alignment: .leading, spacing: 0) {
            Text(Formatters.time.string(from: a.start)).font(.system(size: 9, weight: .semibold).monospacedDigit())
            if height > 30 {
                Text(store.db.patient(a.patientID)?.firstName ?? "").font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(a.isCancelled ? 0.18 : 0.55)))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
        .overlay {
            if a.isCancelled { RoundedRectangle(cornerRadius: 4).stroke(Theme.cancelled, style: StrokeStyle(lineWidth: 1, dash: [3])) }
        }
        .clipped()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(store.db.patient(a.patientID)?.name ?? Term.Client), \(Formatters.time.string(from: a.start))\(a.isCancelled ? ", cancelado" : "")")
    }
}

// MARK: - Mês

/// Mês: cada sessão aparece como uma faixa na cor da tag ("+N" quando não cabem todas). Tocar no dia abre o dia.
struct MonthGrid: View {
    @EnvironmentObject var store: Store
    @Binding var day: Date
    let onPick: (Date) -> Void

    var body: some View {
        let cal = Calendar.current
        let month = cal.monthInterval(containing: day)
        let firstWeekday = cal.component(.weekday, from: month.start) // 1 = domingo
        let gridStart = cal.date(byAdding: .day, value: -(firstWeekday - 1), to: month.start)!
        let cells = (0..<42).compactMap { cal.date(byAdding: .day, value: $0, to: gridStart) }
        let holidays = HolidayCalendar(store.db.settings)
        VStack(spacing: 4) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 32) }.accessibilityLabel("Mês anterior")
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 32) }.accessibilityLabel("Próximo mês")
            }
            HStack(spacing: 2) {
                ForEach(["D", "S", "T", "Q", "Q", "S", "S"].indices, id: \.self) { i in
                    Text(["D", "S", "T", "Q", "Q", "S", "S"][i]).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            GeometryReader { geo in
                let rowHeight = geo.size.height / 6
                VStack(spacing: 2) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { col in
                                let d = cells[row * 7 + col]
                                MonthCell(date: d, inMonth: cal.isDate(d, equalTo: day, toGranularity: .month),
                                          offDay: !holidays.isBusinessDay(d), holiday: holidays.name(of: d), height: rowHeight - 2)
                                    .onTapGesture { onPick(d) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .gesture(DragGesture(minimumDistance: 40).onEnded { v in
            guard abs(v.translation.width) > abs(v.translation.height) * 1.5 else { return }
            shift(v.translation.width < 0 ? 1 : -1)
        })
    }

    private func shift(_ n: Int) {
        withAnimation { day = Calendar.current.date(byAdding: .month, value: n, to: day) ?? day }
    }
}

struct MonthCell: View {
    @EnvironmentObject var store: Store
    let date: Date
    let inMonth: Bool
    let offDay: Bool
    let holiday: String?
    let height: CGFloat

    var body: some View {
        let cal = Calendar.current
        let list = store.db.appointments(on: date)
        let maxBars = max(0, Int((height - 20) / 14))
        let today = cal.isDateInToday(date)
        VStack(alignment: .leading, spacing: 2) {
            Text("\(cal.component(.day, from: date))")
                .font(.caption.weight(today ? .bold : .regular))
                .foregroundStyle(today ? .white : (inMonth ? (offDay ? .secondary : .primary) : .secondary.opacity(0.5)))
                .frame(width: 20, height: 18)
                .background(today ? Theme.plum : .clear, in: Circle())
            ForEach(list.prefix(list.count > maxBars ? max(maxBars - 1, 0) : maxBars)) { a in
                let color = store.db.tag(a.tagID).map { Color(hex: $0.colorHex) } ?? .gray
                Text(store.db.patient(a.patientID)?.firstName ?? "")
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .strikethrough(a.isCancelled)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, minHeight: 12, alignment: .leading)
                    .background(color.opacity(a.isCancelled ? 0.25 : 0.75), in: RoundedRectangle(cornerRadius: 3))
            }
            if list.count > maxBars && maxBars > 0 {
                Text("+\(list.count - max(maxBars - 1, 0))").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(2)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(offDay && inMonth ? Color.secondary.opacity(0.10) : Theme.card))
        .opacity(inMonth ? 1 : 0.55)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Formatters.longDay.string(from: date)), \(list.count) atendimentos\(holiday.map { ", feriado: \($0)" } ?? "")")
    }
}
