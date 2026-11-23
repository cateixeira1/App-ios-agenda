import Foundation

// Modelos de dados do Expediente. Campos que não existiam na primeira versão usam @Default, para os dados
// antigos continuarem abrindo depois de uma atualização.

// MARK: - Profissional

struct Professional: Codable, Equatable, Hashable {
    var fullName: String = ""
    var email: String = ""
    var phone: String = ""
    /// Profissão ou área (ex.: "Cabeleireira", "Personal trainer", "Advogado").
    @Default<Defaults.EmptyString> var occupation: String = ""
    /// Registro profissional, se houver (ex.: "OAB/SP 123.456", "CREF 012345-G/SP"). Sai nos relatórios.
    @Default<Defaults.EmptyString> var registration: String = ""
    /// Endereço de atendimento numa linha, montado a partir de `office`.
    @Default<Defaults.EmptyString> var officeAddress: String = ""
    var office: PostalAddress?

    var firstName: String {
        fullName.split(separator: " ").first.map(String.init) ?? ""
    }

    /// Profissão e registro, numa linha (vazio se nada foi informado).
    var subtitle: String {
        [occupation, registration].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Clientes

/// Arquivo anexado ao cadastro (ex.: contrato). O conteúdo fica cifrado em um arquivo separado.
struct Attachment: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var fileName: String
    var addedAt: Date
    var byteCount: Int
}

/// Cliente (ou paciente, ou aluno: o nome muda em Ajustes). O tipo continua `Patient` no código.
struct Patient: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var phone: String = ""
    var email: String = ""
    var cpf: String = ""
    var birthDate: Date?
    /// Endereço numa linha, montado a partir de `addressParts`.
    var address: String = ""
    /// Endereço em partes, com o CEP.
    var addressParts: PostalAddress?
    var guardianName: String = ""
    var guardianPhone: String = ""
    /// CPF do responsável, para a nota fiscal sair em nome de quem paga.
    @Default<Defaults.EmptyString> var guardianCpf: String = ""
    var notes: String = ""
    var sessionPriceCents: Int?
    /// Contrato, termo ou outro documento do cliente.
    var consent: Attachment?
    var createdAt = Date()
    var archived = false

    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

// MARK: - Agenda

enum PaymentStatus: String, Codable, Hashable {
    case paid, unpaid
}

enum PaymentMethod: String, Codable, CaseIterable, Identifiable, Hashable {
    case pix, cash, debit, credit, transfer, slip, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pix: return "Pix"
        case .cash: return "Dinheiro"
        case .debit: return "Cartão de débito"
        case .credit: return "Cartão de crédito"
        case .transfer: return "Transferência"
        case .slip: return "Boleto"
        case .other: return "Outro"
        }
    }
}

enum Attendance: String, Codable, CaseIterable, Identifiable, Hashable {
    case scheduled, attended, missed
    /// Desmarcado com aviso (diferente de falta).
    case cancelled
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scheduled: return "Agendado"
        case .attended: return "Realizado"
        case .missed: return "\(Term.Client) faltou"
        case .cancelled: return "Cancelado com aviso"
        }
    }
    var shortLabel: String {
        switch self {
        case .scheduled: return "Agendado"
        case .attended: return "Realizado"
        case .missed: return "Faltou"
        case .cancelled: return "Cancelado"
        }
    }
}

