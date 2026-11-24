import Foundation

/// Campos com máscara: o app pontua enquanto se digita e limita a quantidade de caracteres.
enum MaskKind {
    case phone, cpf, cnpj, cep
}

/// Máscaras de telefone, CPF, CNPJ e CEP (as mesmas regras da versão para Windows).
enum Masks {
    static let cpfDigits = 11
    static let cnpjLength = 14
    static let cepDigits = 8
    /// Código do Brasil, que já vem escrito no telefone do paciente.
    static let phonePrefix = "+55"

    static func digits(_ s: String?) -> String { String((s ?? "").filter(\.isASCIIDigit)) }

    static func format(_ kind: MaskKind, _ raw: String?) -> String {
        switch kind {
        case .phone: return phone(raw)
        case .cpf: return cpf(raw)
        case .cnpj: return cnpj(raw)
        case .cep: return cep(raw)
        }
    }

    /// Preenche o modelo (# = caractere) só até onde há caracteres.
    private static func apply(_ chars: String, _ pattern: String) -> String {
        var out = ""
        var it = chars.makeIterator()
        var next = it.next()
        for p in pattern {
            guard let c = next else { break }
            if p == "#" {
                out.append(c)
                next = it.next()
            } else {
                out.append(p)
            }
        }
        return out
    }

    /// 000.000.000-00
    static func cpf(_ raw: String?) -> String { apply(String(digits(raw).prefix(cpfDigits)), "###.###.###-##") }

    /// 00000-000
    static func cep(_ raw: String?) -> String { apply(String(digits(raw).prefix(cepDigits)), "#####-###") }

    /// 00.000.000/0000-00. Desde julho de 2026 (IN RFB nº 2.229/2024) as 12 primeiras posições podem ser letras.
    static func cnpj(_ raw: String?) -> String { apply(cnpjChars(raw), "##.###.###/####-##") }

    static func cnpjChars(_ raw: String?) -> String {
        var out = ""
        for c0 in raw ?? "" {
            if out.count >= cnpjLength { break }
            let c = Character(c0.uppercased())
            if out.count < 12 ? (c.isASCIIDigit || ("A"..."Z").contains(c)) : c.isASCIIDigit { out.append(c) }
        }
        return out
    }

    /// +55 (11) 98765-4321, (11) 98765-4321 ou 98765-4321. Com o DDD também cabe o fixo: (11) 3456-7890.
    static func phone(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var plus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        var d = digits(raw)
        if !plus {
            while d.hasPrefix("0") { d.removeFirst() }
            if d.count > 11 && d.hasPrefix("55") { plus = true }
        }
        if plus {
            if d.isEmpty { return "+" }
            if !d.hasPrefix("5") || (d.count >= 2 && !d.hasPrefix("55")) { return "+" + String(d.prefix(15)) }
            d = String(d.prefix(13))
            if d.count <= 2 { return "+" + d }
            return "+" + String(d.prefix(2)) + " " + withDDD(String(d.dropFirst(2)))
        }
        d = String(d.prefix(11))
        return d.count <= 9 && d.hasPrefix("9") ? apply(d, "#####-####") : withDDD(d)
    }

    private static func withDDD(_ d: String) -> String {
        if d.isEmpty { return "" }
        if d.count <= 2 { return "(" + d }
        let number = String(d.dropFirst(2))
        let formatted: String
        if number.count <= 4 {
            formatted = number
        } else if number.count <= 8 {
            formatted = String(number.prefix(4)) + "-" + String(number.dropFirst(4))
        } else {
            formatted = String(number.prefix(5)) + "-" + String(number.dropFirst(5))
        }
        return "(\(d.prefix(2))) \(formatted)"
    }

    /// O campo que ficou só com o código do país ("+55") conta como vazio.
    static func phoneToSave(_ text: String?) -> String {
        let t = (text ?? "").trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("+") else { return t }
        let d = digits(t)
        return d.isEmpty || d == "55" ? "" : t
    }

    /// Valor inicial do telefone do paciente: o que já existe ou, se estiver vazio, o +55.
    static func phoneWithPrefix(_ existing: String?) -> String {
        let t = (existing ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? phonePrefix : t
    }

    static func isCompletePhone(_ text: String?) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let plus = text.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        var d = digits(text)
        if plus { return d.hasPrefix("55") ? [12, 13].contains(d.count) : (8...15).contains(d.count) }
        while d.hasPrefix("0") { d.removeFirst() }
        return (d.count == 9 && d.hasPrefix("9")) || [10, 11].contains(d.count)
    }

