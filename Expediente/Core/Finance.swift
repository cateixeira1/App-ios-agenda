import Foundation

struct FinanceSummary: Equatable {
    var interval: DateInterval
    var receivedCents = 0
    var receivedCount = 0
    /// Sessões já passadas sem pagamento confirmado.
    var openCents = 0
    var openCount = 0
    /// Sessões futuras do período.
    var expectedCents = 0
    var expectedCount = 0
    var byMethod: [PaymentMethod: Int] = [:]
    var openByPatient: [UUID: Int] = [:]
    /// Parte do recebido que veio de pacotes pagos no período.
    var packagesReceivedCents = 0
    var packagesReceivedCount = 0
    /// Pacotes vendidos no período ainda não pagos (já somados em `openCents`).
    var packagesOpenCents = 0
    var packagesOpenCount = 0
    /// Despesas do período.
    var expensesCents = 0
    var expensesCount = 0
    var expensesByCategory: [ExpenseCategory: Int] = [:]

    /// Recebido menos despesas.
    var netCents: Int { receivedCents - expensesCents }

    /// Parte do valor devido (recebido + em aberto) que está em aberto.
    var delinquencyRate: Double {
        let due = receivedCents + openCents
        return due == 0 ? 0 : Double(openCents) / Double(due)
    }

    var delinquentPatientCount: Int { openByPatient.count }
}

enum Finance {
    /// Um atendimento passado está em aberto quando foi marcado como "não pago", ou quando não foi informado
    /// e o cliente não faltou nem desmarcou com aviso. Retorno sem custo e atendimento de pacote nunca ficam em aberto.
    static func isOpen(_ a: Appointment, in db: Database, now: Date) -> Bool {
        if Billing.isNoCharge(a, in: db) { return false }
        guard a.end <= now, a.payment != .paid else { return false }
        if a.payment == .unpaid { return true }
        return a.attendance != .missed && a.attendance != .cancelled
    }

    /// Recebido, em aberto, previsto e despesas do período. Atendimentos sem custo (retorno ou pacote) ficam de fora;
    /// os pacotes entram pelo pagamento (no dia do pagamento) ou, sem pagamento, como em aberto (no dia da venda).
    static func summary(_ db: Database, interval: DateInterval, now: Date = Date()) -> FinanceSummary {
        var s = FinanceSummary(interval: interval)
        for a in db.appointments where a.start >= interval.start && a.start < interval.end && Billing.isBillable(a, in: db) {
            let value = db.price(of: a)
            if a.payment == .paid {
                s.receivedCents += value
                s.receivedCount += 1
                s.byMethod[a.method ?? .other, default: 0] += value
            } else if isOpen(a, in: db, now: now) {
                s.openCents += value
                s.openCount += 1
                s.openByPatient[a.patientID, default: 0] += value
            } else if a.start > now && a.attendance != .missed && a.attendance != .cancelled {
                s.expectedCents += value
                s.expectedCount += 1
            }
        }
        for p in db.packages where p.priceCents > 0 {
            if p.isPaid {
                let day = p.paidAt ?? p.purchasedAt
                guard interval.contains(day) else { continue }
                s.receivedCents += p.priceCents
                s.receivedCount += 1
                s.packagesReceivedCents += p.priceCents
                s.packagesReceivedCount += 1
                s.byMethod[p.method ?? .other, default: 0] += p.priceCents
            } else if interval.contains(p.purchasedAt) && p.purchasedAt <= now && !p.closed {
                s.openCents += p.priceCents
                s.openCount += 1
                s.openByPatient[p.patientID, default: 0] += p.priceCents
                s.packagesOpenCents += p.priceCents
                s.packagesOpenCount += 1
            }
        }
        for e in db.expenses where e.date >= interval.start && e.date < interval.end {
            s.expensesCents += e.amountCents
            s.expensesCount += 1
            s.expensesByCategory[e.category, default: 0] += e.amountCents
        }
        return s
    }

    /// Pacotes vendidos e ainda não pagos.
    static func openPackages(_ db: Database, now: Date = Date()) -> [ServicePackage] {
        db.packages.filter { !$0.isPaid && !$0.closed && $0.priceCents > 0 && $0.purchasedAt <= now }
            .sorted { $0.purchasedAt > $1.purchasedAt }
    }

    static func paidPackages(_ db: Database, interval: DateInterval) -> [ServicePackage] {
        db.packages.filter { $0.isPaid && interval.contains($0.paidAt ?? $0.purchasedAt) }
            .sorted { ($0.paidAt ?? $0.purchasedAt) > ($1.paidAt ?? $1.purchasedAt) }
    }

    static func expenses(_ db: Database, interval: DateInterval) -> [Expense] {
        db.expenses.filter { $0.date >= interval.start && $0.date < interval.end }.sorted { $0.date > $1.date }
    }

    static func open(_ db: Database, interval: DateInterval? = nil, now: Date = Date()) -> [Appointment] {
        db.appointments
            .filter { a in isOpen(a, in: db, now: now) && (interval.map { i in a.start >= i.start && a.start < i.end } ?? true) }
            .sorted { $0.start > $1.start }
    }

    static func received(_ db: Database, interval: DateInterval) -> [Appointment] {
        db.appointments
            .filter { $0.payment == .paid && $0.start >= interval.start && $0.start < interval.end && Billing.isBillable($0, in: db) }
            .sorted { $0.start > $1.start }
    }
}

enum ReportKind: String, CaseIterable, Identifiable {
    case patientSessions, finance
    var id: String { rawValue }
    var label: String { self == .patientSessions ? "Atendimentos de um \(Term.client)" : "Financeiro" }
}

enum ReportPeriod: String, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last3Months, thisYear, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thisMonth: return "Este mês"
        case .lastMonth: return "Mês passado"
        case .last3Months: return "Últimos 3 meses"
        case .thisYear: return "Este ano"
        case .custom: return "Escolher datas"
        }
    }

    func interval(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let month = calendar.monthInterval(containing: now)
        switch self {
        case .thisMonth, .custom:
            return month
        case .lastMonth:
            let prev = calendar.date(byAdding: .month, value: -1, to: month.start)!
            return calendar.monthInterval(containing: prev)
        case .last3Months:
            let start = calendar.date(byAdding: .month, value: -2, to: month.start)!
            return DateInterval(start: start, end: month.end)
        case .thisYear:
            return calendar.dateInterval(of: .year, for: now) ?? month
        }
    }
}