struct Appointment: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var patientID: UUID
    var start: Date
    var durationMinutes: Int = 60
    var tagID: UUID?
    /// Mesmo valor em todos os atendimentos de uma série recorrente.
    var seriesID: UUID?
    var payment: PaymentStatus?
    var amountCents: Int?
    var method: PaymentMethod?
    var paidAt: Date?
    var attendance: Attendance = .scheduled
    var invoiceNumber: String?
    var invoiceIssuedAt: Date?
    /// Emissão pela NFS-e Nacional. Existe a partir da primeira tentativa.
    var nfse: NfseInfo?
    /// Notas canceladas (ou de teste) deste atendimento.
    var nfseHistory: [NfseInfo]?
    /// Onde é o atendimento: endereço, "Online" ou o link da reunião. Vazio = o local padrão de Ajustes.
    @Default<Defaults.EmptyString> var location: String = ""
    /// Pacote de que este atendimento faz parte (já pago no pacote; não é cobrado sozinho).
    var packageID: UUID?

    var end: Date { start.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var hasInvoice: Bool { !(invoiceNumber ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var isCancelled: Bool { attendance == .cancelled }
}

/// Tag: o tipo de serviço (com cor, duração, valor e mensagem próprios).
struct Tag: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var colorHex: String
    /// Duração dos atendimentos com esta tag (vazio = a duração padrão de Ajustes).
    var durationMinutes: Int?
    /// Valor padrão dos atendimentos com esta tag, em centavos (vazio = o do cliente ou o padrão de Ajustes).
    /// Na tag de retorno, vazio significa sem custo.
    var defaultPriceCents: Int?
    /// Mensagem de WhatsApp dos atendimentos com esta tag (vazio = a mensagem geral de Ajustes).
    var whatsAppMessage: String?

    static let firstSessionPresetName = "Primeiro atendimento"
    static let returnPresetName = "Retorno"
    static let returnPresetColor = "#80CBC4"

    /// Tags de quem ainda não escolheu a área de atuação.
    static var presets: [Tag] { BusinessArea.general.presetTags }

    /// Tons que não se confundem com as cores de pagamento e presença.
    static let palette = ["#B39DDB", "#F48FB1", "#C98B6B", "#E0B33C", "#9E9E9E", "#80CBC4",
                          "#90A4AE", "#CE93D8", "#FFAB91", "#A5D6A7", "#81D4FA", "#BCAAA4"]
}

// MARK: - Área de atuação e nome do cliente

/// Como o app chama quem é atendido.
enum ClientTerm: String, Codable, CaseIterable, Identifiable, Hashable {
    case client, patient, student
    var id: String { rawValue }
    var singular: String {
        switch self {
        case .client: return "cliente"
        case .patient: return "paciente"
        case .student: return "aluno"
        }
    }
    var plural: String { singular + "s" }
    var label: String { Formatters.capitalizedFirst(singular) }
}

/// Termos usados nas telas e nos documentos. Mudam com Ajustes › Perfil › "Como chamar quem você atende".
/// Os três nomes são masculinos ("o cliente", "o paciente", "o aluno"), então artigos e concordância não mudam.
enum Term {
    static var kind: ClientTerm = .client
    /// "cliente"
    static var client: String { kind.singular }
    /// "clientes"
    static var clients: String { kind.plural }
    /// "Cliente"
    static var Client: String { Formatters.capitalizedFirst(kind.singular) }
    /// "Clientes"
    static var Clients: String { Formatters.capitalizedFirst(kind.plural) }
}

/// Área de atuação: define as tags sugeridas e o nome de quem é atendido.
enum BusinessArea: String, Codable, CaseIterable, Identifiable, Hashable {
    case general, beauty, health, fitness, classes, consulting, technical
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "Outra área"
        case .beauty: return "Beleza e estética"
        case .health: return "Saúde e terapias"
        case .fitness: return "Esporte e treino"
        case .classes: return "Aulas e cursos"
        case .consulting: return "Consultoria, advocacia e contabilidade"
        case .technical: return "Serviços técnicos e domiciliares"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "briefcase.fill"
        case .beauty: return "scissors"
        case .health: return "heart.text.square.fill"
        case .fitness: return "figure.run"
        case .classes: return "book.fill"
        case .consulting: return "building.columns.fill"
        case .technical: return "wrench.and.screwdriver.fill"
        }
    }
    var suggestedTerm: ClientTerm {
        switch self {
        case .health: return .patient
        case .fitness, .classes: return .student
        default: return .client
        }
    }
    /// Duração padrão sugerida, em minutos.
    var defaultDuration: Int {
        switch self {
        case .beauty, .consulting, .health, .fitness, .classes, .general: return 60
        case .technical: return 90
        }
    }

    var presetTags: [Tag] {
        func t(_ n: String, _ c: String, _ d: Int? = nil) -> Tag { Tag(name: n, colorHex: c, durationMinutes: d) }
        let first = t(Tag.firstSessionPresetName, "#B39DDB")
        let ret = t(Tag.returnPresetName, Tag.returnPresetColor)
        let personal = t("Pessoal", "#9E9E9E")
        switch self {
        case .general:
            return [first, t("Atendimento", "#F48FB1"), ret, t("Online", "#81D4FA"), personal]
        case .beauty:
            return [t("Corte", "#F48FB1", 45), t("Coloração", "#CE93D8", 120), t("Escova", "#FFAB91", 45),
                    t("Manicure e pedicure", "#E0B33C", 60), t("Sobrancelha", "#C98B6B", 30), ret, personal]
        case .health:
            return [t("Avaliação", "#B39DDB", 60), t("Sessão", "#F48FB1", 50), ret, t("Online", "#81D4FA", 50), personal]
        case .fitness:
            return [t("Aula experimental", "#B39DDB", 60), t("Treino individual", "#F48FB1", 60),
                    t("Treino em grupo", "#E0B33C", 60), t("Avaliação física", "#A5D6A7", 45), t("Reposição", "#80CBC4", 60), personal]
        case .classes:
            return [t("Aula experimental", "#B39DDB", 60), t("Aula individual", "#F48FB1", 60),
                    t("Aula em grupo", "#E0B33C", 90), t("Reposição", "#80CBC4", 60), t("Online", "#81D4FA", 60), personal]
        case .consulting:
            return [t("Primeira reunião", "#B39DDB", 60), t("Reunião", "#F48FB1", 60), t("Audiência ou prazo", "#FFAB91", 60),
                    t("Online", "#81D4FA", 60), ret, personal]
        case .technical:
            return [t("Orçamento", "#B39DDB", 60), t("Visita técnica", "#F48FB1", 90), t("Instalação", "#E0B33C", 180),
                    t("Manutenção", "#A5D6A7", 120), t("Garantia", "#80CBC4", 60), personal]
        }
    }
}

