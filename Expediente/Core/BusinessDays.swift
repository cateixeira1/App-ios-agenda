import Foundation

// Calendário real do consultório: feriados, dias de atendimento, intervalos (almoço), retornos e a regra
// para datas que caem em folga. Mesmas regras da versão para Windows.

struct Holiday: Equatable, Hashable {
    var date: Date
    var name: String
    var optional: Bool
}

/// Feriados nacionais e pontos facultativos, calculados para qualquer ano.
/// Lista conferida com a Portaria MGI nº 11.460, de 29 de dezembro de 2025 (feriados de 2026).
enum Holidays {
    private static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    static func day(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
    }

    /// Domingo de Páscoa (algoritmo de Meeus/Jones/Butcher).
    static func easter(_ year: Int, calendar: Calendar = .current) -> Date {
        let a = year % 19, b = year / 100, c = year % 100, d = b / 4, e = b % 4
        let f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let dd = (h + l - 7 * m + 114) % 31 + 1
        return day(year, month, dd, calendar: calendar)
    }

    static func national(_ year: Int, calendar: Calendar = .current) -> [Holiday] {
        let e = easter(year, calendar: calendar)
        func plus(_ n: Int) -> Date { calendar.date(byAdding: .day, value: n, to: e)! }
        var list = [
            Holiday(date: day(year, 1, 1, calendar: calendar), name: "Confraternização Universal", optional: false),
            Holiday(date: plus(-2), name: "Paixão de Cristo", optional: false),
            Holiday(date: day(year, 4, 21, calendar: calendar), name: "Tiradentes", optional: false),
            Holiday(date: day(year, 5, 1, calendar: calendar), name: "Dia do Trabalho", optional: false),
            Holiday(date: day(year, 9, 7, calendar: calendar), name: "Independência do Brasil", optional: false),
            Holiday(date: day(year, 10, 12, calendar: calendar), name: "Nossa Senhora Aparecida", optional: false),
            Holiday(date: day(year, 11, 2, calendar: calendar), name: "Finados", optional: false),
            Holiday(date: day(year, 11, 15, calendar: calendar), name: "Proclamação da República", optional: false),
            Holiday(date: day(year, 12, 25, calendar: calendar), name: "Natal", optional: false),
            Holiday(date: plus(-48), name: "Carnaval", optional: true),
            Holiday(date: plus(-47), name: "Carnaval", optional: true),
            Holiday(date: plus(60), name: "Corpus Christi", optional: true),
        ]
        // Lei 14.759/2023: feriado nacional a partir de 2024.
        if year >= 2024 {
            list.append(Holiday(date: day(year, 11, 20, calendar: calendar), name: "Dia Nacional de Zumbi e da Consciência Negra", optional: false))
        }
        return list.sorted { $0.date < $1.date }
    }

    /// Feriados que valem para o profissional nesse ano.
    static func list(_ year: Int, settings s: AppSettings, calendar: Calendar = .current) -> [Holiday] {
        var list = national(year, calendar: calendar).filter { !$0.optional || s.optionalHolidaysOff }
        for c in s.customHolidays {
            let comps = calendar.dateComponents([.year, .month, .day], from: c.date)
            if c.yearly {
                guard let m = comps.month, let d = comps.day else { continue }
                let first = day(year, m, 1, calendar: calendar)
                let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 28
                list.append(Holiday(date: day(year, m, min(d, days), calendar: calendar), name: c.name, optional: false))
            } else if comps.year == year {
                list.append(Holiday(date: calendar.startOfDay(for: c.date), name: c.name, optional: false))
            }
        }
        return list.sorted { $0.date < $1.date }
    }
}

/// Consulta rápida de feriados e dias úteis.
final class HolidayCalendar {
    let settings: AppSettings
    let calendar: Calendar
    private var years: [Int: [Date: String]] = [:]

    init(_ settings: AppSettings, calendar: Calendar = .current) {
        self.settings = settings
        self.calendar = calendar
    }

    func name(of day: Date) -> String? {
        let d = calendar.startOfDay(for: day)
        let year = calendar.component(.year, from: d)
        if years[year] == nil {
            var map: [Date: String] = [:]
            for h in Holidays.list(year, settings: settings, calendar: calendar) {
                if let other = map[h.date], other != h.name { map[h.date] = other + " · " + h.name } else { map[h.date] = h.name }
            }
            years[year] = map
        }
        return years[year]?[d]
    }

    func isHoliday(_ day: Date) -> Bool { name(of: day) != nil }

