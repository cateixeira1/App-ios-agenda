import Foundation

enum RepeatRule: String, CaseIterable, Identifiable, Codable {
    case none, weekly, biweekly, monthly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Não repete"
        case .weekly: return "Toda semana"
        case .biweekly: return "A cada 2 semanas"
        case .monthly: return "Todo mês, no mesmo dia"
        }
    }
    var intervalWeeks: Int { self == .biweekly ? 2 : 1 }
}

enum Recurrence {
    /// Sem data de término, a série é criada para os próximos 12 meses.
    static let defaultSpanMonths = 12
    static let maximumOccurrences = 120

    /// Datas da série semanal: mesmo dia da semana e mesmo horário de `start`, até `until` (inclusive).
    static func dates(start: Date, rule: RepeatRule, until: Date?, calendar: Calendar = .current) -> [Date] {
        guard rule != .none else { return [start] }
        let limit = until.map { calendar.endOfDay($0) }
            ?? calendar.date(byAdding: .month, value: defaultSpanMonths, to: start)!
        var result: [Date] = []
        if rule == .monthly {
            // Mesmo dia do mês (dia 31 vira o último dia nos meses mais curtos).
            let day = calendar.component(.day, from: start)
            let time = start.timeIntervalSince(calendar.startOfDay(for: start))
            let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: start)) ?? start
            var i = 0
            while result.count < maximumOccurrences {
                guard let m = calendar.date(byAdding: .month, value: i, to: firstOfMonth) else { break }
                let days = calendar.range(of: .day, in: .month, for: m)?.count ?? 28
                let d = calendar.date(byAdding: .day, value: min(day, days) - 1, to: m)!.addingTimeInterval(time)
                if d > limit { break }
                result.append(d)
                i += 1
            }
            return result
        }
        var current = start
        while current <= limit && result.count < maximumOccurrences {
            result.append(current)
            guard let next = calendar.date(byAdding: .weekOfYear, value: rule.intervalWeeks, to: current) else { break }
            current = next
        }
        return result
    }

    /// Texto como "Toda terça às 16:00".
    static func describe(start: Date, rule: RepeatRule, calendar: Calendar = .current) -> String {
        guard rule != .none else { return "Não repete" }
        let weekday = Formatters.weekdayName(start, calendar: calendar)
        let c = calendar.dateComponents([.hour, .minute], from: start)
        let h = c.hour ?? 0, m = c.minute ?? 0
        let time = (h < 10 ? "0\(h)" : "\(h)") + ":" + (m < 10 ? "0\(m)" : "\(m)")
        let article = Formatters.isFeminineWeekday(start, calendar: calendar) ? "Toda" : "Todo"
        if rule == .weekly { return "\(article) \(weekday) às \(time)" }
        if rule == .monthly { return "Todo dia \(calendar.component(.day, from: start)) às \(time)" }
        return "A cada 2 semanas, \(weekday) às \(time)"
    }
}

enum Conflicts {
    /// Sessões que se sobrepõem ao intervalo indicado (as desmarcadas com aviso não contam).
    static func overlapping(start: Date, durationMinutes: Int, in appointments: [Appointment], excluding id: UUID? = nil) -> [Appointment] {
        let end = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        return appointments.filter { a in
            a.id != id && !a.isCancelled && a.start < end && a.end > start
        }
    }
}

extension Calendar {
    func endOfDay(_ date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? date
    }

    func monthInterval(containing date: Date) -> DateInterval {
        dateInterval(of: .month, for: date) ?? DateInterval(start: startOfDay(for: date), duration: 86_400 * 30)
    }

    func dayInterval(_ date: Date) -> DateInterval {
        dateInterval(of: .day, for: date) ?? DateInterval(start: startOfDay(for: date), duration: 86_400)
    }

    /// Data com o dia de `day` e o horário de `time`.
    func combine(day: Date, time: Date) -> Date {
        let d = dateComponents([.year, .month, .day], from: day)
        let t = dateComponents([.hour, .minute], from: time)
        var c = DateComponents()
        c.year = d.year; c.month = d.month; c.day = d.day
        c.hour = t.hour; c.minute = t.minute
        return date(from: c) ?? day
    }
}

// MARK: - Busca de nomes