// MARK: - Anotações

/// Texto com formatação (trechos com fonte, tamanho, estilo, cor e alinhamento, em JSON),
/// com uma cópia em texto puro para busca e para saber se está vazio.
struct RichText: Codable, Equatable, Hashable {
    var format: Data = Data()
    var plain: String = ""

    var isBlank: Bool { plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    static let empty = RichText()
}

struct SessionNote: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var patientID: UUID
    var appointmentID: UUID?
    var createdAt = Date()
    var updatedAt = Date()
    var body = RichText()
}

// MARK: - Pacotes

/// Pacote pré-pago (ex.: 10 aulas, 4 sessões). O pagamento é do pacote; os atendimentos ligados a ele
/// não são cobrados um a um e vão descontando do saldo.
struct ServicePackage: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var patientID: UUID
    var name: String = ""
    var totalSessions: Int = 10
    var priceCents: Int = 0
    var tagID: UUID?
    var purchasedAt: Date = Date()
    /// Depois desta data o saldo não vale mais (vazio = sem validade).
    var expiresAt: Date?
    var payment: PaymentStatus?
    var method: PaymentMethod?
    var paidAt: Date?
    @Default<Defaults.EmptyString> var notes: String = ""
    /// Pacote encerrado à mão (ex.: devolvido). Não aceita novos atendimentos.
    @Default<Defaults.False> var closed: Bool = false

    var title: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Pacote de \(totalSessions)" : n
    }
    var isPaid: Bool { payment == .paid }
    func isExpired(now: Date) -> Bool { expiresAt.map { $0 < now } ?? false }
}

// MARK: - Despesas

enum ExpenseCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    case rent, supplies, transport, marketing, software, taxes, training, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rent: return "Aluguel e espaço"
        case .supplies: return "Material e produtos"
        case .transport: return "Transporte"
        case .marketing: return "Divulgação"
        case .software: return "Sistemas e assinaturas"
        case .taxes: return "Impostos e taxas"
        case .training: return "Cursos"
        case .other: return "Outros"
        }
    }
    var symbol: String {
        switch self {
        case .rent: return "building.2"
        case .supplies: return "shippingbox"
        case .transport: return "car"
        case .marketing: return "megaphone"
        case .software: return "app.badge"
        case .taxes: return "building.columns"
        case .training: return "graduationcap"
        case .other: return "ellipsis.circle"
        }
    }
}

struct Expense: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var date: Date = Date()
    var title: String = ""
    var amountCents: Int = 0
    var category: ExpenseCategory = .other
    var method: PaymentMethod?
    @Default<Defaults.EmptyString> var notes: String = ""
}

// MARK: - Ajustes

/// Como a agenda (tela inicial) aparece no iPhone.
enum AgendaMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case day, week, month
    var id: String { rawValue }
    var label: String {
        switch self {
        case .day: return "Dia"
        case .week: return "Semana"
        case .month: return "Mês"
        }
    }
}