    func isWorkDay(_ day: Date) -> Bool { settings.isWorkDay(weekday: calendar.component(.weekday, from: day)) }

    /// Dia útil: dia de atendimento e sem feriado.
    func isBusinessDay(_ day: Date) -> Bool { isWorkDay(day) && !isHoliday(day) }

    func addDays(_ n: Int, _ d: Date) -> Date { calendar.date(byAdding: .day, value: n, to: d) ?? d }
}

// MARK: - Intervalos do expediente

enum WorkBreaks {
    struct Slot: Equatable {
        var workBreak: WorkBreak
        var start: Date
        var end: Date
        /// "“Almoço” (12:00–13:00)".
        var describe: String { "“\(workBreak.title)” (\(workBreak.timeRange))" }
    }

    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    static func on(_ s: AppSettings, day: Date, calendar: Calendar = .current) -> [Slot] {
        let base = calendar.startOfDay(for: day)
        let weekday = calendar.component(.weekday, from: base)
        return s.breaks.filter { $0.isValid && $0.applies(weekday: weekday) }
            .map { b in
                Slot(workBreak: b, start: calendar.date(byAdding: .minute, value: b.startMinutes, to: base)!,
                     end: calendar.date(byAdding: .minute, value: b.endMinutes, to: base)!)
            }
            .sorted { $0.start < $1.start }
    }

    /// O primeiro intervalo que se sobrepõe à sessão [início, início + duração), ou nil.
    static func hit(_ s: AppSettings, start: Date, minutes: Int, calendar: Calendar = .current) -> Slot? {
        guard !s.breaks.isEmpty, minutes > 0 else { return nil }
        let end = start.addingTimeInterval(TimeInterval(minutes * 60))
        var d = calendar.startOfDay(for: start)
        while d < end {
            for slot in on(s, day: d, calendar: calendar) where slot.start < end && slot.end > start { return slot }
            d = calendar.date(byAdding: .day, value: 1, to: d)!
        }
        return nil
    }

    static let weekdayShortNames = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"]

    /// "todos os dias", "segunda a sexta" ou "seg, qua e sex".
    static func daysLabel(_ b: WorkBreak) -> String {
        let days = Array(Set(b.days.filter { (0...6).contains($0) }))
        if days.isEmpty || days.count == 7 { return "todos os dias" }
        if days.count == 5 && days.allSatisfy({ (1...5).contains($0) }) { return "segunda a sexta" }
        return Formatters.list([1, 2, 3, 4, 5, 6, 0].filter(days.contains).map { weekdayShortNames[$0] })
    }

    static func warning(_ slot: Slot) -> String {
        "Esse horário cai no intervalo \(slot.describe), reservado em Ajustes › Agenda para não marcar atendimentos."
    }
}

// MARK: - Retornos

enum ReturnUnit: String, Codable, CaseIterable, Identifiable, Hashable {
    case days, weeks, months
    var id: String { rawValue }
    func label(_ value: Int) -> String {
        switch self {
        case .days: return value == 1 ? "dia" : "dias"
        case .weeks: return value == 1 ? "semana" : "semanas"
        case .months: return value == 1 ? "mês" : "meses"
        }
    }
}

struct ReturnInterval: Equatable, Hashable {
    static let maxValue = 999
    var value: Int
    var unit: ReturnUnit

    func apply(_ start: Date, calendar: Calendar = .current) -> Date {
        switch unit {
        case .days: return calendar.date(byAdding: .day, value: value, to: start) ?? start
        case .weeks: return calendar.date(byAdding: .day, value: 7 * value, to: start) ?? start
        case .months: return calendar.date(byAdding: .month, value: value, to: start) ?? start
        }
    }

    var isValid: Bool { value > 0 && value <= ReturnInterval.maxValue }
    /// "15 dias", "2 semanas", "1 mês".
    var label: String { "\(value) \(unit.label(value))" }

    static let shortcuts: [ReturnInterval] = [
        .init(value: 7, unit: .days), .init(value: 15, unit: .days), .init(value: 30, unit: .days), .init(value: 45, unit: .days),
        .init(value: 2, unit: .months), .init(value: 3, unit: .months), .init(value: 6, unit: .months),
    ]
}

enum DayAdjustKind: Equatable {
    /// Dia útil: fica como está.
    case none
    /// Voltou para um dia útil anterior (até 3 dias úteis antes da folga), no mesmo horário.
    case sameTimeEarlier
    /// Nenhum dos 3 dias úteis anteriores tinha o mesmo horário livre: vai para o dia útil logo antes da folga, em outro horário.
    case otherTimeLastBusinessDay
    /// Não há horário livre no dia útil logo antes da folga: o profissional escolhe.
    case noSlot
}

