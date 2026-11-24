import Foundation

enum Formatters {
    static let locale = Locale(identifier: "pt_BR")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        return f
    }

    static let time = make("HH:mm")
    static let shortDate = make("dd/MM/yyyy")
    static let dayMonth = make("dd/MM")
    static let dateTime = make("dd/MM/yyyy 'às' HH:mm")
    static let longDay = make("EEEE, d 'de' MMMM")
    static let longDate = make("d 'de' MMMM 'de' yyyy")
    static let dayMonthLong = make("d 'de' MMM")
    static let monthYear = make("MMMM 'de' yyyy")
    static let weekdayShort = make("EEE")
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()

    static let weekdayNames = ["domingo", "segunda", "terça", "quarta", "quinta", "sexta", "sábado"]

    static func weekdayName(_ date: Date, calendar: Calendar = .current) -> String {
        weekdayNames[calendar.component(.weekday, from: date) - 1]
    }

    static func isFeminineWeekday(_ date: Date, calendar: Calendar = .current) -> Bool {
        let w = calendar.component(.weekday, from: date)
        return w >= 2 && w <= 6
    }

    static func capitalizedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// "Ana", "Ana e Bruno", "Ana, Bruno e Carla".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " e " + items.last!
        }
    }

    static func money(_ cents: Int) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = "BRL"
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "R$ \(cents / 100)"
    }

    static func percent(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .percent
        f.maximumFractionDigits = 1
        return f.string(from: NSNumber(value: value)) ?? "\(Int(value * 100))%"
    }

    /// Lê valores como "180", "180,50", "R$ 1.200,00".
    static func parseMoney(_ text: String) -> Int? {
        var s = text.replacingOccurrences(of: "R$", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.contains(",") {
            s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        guard let value = Decimal(string: s, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        var cents = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static func moneyInput(_ cents: Int?) -> String {
        guard let cents else { return "" }
        let rest = cents % 100
        return "\(cents / 100)," + (rest < 10 ? "0\(rest)" : "\(rest)")
    }

    /// Máximo de dígitos do valor digitado (9.999.999,99).
    static let moneyMaxDigits = 9

    /// Máscara de valor: só os dígitos contam, e o app põe o ponto dos milhares e a vírgula dos centavos.
    /// "1" vira "0,01", "180" vira "1,80" e "18000" vira "180,00". Sem dígitos (ou só zeros), o campo fica vazio.
    static func moneyMask(_ raw: String) -> String {
        let digits = String(raw.filter(\.isASCIIDigit).drop(while: { $0 == "0" }).prefix(moneyMaxDigits))
        guard let cents = Int(digits), cents > 0 else { return "" }
        let reais = String(cents / 100)
        var grouped = ""
        for (i, ch) in reais.reversed().enumerated() {
            if i > 0, i % 3 == 0 { grouped.append(".") }
            grouped.append(ch)
        }
        let rest = cents % 100
        return String(grouped.reversed()) + "," + (rest < 10 ? "0\(rest)" : "\(rest)")
    }

    /// Texto cinza do campo de valor: o valor que será usado, ou "0,00".
    static func moneyPlaceholder(_ cents: Int?) -> String {
        let m = moneyMasked(cents)
        return m.isEmpty ? "0,00" : m
    }

    /// O valor já com a máscara, a partir dos centavos (nil ou zero = campo vazio).
    static func moneyMasked(_ cents: Int?) -> String {
        guard let cents, cents > 0 else { return "" }
        return moneyMask(String(cents))
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