struct AppSettings: Codable, Equatable, Hashable {
    var patientRowHeight: Double = 64
    /// Aviso no fim do dia com os atendimentos sem anotação (desligado por padrão).
    var endOfDayReminder = false
    var reminderShowsNames = true
    var defaultDurationMinutes = 60
    var defaultPriceCents: Int?
    /// 0 = bloqueia assim que o app sai da tela.
    var lockAfterSeconds = 0
    var workdayStartHour = 7
    var workdayEndHour = 21
    /// Por padrão os dados não vão para o backup do iCloud do aparelho (eles continuariam cifrados).
    var includeInDeviceBackup = false

    /// Duração padrão do primeiro atendimento.
    @Default<Defaults.FirstSessionMinutes> var firstSessionDurationMinutes: Int = 60
    /// Tag que marca o primeiro atendimento. Vazio = a tag chamada "Primeiro atendimento".
    var firstSessionTagID: UUID?
    /// Tag que marca o retorno. Vazio = a tag chamada "Retorno". O retorno não tem custo, a não ser que a tag tenha valor.
    var returnTagID: UUID?
    /// Valor por cliente: o valor do cadastro do cliente vale sempre, qualquer que seja a tag (o valor da tag não é usado).
    @Default<Defaults.False> var priceByClient: Bool = false
    /// Último intervalo de retorno usado.
    @Default<Defaults.ReturnValue> var returnIntervalValue: Int = 30
    @Default<Defaults.ReturnUnitDays> var returnIntervalUnit: ReturnUnit = .days
    /// Dias de atendimento (0 = domingo … 6 = sábado).
    @Default<Defaults.WeekdaysMonFri> var workDays: [Int] = [1, 2, 3, 4, 5]
    /// Carnaval e Corpus Christi (pontos facultativos) contam como feriado.
    @Default<Defaults.True> var optionalHolidaysOff: Bool = true
    @Default<Defaults.EmptyList<CustomHoliday>> var customHolidays: [CustomHoliday] = []
    @Default<Defaults.False> var sessionsAsBlocks: Bool = false
    @Default<Defaults.Layout> var documentLayout: DocumentLayout = DocumentLayout()
    /// Intervalos do expediente sem atendimentos (ex.: almoço).
    @Default<Defaults.EmptyList<WorkBreak>> var breaks: [WorkBreak] = []
    /// Buscar o endereço pelo CEP no ViaCEP (só o CEP é enviado).
    @Default<Defaults.True> var cepLookup: Bool = true
    /// Mensagem do botão do WhatsApp, com {nome}, {horário}, {data} e {local}. Vazio = a padrão.
    @Default<Defaults.EmptyString> var whatsAppTemplate: String = ""
    /// Agenda em tela cheia: dia, semana ou mês.
    @Default<Defaults.AgendaDay> var agendaMode: AgendaMode = .day

    // Novidades do Expediente.
    /// Como chamar quem é atendido.
    @Default<Defaults.ClientTermDefault> var clientTerm: ClientTerm = .client
    @Default<Defaults.AreaGeneral> var businessArea: BusinessArea = .general
    /// Local padrão dos atendimentos (endereço, "Online" ou link fixo).
    @Default<Defaults.EmptyString> var defaultLocation: String = ""
    /// Aviso no iPhone antes de cada atendimento, em minutos (0 = desligado).
    @Default<Defaults.Zero> var reminderMinutesBefore: Int = 0
    /// Pix para cobrança: chave, nome e cidade de quem recebe (o nome e a cidade vão no código copia e cola).
    @Default<Defaults.EmptyString> var pixKey: String = ""
    @Default<Defaults.EmptyString> var pixName: String = ""
    @Default<Defaults.EmptyString> var pixCity: String = ""
    /// Mensagem de cobrança pelo WhatsApp, com {nome}, {valor}, {data} e {pix}. Vazio = a padrão.
    @Default<Defaults.EmptyString> var chargeTemplate: String = ""

    /// Dia de atendimento. `weekday` segue o Calendar (1 = domingo … 7 = sábado).
    func isWorkDay(weekday: Int) -> Bool { workDays.contains(weekday - 1) }
}

/// Feriado cadastrado pelo profissional (estadual, municipal, férias ou recesso).
struct CustomHoliday: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String = ""
    var date: Date
    /// Repete todo ano no mesmo dia e mês.
    var yearly: Bool = true
}

/// Cabeçalho ou rodapé dos documentos: uma imagem (o timbre) e/ou um texto.
struct DocumentBand: Codable, Equatable, Hashable {
    var text: String = ""
    var imageID: UUID?
    @Default<Defaults.EmptyString> var imageName: String = ""
    /// Altura da imagem no papel, em milímetros.
    @Default<Defaults.ImageHeight> var imageHeightMm: Double = 22

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && imageID == nil }
}