/// Proposta para uma sessão que cairia num dia sem atendimento. Sempre precisa da aprovação do profissional.
struct DayAdjustment: Equatable {
    var original: Date
    var proposed: Date
    var kind: DayAdjustKind
    var reason = ""
    var offStart: Date
    var offEnd: Date
    var businessDaysBefore = 0

    var moved: Bool { kind != .none }

    var explanation: String {
        let t = Formatters.time
        switch kind {
        case .none: return ""
        case .sameTimeEarlier:
            return businessDaysBefore == 1
                ? "Vai para o dia útil anterior, no mesmo horário (\(t.string(from: original)))."
                : "O mesmo horário estava ocupado nos dias úteis mais próximos. Vai para \(businessDaysBefore) dias úteis antes, no mesmo horário (\(t.string(from: original)))."
        case .otherTimeLastBusinessDay:
            return "O horário das \(t.string(from: original)) não está livre em nenhum dos 3 dias úteis antes. Vai para o dia útil logo antes, no horário livre mais próximo (\(t.string(from: proposed)))."
        case .noSlot:
            return "Não há horário livre no dia útil logo antes. Escolha outro dia e horário."
        }
    }
}

/// Regra para datas que caem em fim de semana, feriado ou dia sem atendimento (retornos e consultas recorrentes):
/// 1. volta para o dia útil mais próximo, antes da folga, com o mesmo horário livre;
/// 2. se esse dia ficar a mais de 3 dias úteis antes da folga, marca no dia útil logo antes da folga, no horário
///    livre mais próximo do original;
/// 3. feriados emendados contam como uma folga só.
/// O app sempre avisa e pede aprovação antes de agendar.
enum BusinessDayRule {
    static let maxBusinessDaysBack = 3
    static let slotStepMinutes = 15
    static let weekdayLongNames = ["domingo", "segunda-feira", "terça-feira", "quarta-feira", "quinta-feira", "sexta-feira", "sábado"]

    static func reason(for day: Date, holidays cal: HolidayCalendar) -> String {
        if let h = cal.name(of: day) { return "feriado: " + h }
        let w = cal.calendar.component(.weekday, from: day)
        if w == 1 || w == 7 { return "fim de semana" }
        return "\(weekdayLongNames[w - 1]) não é dia de atendimento"
    }

    typealias FreeCheck = (Date, Int) -> Bool