    static func isValidCPF(_ cpf: String?) -> Bool {
        let d = digits(cpf).compactMap { $0.wholeNumberValue }
        guard d.count == 11, Set(d).count > 1 else { return false }
        func check(_ len: Int) -> Int {
            var sum = 0
            for i in 0..<len { sum += d[i] * (len + 1 - i) }
            let r = (sum * 10) % 11
            return r == 10 ? 0 : r
        }
        return check(9) == d[9] && check(10) == d[10]
    }

    /// Dígitos verificadores do CNPJ numérico ou alfanumérico: cada caractere vale o código ASCII menos 48.
    static func isValidCNPJ(_ cnpj: String?) -> Bool {
        let c = Array(cnpjChars(cnpj))
        guard c.count == cnpjLength, Set(c).count > 1 else { return false }
        func value(_ ch: Character) -> Int { Int(ch.asciiValue ?? 48) - 48 }
        func digit(_ len: Int) -> Int {
            let w = len == 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
            var sum = 0
            for i in 0..<len { sum += value(c[i]) * w[i] }
            let r = sum % 11
            return r < 2 ? 0 : 11 - r
        }
        return digit(12) == value(c[12]) && digit(13) == value(c[13])
    }

    static func hasLetters(_ cnpj: String?) -> Bool { cnpjChars(cnpj).contains { $0.isASCIILetter } }

    /// Problema do valor já completo (nil = certo ou ainda incompleto).
    static func problem(_ kind: MaskKind, _ text: String?) -> String? {
        switch kind {
        case .cpf:
            return digits(text).count == cpfDigits && !isValidCPF(text) ? "CPF inválido: os dígitos verificadores não conferem." : nil
        case .cnpj:
            return cnpjChars(text).count == cnpjLength && !isValidCNPJ(text) ? "CNPJ inválido: os dígitos verificadores não conferem." : nil
        default:
            return nil
        }
    }
}

/// Endereço em partes (o CEP vem primeiro e preenche o resto).
struct PostalAddress: Codable, Equatable, Hashable {
    @Default<Defaults.EmptyString> var cep: String = ""
    @Default<Defaults.EmptyString> var street: String = ""
    @Default<Defaults.EmptyString> var number: String = ""
    @Default<Defaults.EmptyString> var complement: String = ""
    @Default<Defaults.EmptyString> var district: String = ""
    @Default<Defaults.EmptyString> var city: String = ""
    @Default<Defaults.EmptyString> var state: String = ""

    var isEmpty: Bool {
        [cep, street, number, complement, district, city, state].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "Rua Exemplo, 100, sala 12 – Centro – Santo André/SP – CEP 09010-000".
    func compose() -> String {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let first = [street, number, complement].map(t).filter { !$0.isEmpty }.joined(separator: ", ")
        let c = t(city), uf = t(state).uppercased()
        let cityUf = !c.isEmpty && !uf.isEmpty ? "\(c)/\(uf)" : (!c.isEmpty ? c : uf)
        let cepText = Masks.digits(cep).count == Masks.cepDigits ? "CEP " + Masks.cep(cep) : t(cep)
        return [first, t(district), cityUf, cepText].filter { !$0.isEmpty }.joined(separator: " – ")
    }

    /// Partes de um endereço antigo (um texto só): tudo vai para o logradouro; um CEP no meio vai para o campo do CEP.
    static func fromLegacy(_ text: String?) -> PostalAddress {
        let t = (text ?? "").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        var a = PostalAddress()
        a.street = t
        let pattern = #"(?:CEP[:\s]*)?\b(\d{5})-?(\d{3})\b"#
        if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let r1 = Range(m.range(at: 1), in: t), let r2 = Range(m.range(at: 2), in: t), let all = Range(m.range, in: t) {
            a.cep = Masks.cep(String(t[r1]) + String(t[r2]))
            let rest = String(t[..<all.lowerBound]) + String(t[all.upperBound...])
            a.street = rest.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",-–;"))
                .trimmingCharacters(in: .whitespaces)
        }
        return a
    }
}
