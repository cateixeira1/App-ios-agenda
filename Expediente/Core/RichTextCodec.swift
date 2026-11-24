import UIKit

/// Trecho de texto com a mesma formatação.
struct TextRun: Codable, Equatable {
    var text: String
    /// Família da fonte; `nil` é a fonte do sistema.
    var font: String?
    var size: Double
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    /// Cor em "#RRGGBB"; `nil` segue o modo claro/escuro.
    var color: String?
    /// NSTextAlignment.rawValue; `nil` é o alinhamento natural.
    var align: Int?
}

/// Fontes oferecidas no editor (todas já vêm no iOS).
struct EditorFont: Identifiable, Hashable {
    let label: String
    /// `nil` = fonte do sistema.
    let family: String?
    var id: String { family ?? "system" }

    static let all: [EditorFont] = [
        EditorFont(label: "Sistema (SF Pro)", family: nil),
        EditorFont(label: "New York", family: "New York"),
        EditorFont(label: "Helvetica Neue", family: "Helvetica Neue"),
        EditorFont(label: "Avenir Next", family: "Avenir Next"),
        EditorFont(label: "Arial", family: "Arial"),
        EditorFont(label: "Georgia", family: "Georgia"),
        EditorFont(label: "Times New Roman", family: "Times New Roman"),
        EditorFont(label: "Palatino", family: "Palatino"),
        EditorFont(label: "Baskerville", family: "Baskerville"),
        EditorFont(label: "Charter", family: "Charter"),
        EditorFont(label: "Iowan Old Style", family: "Iowan Old Style"),
        EditorFont(label: "Gill Sans", family: "Gill Sans"),
        EditorFont(label: "Optima", family: "Optima"),
        EditorFont(label: "Futura", family: "Futura"),
        EditorFont(label: "Menlo", family: "Menlo"),
    ]
}

/// Converte o texto do editor (NSAttributedString) para o formato guardado e de volta.
/// Formato próprio em JSON porque o RTF troca a fonte do sistema por Times ao reabrir.
enum RichTextCodec {
    static let baseFontSize: CGFloat = 17

    /// Padrão do texto novo: Arial 17, justificado (igual à versão para Windows).
    static let defaultFamily = "Arial"

    static var defaultFont: UIFont { font(family: defaultFamily, size: baseFontSize, bold: false, italic: false) }

    static var defaultParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .justified
        return p
    }

    static var defaultAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: UIColor.label, .paragraphStyle: defaultParagraph]
    }

    static func isSystemFont(_ font: UIFont) -> Bool {
        font.familyName.hasPrefix(".") || font.fontName.hasPrefix(".")
    }

    /// Nome guardado para a fonte: `nil` para a do sistema, "New York" para a serifada do sistema.
    static func familyKey(_ font: UIFont) -> String? {
        if font.familyName.contains("New York") || font.fontName.contains("NewYork") { return "New York" }
        return isSystemFont(font) ? nil : font.familyName
    }

    // MARK: - Codificar

    static func runs(of text: NSAttributedString) -> [TextRun] {
        var runs: [TextRun] = []
        let full = NSRange(location: 0, length: text.length)
        let ns = text.string as NSString
        text.enumerateAttributes(in: full) { attrs, range, _ in
            let font = (attrs[.font] as? UIFont) ?? UIFont.systemFont(ofSize: baseFontSize)
            let traits = font.fontDescriptor.symbolicTraits
            var run = TextRun(text: ns.substring(with: range), font: familyKey(font), size: Double(font.pointSize))
            run.bold = traits.contains(.traitBold)
            run.italic = traits.contains(.traitItalic)
            run.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            run.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            if let c = attrs[.foregroundColor] as? UIColor, !isDefaultTextColor(c) { run.color = c.hexString }
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle, p.alignment != .natural { run.align = p.alignment.rawValue }
            if var last = runs.last, last.sameStyle(as: run) {
                last.text += run.text
                runs[runs.count - 1] = last
            } else {
                runs.append(run)
            }
        }
        return runs
    }

    static func encode(_ text: NSAttributedString) -> RichText {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(runs(of: text))) ?? Data()
        return RichText(format: data, plain: text.string)
    }

    // MARK: - Decodificar

    static func decode(_ rich: RichText) -> NSAttributedString {
        guard !rich.format.isEmpty, let runs = try? JSONDecoder().decode([TextRun].self, from: rich.format) else {
            return NSAttributedString(string: rich.plain, attributes: defaultAttributes)
        }
        let out = NSMutableAttributedString()
        for run in runs { out.append(NSAttributedString(string: run.text, attributes: attributes(for: run))) }
        return out
    }

    static func attributes(for run: TextRun) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(family: run.font, size: CGFloat(run.size), bold: run.bold, italic: run.italic),
            .foregroundColor: run.color.flatMap(UIColor.init(hex:)) ?? UIColor.label,
        ]
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let a = run.align, let alignment = NSTextAlignment(rawValue: a) {
            let p = NSMutableParagraphStyle()
            p.alignment = alignment
            attrs[.paragraphStyle] = p
        }
        return attrs
    }

    static func font(family: String?, size: CGFloat, bold: Bool, italic: Bool) -> UIFont {
        let base: UIFont
        if family == "New York" {
            let system = UIFont.systemFont(ofSize: size)
            base = system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? system
        } else if let family {
            let d = UIFontDescriptor(fontAttributes: [.family: family])
            base = UIFont(descriptor: d, size: size)
        } else {
            base = UIFont.systemFont(ofSize: size)
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let d = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: d, size: size)
    }

    static func plain(_ string: String) -> RichText {
        encode(NSAttributedString(string: string, attributes: defaultAttributes))
    }

    static func isDefaultTextColor(_ c: UIColor) -> Bool {
        if c == UIColor.label { return true }
        let light = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = c.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        return light.hexString == "#000000" && dark.hexString == "#FFFFFF"
    }

    /// Versão para impressão/PDF: cores que seguem o tema viram as do modo claro.
    static func forPrinting(_ text: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let range = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.foregroundColor, in: range) { value, sub, _ in
            let color = (value as? UIColor) ?? .label
            m.addAttribute(.foregroundColor, value: color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), range: sub)
        }
        return m
    }
}

extension TextRun {
    func sameStyle(as o: TextRun) -> Bool {
        font == o.font && size == o.size && bold == o.bold && italic == o.italic && underline == o.underline
            && strike == o.strike && color == o.color && align == o.align
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        func c(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}