struct DocumentLayout: Codable, Equatable, Hashable {
    var header = DocumentBand()
    var footer = DocumentBand()
}

/// Intervalo do expediente em que não se marcam atendimentos (ex.: almoço).
struct WorkBreak: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    @Default<Defaults.BreakName> var name: String = "Almoço"
    /// Minutos desde a meia-noite (720 = 12:00).
    @Default<Defaults.Noon> var startMinutes: Int = 12 * 60
    @Default<Defaults.OnePM> var endMinutes: Int = 13 * 60
    /// Dias da semana (0 = domingo … 6 = sábado). Vazio = todos os dias.
    @Default<Defaults.EmptyList<Int>> var days: [Int] = []

    var isValid: Bool { startMinutes >= 0 && endMinutes <= 24 * 60 && endMinutes > startMinutes }
    var title: String {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Intervalo" : t
    }
    /// "12:00–13:00".
    var timeRange: String { "\(WorkBreaks.clock(startMinutes))–\(WorkBreaks.clock(endMinutes))" }
    /// `weekday` do Calendar (1 = domingo).
    func applies(weekday: Int) -> Bool { days.isEmpty || days.contains(weekday - 1) }
}

enum PersonType: String, Codable, CaseIterable, Identifiable {
    case individual, company
    var id: String { rawValue }
    var label: String { self == .individual ? "Pessoa física (CPF)" : "Pessoa jurídica (CNPJ)" }
}

enum NfseEnvironment: String, Codable, CaseIterable, Identifiable, Hashable {
    case homologation, production
    var id: String { rawValue }
    var label: String { self == .production ? "Produção (notas com validade fiscal)" : "Homologação (testes, sem validade fiscal)" }
    var shortLabel: String { self == .production ? "Produção" : "Homologação" }
}

struct FiscalProfile: Codable, Equatable, Hashable {
    var personType: PersonType = .individual
    var legalName = ""
    var document = ""
    var municipalRegistration = ""
    var address = ""
    var city = ""
    var state = ""
    /// Item da lista de serviços (Lei Complementar 116/2003), ex.: "06.01 – Barbearia, cabeleireiros…".
    var serviceItem = ""
    var serviceDescription = ""
    var issRate = ""
    var taxRegime = ""

    // NFS-e Nacional (por enquanto, só Santo André/SP).
    @Default<Defaults.EmptyString> var street: String = ""
    @Default<Defaults.EmptyString> var number: String = ""
    @Default<Defaults.EmptyString> var complement: String = ""
    @Default<Defaults.EmptyString> var district: String = ""
    @Default<Defaults.EmptyString> var cep: String = ""
    @Default<Defaults.EmptyString> var fiscalPhone: String = ""
    @Default<Defaults.EmptyString> var fiscalEmail: String = ""
    /// Código IBGE do município do prestador (Santo André: 3547809).
    @Default<Defaults.SantoAndre> var municipalityCode: String = Nfse.santoAndre
    /// opSimpNac: 1 não optante, 2 MEI, 3 ME/EPP.
    @Default<Defaults.SimplesME> var simplesOption: Int = 3
    /// regApTribSN: 1 tributos federais e municipal pelo Simples Nacional.
    @Default<Defaults.One> var simplesRegime: Int = 1
    /// regEspTrib: 0 nenhum.
    @Default<Defaults.Zero> var specialRegime: Int = 0
    /// Código de tributação nacional (6 dígitos). Obrigatório para emitir: depende do serviço prestado.
    @Default<Defaults.EmptyString> var nationalTaxCode: String = ""
    @Default<Defaults.EmptyString> var nbsCode: String = ""
    @Default<Defaults.EmptyString> var approxTaxPercent: String = ""
    @Default<Defaults.Homologation> var environment: NfseEnvironment = .homologation
    /// Série da DPS. Use uma série diferente em cada aparelho.
    @Default<Defaults.SeriesOne> var dpsSeries: String = "1"
    /// Próximo número de DPS por ambiente e série (ex.: "2-1" → 15).
    @Default<Defaults.EmptyCounters> var nextDpsNumber: [String: Int64] = [:]
    /// Certificado usado na NFS-e (vazio = o certificado padrão).
    var certificateID: UUID?
    /// Descrição do serviço na nota; {data} vira a data do atendimento.
    @Default<Defaults.EmptyString> var nfseDescription: String = ""
}