/// Sugere o paciente cujo nome é igual ou o mais parecido com o que foi digitado.
enum NameMatcher {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Pontuação: quanto menor, mais parecido. `nil` quando não há semelhança suficiente.
    static func score(query: String, name: String) -> Int? {
        let q = normalize(query)
        let n = normalize(name)
        guard !q.isEmpty else { return nil }
        if q == n { return 0 }
        if n.hasPrefix(q) { return 1 }
        let qWords = q.split(separator: " ").map(String.init)
        let nWords = n.split(separator: " ").map(String.init)
        if qWords.allSatisfy({ qw in nWords.contains(where: { $0.hasPrefix(qw) }) }) { return 2 }
        if n.contains(q) { return 3 }
        // Erros de digitação: compara com o nome inteiro e com cada palavra.
        let tolerance = max(1, q.count / 4)
        var best = levenshtein(q, n)
        for w in nWords { best = min(best, levenshtein(q, w)) }
        if qWords.count > 1 {
            // Compara com o começo do nome com o mesmo número de palavras.
            let head = nWords.prefix(qWords.count).joined(separator: " ")
            best = min(best, levenshtein(q, head))
        }
        return best <= tolerance ? 10 + best : nil
    }

    static func suggestions(for query: String, in patients: [Patient], limit: Int = 5) -> [Patient] {
        var scored: [(patient: Patient, score: Int)] = []
        for p in patients where !p.archived {
            if let s = score(query: query, name: p.name) { scored.append((p, s)) }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.patient.name.localizedCompare(b.patient.name) == .orderedAscending
        }
        return scored.prefix(limit).map { $0.patient }
    }

