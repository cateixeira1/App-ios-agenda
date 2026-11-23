import Foundation

/// Pix "copia e cola" estático (BR Code), gerado no próprio aparelho, sem banco nem servidor.
/// Segue o Manual de Padrões para Iniciação do Pix (Banco Central): campos EMV com tamanho de 2 dígitos e CRC16 no fim.
/// O código leva a chave, o nome e a cidade de quem recebe e, se informado, o valor. Quem paga confere tudo no
/// app do banco antes de confirmar.
enum Pix {
    enum KeyKind: Equatable {
        case cpf, cnpj, phone, email, random
        var label: String {
            switch self {
            case .cpf: return "CPF"
            case .cnpj: return "CNPJ"
            case .phone: return "telefone"
            case .email: return "e-mail"
            case .random: return "chave aleatória"
            }
        }
    }

    /// Reconhece o tipo da chave e devolve como ela vai no código (ou nil, se não parece uma chave Pix).
    static func normalizeKey(_ raw: String) -> (key: String, kind: KeyKind)? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.contains("@") {
            let e = t.lowercased()
            return e.count <= 77 && e.split(separator: "@").count == 2 ? (e, .email) : nil
        }
        let lower = t.lowercased()
        if lower.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil {
            return (lower, .random)
        }
        let d = t.filter(\.isASCIIDigit)
        if t.hasPrefix("+") {
            return (8...15).contains(d.count) ? ("+" + d, .phone) : nil
        }
        if d.count == 14 { return (d, .cnpj) }
        if d.count == 11 && isValidCpf(d) { return (d, .cpf) }
        if d.count == 10 || d.count == 11 { return ("+55" + d, .phone) }
        if (d.count == 12 || d.count == 13) && d.hasPrefix("55") { return ("+" + d, .phone) }
        return nil
    }

    static func isValidCpf(_ digits: String) -> Bool {
        let n = digits.compactMap(\.wholeNumberValue)
        guard n.count == 11, Set(n).count > 1 else { return false }
        func check(_ upTo: Int) -> Int {
            var sum = 0
            for i in 0..<upTo { sum += n[i] * (upTo + 1 - i) }
            let r = (sum * 10) % 11
            return r == 10 ? 0 : r
        }
        return check(9) == n[9] && check(10) == n[10]
    }

    /// Texto só com letras sem acento, números, espaço e alguns sinais, cortado no tamanho máximo do campo.
    static func plain(_ s: String, max: Int) -> String {
        let folded = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
        let kept = folded.filter { $0.isASCII && ($0.isLetter || $0.isNumber || " .-&".contains($0)) }
        return String(kept.trimmingCharacters(in: .whitespaces).prefix(max)).trimmingCharacters(in: .whitespaces)
    }

    private static func field(_ id: String, _ value: String) -> String {
        let count = value.utf8.count
        return id + (count < 10 ? "0\(count)" : "\(count)") + value
    }

    /// CRC16-CCITT (polinômio 0x1021, valor inicial 0xFFFF), em 4 dígitos hexadecimais maiúsculos.
    static func crc16(_ s: String) -> String {
        var crc: UInt16 = 0xFFFF
        for byte in s.utf8 {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return String(format: "%04X", crc)
    }

    /// O código copia e cola. nil se a chave, o nome ou a cidade faltarem.
    static func payload(key rawKey: String, name: String, city: String, amountCents: Int?, txid: String = "***") -> String? {
        guard let (key, _) = normalizeKey(rawKey) else { return nil }
        let n = plain(name, max: 25)
        let c = plain(city, max: 15)
        guard !n.isEmpty, !c.isEmpty else { return nil }
        var s = field("00", "01")
        s += field("26", field("00", "br.gov.bcb.pix") + field("01", key))
        s += field("52", "0000")
        s += field("53", "986")
        if let amountCents, amountCents > 0 {
            s += field("54", String(format: "%d.%02d", amountCents / 100, amountCents % 100))
        }
        s += field("58", "BR")
        s += field("59", n)
        s += field("60", c)
        let cleanTx = String(txid.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "*") }.prefix(25))
        s += field("62", field("05", cleanTx.isEmpty ? "***" : cleanTx))
        s += "6304"
        return s + crc16(s)
    }

    /// O código com os dados de Ajustes, ou nil quando o Pix não está configurado.
    static func payload(_ settings: AppSettings, amountCents: Int?) -> String? {
        payload(key: settings.pixKey, name: settings.pixName, city: settings.pixCity, amountCents: amountCents)
    }

    static func isConfigured(_ settings: AppSettings) -> Bool { payload(settings, amountCents: nil) != nil }
}
