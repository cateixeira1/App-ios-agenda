import Foundation

/// Valor padrão de um campo que pode faltar no arquivo (dados gravados por uma versão anterior).
protocol DefaultValue {
    associatedtype Value: Codable & Hashable
    static var defaultValue: Value { get }
}

/// Campo com valor padrão: se a chave não existir (ou vier nula) no JSON, usa o padrão em vez de dar erro.
/// O JSONDecoder do Swift exige todas as chaves dos campos não opcionais; com isto, os campos novos
/// abrem os arquivos antigos sem perder nada.
@propertyWrapper
struct Default<D: DefaultValue>: Codable, Hashable {
    var wrappedValue: D.Value

    init(wrappedValue: D.Value) { self.wrappedValue = wrappedValue }
    init() { wrappedValue = D.defaultValue }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? D.defaultValue : try c.decode(D.Value.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<D>(_ type: Default<D>.Type, forKey key: Key) throws -> Default<D> {
        try decodeIfPresent(type, forKey: key) ?? Default()
    }
}

// MARK: - Padrões usados nos modelos

enum Defaults {
    enum EmptyString: DefaultValue { static var defaultValue: String { "" } }
    enum False: DefaultValue { static var defaultValue: Bool { false } }
    enum True: DefaultValue { static var defaultValue: Bool { true } }
    enum Zero: DefaultValue { static var defaultValue: Int { 0 } }
    enum One: DefaultValue { static var defaultValue: Int { 1 } }
    enum EmptyList<T: Codable & Hashable>: DefaultValue { static var defaultValue: [T] { [] } }
    enum EmptyCounters: DefaultValue { static var defaultValue: [String: Int64] { [:] } }
    enum FirstSessionMinutes: DefaultValue { static var defaultValue: Int { 60 } }
    enum ReturnValue: DefaultValue { static var defaultValue: Int { 30 } }
    enum ReturnUnitDays: DefaultValue { static var defaultValue: ReturnUnit { .days } }
    /// Segunda a sexta (0 = domingo … 6 = sábado).
    enum WeekdaysMonFri: DefaultValue { static var defaultValue: [Int] { [1, 2, 3, 4, 5] } }
    enum Layout: DefaultValue { static var defaultValue: DocumentLayout { DocumentLayout() } }
    enum ImageHeight: DefaultValue { static var defaultValue: Double { 22 } }
    enum SantoAndre: DefaultValue { static var defaultValue: String { Nfse.santoAndre } }
    enum SimplesME: DefaultValue { static var defaultValue: Int { 3 } }
    enum Homologation: DefaultValue { static var defaultValue: NfseEnvironment { .homologation } }
    enum SeriesOne: DefaultValue { static var defaultValue: String { "1" } }
    enum NfseUnknown: DefaultValue { static var defaultValue: NfseState { .unknown } }
    enum Distant: DefaultValue { static var defaultValue: Date { Date(timeIntervalSinceReferenceDate: 0) } }
    enum CertA1: DefaultValue { static var defaultValue: CertificateKind { .a1 } }
    enum AgendaDay: DefaultValue { static var defaultValue: AgendaMode { .day } }
    enum BreakName: DefaultValue { static var defaultValue: String { "Almoço" } }
    enum Noon: DefaultValue { static var defaultValue: Int { 12 * 60 } }
    enum OnePM: DefaultValue { static var defaultValue: Int { 13 * 60 } }
    enum RichEmpty: DefaultValue { static var defaultValue: RichText { RichText() } }
    enum ClientTermDefault: DefaultValue { static var defaultValue: ClientTerm { .client } }
    enum AreaGeneral: DefaultValue { static var defaultValue: BusinessArea { .general } }
}