    static func adjust(_ target: Date, durationMinutes: Int, settings: AppSettings, isFree agendaFree: @escaping FreeCheck,
                       now: Date, calendar: Calendar = .current) -> DayAdjustment {
        let cal = HolidayCalendar(settings, calendar: calendar)
        // Livre: sem sessão marcada e fora dos intervalos do expediente.
        let isFree: FreeCheck = { start, minutes in
            agendaFree(start, minutes) && WorkBreaks.hit(settings, start: start, minutes: minutes, calendar: calendar) == nil
        }
        let day = calendar.startOfDay(for: target)
        if cal.isBusinessDay(day) {
            return DayAdjustment(original: target, proposed: target, kind: .none, offStart: day, offEnd: day)
        }
        var offStart = day
        for _ in 0..<366 where !cal.isBusinessDay(cal.addDays(-1, offStart)) { offStart = cal.addDays(-1, offStart) }
        var offEnd = day
        for _ in 0..<366 where !cal.isBusinessDay(cal.addDays(1, offEnd)) { offEnd = cal.addDays(1, offEnd) }
        let why = reason(for: day, holidays: cal)

        var businessDays: [Date] = []
        var d = cal.addDays(-1, offStart)
        for _ in 0..<400 {
            if businessDays.count >= maxBusinessDaysBack { break }
            if cal.isBusinessDay(d) { businessDays.append(d) }
            d = cal.addDays(-1, d)
        }
        guard !businessDays.isEmpty else {
            return DayAdjustment(original: target, proposed: target, kind: .noSlot, reason: why, offStart: offStart, offEnd: offEnd)
        }
        let timeOfDay = target.timeIntervalSince(day)
        for (i, bd) in businessDays.enumerated() {
            let candidate = bd.addingTimeInterval(timeOfDay)
            if candidate > now && isFree(candidate, durationMinutes) {
                return DayAdjustment(original: target, proposed: candidate, kind: .sameTimeEarlier, reason: why,
                                     offStart: offStart, offEnd: offEnd, businessDaysBefore: i + 1)
            }
        }
        let last = businessDays[0]
        let startMin = min(max(settings.workdayStartHour, 0), 23) * 60
        let endMin = min(max(settings.workdayEndHour, 1), 24) * 60
        let wanted = timeOfDay / 60
        var best: Date?
        var bestDistance = Double.greatestFiniteMagnitude
        var m = startMin
        while m + durationMinutes <= endMin {
            let candidate = last.addingTimeInterval(TimeInterval(m * 60))
            if candidate > now && isFree(candidate, durationMinutes) {
                let distance = abs(Double(m) - wanted)
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
            m += slotStepMinutes
        }
        if let best {
            return DayAdjustment(original: target, proposed: best, kind: .otherTimeLastBusinessDay, reason: why,
                                 offStart: offStart, offEnd: offEnd, businessDaysBefore: 1)
        }
        return DayAdjustment(original: target, proposed: last.addingTimeInterval(timeOfDay), kind: .noSlot, reason: why,
                             offStart: offStart, offEnd: offEnd, businessDaysBefore: 1)
    }

    /// Livre na agenda: nenhuma sessão (não cancelada) no intervalo, fora as ignoradas.
    static func free(in booked: [Appointment], extra: [(start: Date, minutes: Int)] = [], ignoring: UUID? = nil) -> FreeCheck {
        { start, minutes in
            if !Conflicts.overlapping(start: start, durationMinutes: minutes, in: booked, excluding: ignoring).isEmpty { return false }
            let end = start.addingTimeInterval(TimeInterval(minutes * 60))
            return !extra.contains { $0.start < end && $0.start.addingTimeInterval(TimeInterval($0.minutes * 60)) > start }
        }
    }
}

/// Retorno: uma nova sessão do paciente, depois do intervalo escolhido, no mesmo horário da sessão de origem.
enum ReturnPlanner {
    static func plan(from a: Appointment, interval: ReturnInterval, durationMinutes: Int, db: Database, now: Date) -> DayAdjustment {
        let target = interval.apply(a.start)
        return BusinessDayRule.adjust(target, durationMinutes: durationMinutes, settings: db.settings,
                                      isFree: BusinessDayRule.free(in: db.appointments), now: now)
    }

    static func make(from a: Appointment, start: Date, durationMinutes: Int, db: Database) -> Appointment {
        Appointment(patientID: a.patientID, start: start, durationMinutes: durationMinutes, tagID: db.returnTag()?.id)
    }
}

// MARK: - Séries no calendário real

enum OccurrenceChoice: Equatable {
    /// Agendar na data proposta (dia útil anterior).
    case useProposal
    /// Agendar mesmo assim no dia original.
    case keepOriginal
    /// Não agendar esta sessão.
    case skip
}

struct PlannedOccurrence: Identifiable, Equatable {
    let id = UUID()
    var original: Date
    var date: Date
    var adjusted: Bool
    var adjustment: DayAdjustment?
    var choice: OccurrenceChoice = .useProposal

    var included: Bool { choice != .skip }

    mutating func resolve(_ c: OccurrenceChoice) {
        choice = c
        date = c == .useProposal ? (adjustment?.proposed ?? original) : original
    }
}

/// Datas de uma série levando em conta o calendário real: da segunda sessão em diante, as que caem em folga
/// seguem a regra de dias úteis, com aprovação do profissional.
enum RecurrencePlanner {
    static func plan(start: Date, rule: RepeatRule, until: Date?, settings: AppSettings, booked: [Appointment],
                     now: Date, durationMinutes: Int, calendar: Calendar = .current) -> [PlannedOccurrence] {
        let cal = HolidayCalendar(settings, calendar: calendar)
        var result: [PlannedOccurrence] = []
        var planned: [(start: Date, minutes: Int)] = []
        for (i, d) in Recurrence.dates(start: start, rule: rule, until: until, calendar: calendar).enumerated() {
            if i > 0 && !cal.isBusinessDay(d) {
                let adj = BusinessDayRule.adjust(d, durationMinutes: durationMinutes, settings: settings,
                                                 isFree: BusinessDayRule.free(in: booked, extra: planned), now: now, calendar: calendar)
                result.append(PlannedOccurrence(original: d, date: adj.proposed, adjusted: true, adjustment: adj))
                planned.append((adj.proposed, durationMinutes))
                continue
            }
            result.append(PlannedOccurrence(original: d, date: d, adjusted: false))
            planned.append((d, durationMinutes))
        }
        return result
    }

    static func dates(_ plan: [PlannedOccurrence]) -> [Date] { plan.filter(\.included).map(\.date) }
}
