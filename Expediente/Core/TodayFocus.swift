import Foundation

/// Qual sessão da agenda de hoje fica em foco conforme o relógio do aparelho.
enum TodayFocus {
    /// Sessão em andamento (não cancelada).
    static func current(_ list: [Appointment], now: Date) -> Appointment? {
        list.first { !$0.isCancelled && $0.start <= now && $0.end > now }
    }

    /// Próxima sessão que ainda não começou (não cancelada).
    static func next(_ list: [Appointment], now: Date) -> Appointment? {
        list.filter { !$0.isCancelled && $0.start > now }.min { $0.start < $1.start }
    }

    /// Para onde a agenda rola: a sessão em andamento; senão a próxima; passada a última, a última do dia.
    static func focus(_ list: [Appointment], now: Date) -> Appointment? {
        current(list, now: now) ?? next(list, now: now) ?? list.filter { !$0.isCancelled }.max { $0.start < $1.start }
    }
}