    static func exactMatch(for query: String, in patients: [Patient]) -> Patient? {
        let q = normalize(query)
        return patients.first { normalize($0.name) == q }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - Atendimentos sem anotação e lembretes

enum Documentation {
    /// O atendimento conta como registrado se tiver anotação com texto.
    static func isDocumented(_ appointment: Appointment, in db: Database) -> Bool {
        db.notes.contains(where: { $0.appointmentID == appointment.id && !$0.body.isBlank })
    }

    /// Faltas e atendimentos desmarcados com aviso não pedem anotação.
    static func needsNote(_ a: Appointment) -> Bool { a.attendance != .missed && a.attendance != .cancelled }

    /// Atendimentos do dia que precisam de anotação.
    static func undocumented(on day: Date, in db: Database, calendar: Calendar = .current) -> [Appointment] {
        db.appointments(on: day, calendar: calendar).filter { needsNote($0) && !isDocumented($0, in: db) }
    }

    /// Atendimentos já encerrados, dos últimos `days` dias, ainda sem anotação.
    static func pending(in db: Database, now: Date = Date(), days: Int = 30, calendar: Calendar = .current) -> [Appointment] {
        let from = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
        return db.appointments
            .filter { $0.end <= now && $0.start >= from && needsNote($0) && !isDocumented($0, in: db) }
            .sorted { $0.start > $1.start }
    }

    struct Reminder: Equatable {
        var identifier: String
        var fireDate: Date
        var title: String
        var body: String
        var appointmentIDs: [UUID]
    }

    static let reminderPrefix = "fim-do-dia-"
    static let upcomingPrefix = "antes-"
    /// O iPhone guarda no máximo 64 avisos pendentes por app; o app agenda só os próximos.
    static let maxUpcoming = 50

    /// Um aviso por dia, 5 minutos depois do fim do último atendimento, listando quem ficou sem anotação.
    static func reminders(for db: Database, now: Date = Date(), days: Int = 14, calendar: Calendar = .current) -> [Reminder] {
        guard db.settings.endOfDayReminder else { return [] }
        var out: [Reminder] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let all = db.appointments(on: day, calendar: calendar).filter(needsNote)
            guard let lastEnd = all.map(\.end).max() else { continue }
            let fire = lastEnd.addingTimeInterval(5 * 60)
            guard fire > now else { continue }
            let missing = all.filter { !isDocumented($0, in: db) }
            guard !missing.isEmpty else { continue }
            let names = missing.compactMap { db.patient($0.patientID)?.firstName }
            let body: String
            if db.settings.reminderShowsNames {
                body = "Sem anotação: " + Formatters.list(names) + "."
            } else {
                body = missing.count == 1 ? "1 atendimento de hoje está sem anotação." : "\(missing.count) atendimentos de hoje estão sem anotação."
            }
            let id = reminderPrefix + Formatters.isoDay.string(from: day)
            out.append(Reminder(identifier: id, fireDate: fire,
                                title: missing.count == 1 ? "Atendimento sem anotação" : "Atendimentos sem anotação",
                                body: body, appointmentIDs: missing.map(\.id)))
        }
        return out
    }

    /// Avisos antes de cada atendimento (Ajustes › Agenda › Avisar antes), só para os próximos.
    static func upcomingReminders(for db: Database, now: Date = Date()) -> [Reminder] {
        let minutes = db.settings.reminderMinutesBefore
        guard minutes > 0 else { return [] }
        let list = db.appointments
            .filter { !$0.isCancelled && $0.start.addingTimeInterval(TimeInterval(-minutes * 60)) > now }
            .sorted { $0.start < $1.start }
            .prefix(maxUpcoming)
        return list.map { a in
            let name = db.settings.reminderShowsNames ? (db.patient(a.patientID)?.name ?? Term.Client) : "Próximo atendimento"
            var parts = ["\(Formatters.time.string(from: a.start))"]
            if let t = db.tag(a.tagID) { parts.append(t.name) }
            let place = db.location(of: a)
            if !place.isEmpty && db.settings.reminderShowsNames { parts.append(place) }
            let lead = minutes < 60 ? "Em \(minutes) min" : "Em \(Formatters.duration(minutes))"
            return Reminder(identifier: upcomingPrefix + a.id.uuidString,
                            fireDate: a.start.addingTimeInterval(TimeInterval(-minutes * 60)),
                            title: "\(lead): \(name)", body: parts.joined(separator: " · "), appointmentIDs: [a.id])
        }
    }
}

// MARK: - Atendimentos do cliente

/// Bloco "Atendimentos do cliente": lista do mais recente para o mais antigo, com filtro por período.
enum HistoryPeriod: String, CaseIterable, Identifiable {
    case last15Days, lastMonth, last3Months, last6Months, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .last15Days: return "Últimos 15 dias"
        case .lastMonth: return "Último mês"
        case .last3Months: return "Últimos 3 meses"
        case .last6Months: return "Últimos 6 meses"
        case .all: return "Desde sempre"
        }
    }

    func cutoff(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .last15Days: return calendar.date(byAdding: .day, value: -15, to: today)
        case .lastMonth: return calendar.date(byAdding: .month, value: -1, to: today)
        case .last3Months: return calendar.date(byAdding: .month, value: -3, to: today)
        case .last6Months: return calendar.date(byAdding: .month, value: -6, to: today)
        case .all: return nil
        }
    }
}

enum SessionBadge: Equatable {
    case presence, absence, cancelled, scheduled
    var label: String {
        switch self {
        case .presence: return "Presença"
        case .absence: return "Falta"
        case .cancelled: return "Cancelado"
        case .scheduled: return "Agendado"
        }
    }
}

enum SessionHistory {
    /// Atendimentos do cliente no período, do mais recente para o mais antigo (os futuros aparecem no topo).
    static func list(_ db: Database, patientID: UUID, period: HistoryPeriod, now: Date) -> [Appointment] {
        let cutoff = period.cutoff(now: now)
        return db.appointments.filter { $0.patientID == patientID && (cutoff == nil || $0.start >= cutoff!) }
            .sorted { $0.start > $1.start }
    }

    static func badge(_ a: Appointment, now: Date) -> SessionBadge {
        switch a.attendance {
        case .cancelled: return .cancelled
        case .missed: return .absence
        case .attended: return .presence
        case .scheduled: return a.end <= now ? .presence : .scheduled
        }
    }

    struct Counts: Equatable { var presence = 0, absence = 0, cancelled = 0, scheduled = 0 }

    static func count(_ list: [Appointment], now: Date) -> Counts {
        var c = Counts()
        for a in list {
            switch badge(a, now: now) {
            case .presence: c.presence += 1
            case .absence: c.absence += 1
            case .cancelled: c.cancelled += 1
            case .scheduled: c.scheduled += 1
            }
        }
        return c
    }
}