// MARK: - Banco de dados

struct Database: Codable, Equatable {
    var version = 1
    var professional = Professional()
    var patients: [Patient] = []
    var appointments: [Appointment] = []
    var notes: [SessionNote] = []
    var tags: [Tag] = Tag.presets
    var settings = AppSettings()
    var fiscal = FiscalProfile()
    /// Certificados digitais ICP-Brasil do profissional (para a NFS-e).
    @Default<Defaults.EmptyList<CertificateEntry>> var certificates: [CertificateEntry] = []
    @Default<Defaults.EmptyList<ServicePackage>> var packages: [ServicePackage] = []
    @Default<Defaults.EmptyList<Expense>> var expenses: [Expense] = []

    func patient(_ id: UUID?) -> Patient? {
        guard let id else { return nil }
        return patients.first { $0.id == id }
    }

    func tag(_ id: UUID?) -> Tag? {
        guard let id else { return nil }
        return tags.first { $0.id == id }
    }

    func appointment(_ id: UUID?) -> Appointment? {
        guard let id else { return nil }
        return appointments.first { $0.id == id }
    }

    func package(_ id: UUID?) -> ServicePackage? {
        guard let id else { return nil }
        return packages.first { $0.id == id }
    }

    func notes(for appointmentID: UUID) -> [SessionNote] {
        notes.filter { $0.appointmentID == appointmentID }
    }

    func appointments(of patientID: UUID) -> [Appointment] {
        appointments.filter { $0.patientID == patientID }.sorted { $0.start < $1.start }
    }

    func appointments(on day: Date, calendar: Calendar = .current) -> [Appointment] {
        appointments.filter { calendar.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
    }

    func appointments(in interval: DateInterval) -> [Appointment] {
        appointments.filter { $0.start >= interval.start && $0.start < interval.end }.sorted { $0.start < $1.start }
    }

    func lastSession(of patientID: UUID, before now: Date = Date()) -> Appointment? {
        appointments(of: patientID).last { $0.start <= now && !$0.isCancelled }
    }

    func nextSession(of patientID: UUID, after now: Date = Date()) -> Appointment? {
        appointments(of: patientID).first { $0.start > now && !$0.isCancelled }
    }

    /// Valor do atendimento: o do próprio atendimento, senão o da tag, senão o do cliente, senão o padrão.
    /// Retorno sem valor e atendimento de pacote não têm custo.
    func price(of appointment: Appointment) -> Int {
        if Billing.isNoCharge(appointment, in: self) { return 0 }
        return appointment.amountCents
            ?? tagPrice(tag(appointment.tagID))
            ?? patient(appointment.patientID)?.sessionPriceCents
            ?? settings.defaultPriceCents
            ?? 0
    }

    /// Valor padrão da tag, ou nil quando a chave "valor por cliente" está ligada (aí só vale o do cadastro do cliente).
    func tagPrice(_ tag: Tag?) -> Int? {
        settings.priceByClient ? nil : tag?.defaultPriceCents
    }

    private func namedTag(_ chosen: UUID?, _ presetName: String) -> Tag? {
        if let chosen { return tag(chosen) }
        let target = NameMatcher.normalize(presetName)
        return tags.first { NameMatcher.normalize($0.name) == target }
    }

    /// A tag do primeiro atendimento (escolhida em Ajustes, ou a de nome "Primeiro atendimento").
    func firstSessionTag() -> Tag? { namedTag(settings.firstSessionTagID, Tag.firstSessionPresetName) }

    /// A tag do retorno (escolhida em Ajustes, ou a de nome "Retorno").
    func returnTag() -> Tag? { namedTag(settings.returnTagID, Tag.returnPresetName) }

    /// Duração sugerida para um atendimento com esta tag: a da própria tag; no primeiro atendimento, a de Ajustes;
    /// senão a duração padrão.
    func duration(for tagID: UUID?) -> Int {
        if let d = tag(tagID)?.durationMinutes, d > 0 { return d }
        if let first = firstSessionTag(), tagID == first.id { return settings.firstSessionDurationMinutes }
        return settings.defaultDurationMinutes
    }

    /// Local do atendimento: o dele, senão o padrão de Ajustes.
    func location(of a: Appointment) -> String {
        let own = a.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? settings.defaultLocation.trimmingCharacters(in: .whitespacesAndNewlines) : own
    }

    var activePatients: [Patient] {
        patients.filter { !$0.archived }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
