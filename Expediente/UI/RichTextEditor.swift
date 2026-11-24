import SwiftUI
import UIKit

/// Editor de texto com as ferramentas mais usadas. Cresce conforme o texto.
struct RichTextEditor: View {
    let initial: RichText
    var placeholder = "Escreva aqui…"
    var minHeight: CGFloat = 160
    var editable = true
    var autoFocus = false
    let onChange: (RichText) -> Void

    @State private var height: CGFloat = 0

    var body: some View {
        RichTextViewRepresentable(initial: initial, placeholder: placeholder, editable: editable, autoFocus: autoFocus,
                                  height: $height, onChange: onChange)
            .frame(height: max(minHeight, height))
    }
}

struct RichTextViewRepresentable: UIViewRepresentable {
    let initial: RichText
    let placeholder: String
    let editable: Bool
    let autoFocus: Bool
    @Binding var height: CGFloat
    let onChange: (RichText) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, height: $height) }

    func makeUIView(context: Context) -> GrowingTextView {
        let tv = GrowingTextView()
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        tv.attributedText = RichTextCodec.decode(initial)
        tv.typingAttributes = RichTextCodec.defaultAttributes
        tv.isEditable = editable
        tv.isSelectable = true
        tv.delegate = context.coordinator
        tv.adjustsFontForContentSizeCategory = false
        tv.dataDetectorTypes = []
        tv.allowsEditingTextAttributes = true
        tv.placeholder = placeholder
        tv.onHeight = { [weak coordinator = context.coordinator] h in coordinator?.report(height: h) }
        if editable {
            tv.inputAccessoryView = FormattingBar(textView: tv, coordinator: context.coordinator)
        }
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if autoFocus && editable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tv.becomeFirstResponder() }
        }
        return tv
    }

    func updateUIView(_ tv: GrowingTextView, context: Context) {
        context.coordinator.onChange = onChange
        if tv.isEditable != editable { tv.isEditable = editable }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onChange: (RichText) -> Void
        var height: Binding<CGFloat>

        init(onChange: @escaping (RichText) -> Void, height: Binding<CGFloat>) {
            self.onChange = onChange
            self.height = height
        }

        func report(height h: CGFloat) {
            guard abs(height.wrappedValue - h) > 0.5 else { return }
            DispatchQueue.main.async { self.height.wrappedValue = h }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView.inputAccessoryView as? FormattingBar)?.refreshState()
        }

        func textViewDidChange(_ textView: UITextView) {
            (textView.inputAccessoryView as? FormattingBar)?.refreshState()
            (textView as? GrowingTextView)?.refreshPlaceholder()
            textView.invalidateIntrinsicContentSize()
            (textView as? GrowingTextView)?.reportHeight()
            onChange(RichTextCodec.encode(textView.attributedText))
        }

        /// Continua listas ao apertar Enter; Enter numa linha de lista vazia encerra a lista.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            let ns = textView.text as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
            guard let prefix = ListFormatting.prefix(of: line) else { return true }
            let storage = textView.textStorage
            if line == prefix.marker {
                // Linha vazia: tira o marcador.
                storage.replaceCharacters(in: NSRange(location: paragraph.location, length: (prefix.marker as NSString).length), with: "")
                textView.selectedRange = NSRange(location: paragraph.location, length: 0)
            } else {
                let next = "\n" + prefix.next
                let attrs = textView.typingAttributes
                storage.replaceCharacters(in: range, with: NSAttributedString(string: next, attributes: attrs))
                textView.selectedRange = NSRange(location: range.location + (next as NSString).length, length: 0)
            }
            textViewDidChange(textView)
            return false
        }
    }
}

final class GrowingTextView: UITextView {
    var onHeight: ((CGFloat) -> Void)?
    private let placeholderLabel = UILabel()
    var placeholder: String = "" {
        didSet { placeholderLabel.text = placeholder; refreshPlaceholder() }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: RichTextCodec.baseFontSize)
        placeholderLabel.numberOfLines = 0
        addSubview(placeholderLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = textContainerInset
        let pad = textContainer.lineFragmentPadding
        placeholderLabel.frame = CGRect(x: inset.left + pad, y: inset.top, width: bounds.width - inset.left - inset.right - 2 * pad, height: 24)
        reportHeight()
    }

    func reportHeight() {
        guard bounds.width > 0 else { return }
        let h = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        onHeight?(ceil(h))
    }

    func refreshPlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty || !isEditable
    }

    override var attributedText: NSAttributedString! {
        didSet { refreshPlaceholder() }
    }
}

// MARK: - Listas

enum ListFormatting {
    static let bullet = "• "

    struct Prefix { let marker: String; let next: String }

    static func prefix(of line: String) -> Prefix? {
        if line.hasPrefix(bullet) { return Prefix(marker: bullet, next: bullet) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, let n = Int(digits), line.dropFirst(digits.count).hasPrefix(". ") {
            return Prefix(marker: "\(n). ", next: "\(n + 1). ")
        }
        return nil
    }
}

// MARK: - Barra de formatação

final class FormattingBar: UIInputView {
    private weak var textView: UITextView?
    private weak var coordinator: RichTextViewRepresentable.Coordinator?

    init(textView: UITextView, coordinator: RichTextViewRepresentable.Coordinator) {
        self.textView = textView
        self.coordinator = coordinator
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não usado") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 46) }

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 40),
        ])

        boldButton = button("bold", "Negrito") { [weak self] in self?.toggleTrait(bold: true); self?.refreshState() }
        italicButton = button("italic", "Itálico") { [weak self] in self?.toggleTrait(bold: false); self?.refreshState() }
        underlineButton = button("underline", "Sublinhado") { [weak self] in self?.toggleLine(.underlineStyle); self?.refreshState() }
        strikeButton = button("strikethrough", "Tachado") { [weak self] in self?.toggleLine(.strikethroughStyle); self?.refreshState() }
        for b in [boldButton, italicButton, underlineButton, strikeButton] { if let b { stack.addArrangedSubview(b) } }
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(menuButton("textformat", "Fonte", fontMenu()))
        stack.addArrangedSubview(menuButton("textformat.size", "Tamanho", sizeMenu()))
        stack.addArrangedSubview(menuButton("paintpalette", "Cor do texto", colorMenu()))
        stack.addArrangedSubview(menuButton("text.alignleft", "Alinhamento", alignMenu()))
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(button("list.bullet", "Lista com marcadores") { [weak self] in self?.toggleList(numbered: false) })
        stack.addArrangedSubview(button("list.number", "Lista numerada") { [weak self] in self?.toggleList(numbered: true) })
        stack.addArrangedSubview(button("textformat.alt", "Título") { [weak self] in self?.toggleHeading() })
        stack.addArrangedSubview(button("eraser", "Limpar formatação") { [weak self] in self?.clearFormatting() })
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(button("arrow.uturn.backward", "Desfazer") { [weak self] in self?.textView?.undoManager?.undo(); self?.changed() })
        stack.addArrangedSubview(button("keyboard.chevron.compact.down", "Fechar teclado") { [weak self] in self?.textView?.resignFirstResponder() })
    }

    private var boldButton: UIButton?
    private var italicButton: UIButton?
    private var underlineButton: UIButton?
    private var strikeButton: UIButton?

    /// Os botões de negrito, itálico, sublinhado e tachado ficam com fundo mais escuro enquanto estão ligados
    /// no ponto do cursor (ou no começo da seleção).
    func refreshState() {
        guard let tv = textView else { return }
        let attrs: [NSAttributedString.Key: Any]
        if tv.selectedRange.length == 0 || tv.textStorage.length == 0 {
            attrs = tv.typingAttributes
        } else {
            attrs = tv.textStorage.attributes(at: min(tv.selectedRange.location, tv.textStorage.length - 1), effectiveRange: nil)
        }
        let traits = (attrs[.font] as? UIFont)?.fontDescriptor.symbolicTraits ?? []
        func mark(_ b: UIButton?, _ on: Bool) {
            b?.backgroundColor = on ? UIColor.systemGray3 : .clear
            b?.layer.cornerRadius = 8
            b?.accessibilityTraits = on ? [.button, .selected] : .button
        }
        mark(boldButton, traits.contains(.traitBold))
        mark(italicButton, traits.contains(.traitItalic))
        mark(underlineButton, ((attrs[.underlineStyle] as? Int) ?? 0) != 0)
        mark(strikeButton, ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        b.accessibilityLabel = label
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func menuButton(_ symbol: String, _ label: String, _ menu: UIMenu) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)), for: .normal)
        b.accessibilityLabel = label
        b.menu = menu
        b.showsMenuAsPrimaryAction = true
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 40).isActive = true
        return b
    }

    private func separator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    private func fontMenu() -> UIMenu {
        UIMenu(title: "Fonte", children: EditorFont.all.map { f in
            UIAction(title: f.label) { [weak self] _ in
                self?.transformFonts { old in
                    let t = old.fontDescriptor.symbolicTraits
                    return RichTextCodec.font(family: f.family, size: old.pointSize, bold: t.contains(.traitBold), italic: t.contains(.traitItalic))
                }
            }
        })
    }

    private func sizeMenu() -> UIMenu {
        UIMenu(title: "Tamanho", children: [12, 14, 15, 17, 20, 24, 28].map { size in
            UIAction(title: "\(size) pt") { [weak self] _ in
                self?.transformFonts { $0.withSize(CGFloat(size)) }
            }
        })
    }

    private func colorMenu() -> UIMenu {
        let colors: [(String, UIColor)] = [
            ("Padrão", .label),
            ("Ameixa", UIColor(hex: "#5C2D4F")!),
            ("Vermelho", UIColor(hex: "#D32F2F")!),
            ("Azul", UIColor(hex: "#1565C0")!),
            ("Verde", UIColor(hex: "#2E7D32")!),
            ("Laranja", UIColor(hex: "#C25E00")!),
            ("Cinza", UIColor(hex: "#6B6B6B")!),
        ]
        return UIMenu(title: "Cor do texto", children: colors.map { name, color in
            UIAction(title: name, image: UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.setAttribute(.foregroundColor, color)
            }
        })
    }

    private func alignMenu() -> UIMenu {
        let options: [(String, String, NSTextAlignment)] = [
            ("À esquerda", "text.alignleft", .left),
            ("Centralizado", "text.aligncenter", .center),
            ("À direita", "text.alignright", .right),
            ("Justificado", "text.justify", .justified),
        ]
        return UIMenu(title: "Alinhamento", children: options.map { title, symbol, alignment in
            UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in self?.setAlignment(alignment) }
        })
    }

    // MARK: - Operações

    private func changed() {
        guard let tv = textView else { return }
        coordinator?.textViewDidChange(tv)
    }

    private var defaultFont: UIFont { RichTextCodec.defaultFont }

    /// Aplica a mudança na seleção; sem seleção, vale para o que for digitado a seguir.
    private func transformFonts(_ transform: (UIFont) -> UIFont) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.font] = transform((attrs[.font] as? UIFont) ?? defaultFont)
            tv.typingAttributes = attrs
            return
        }
        let storage = tv.textStorage
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            storage.addAttribute(.font, value: transform((value as? UIFont) ?? defaultFont), range: sub)
        }
        storage.endEditing()
        tv.selectedRange = range
        changed()
    }

    private func toggleTrait(bold: Bool) {
        guard let tv = textView else { return }
        let trait: UIFontDescriptor.SymbolicTraits = bold ? .traitBold : .traitItalic
        let range = tv.selectedRange
        var allHave = true
        if range.length == 0 {
            allHave = ((tv.typingAttributes[.font] as? UIFont) ?? defaultFont).fontDescriptor.symbolicTraits.contains(trait)
        } else {
            tv.textStorage.enumerateAttribute(.font, in: range) { value, _, stop in
                if !((value as? UIFont) ?? self.defaultFont).fontDescriptor.symbolicTraits.contains(trait) { allHave = false; stop.pointee = true }
            }
        }
        transformFonts { f in
            let t = f.fontDescriptor.symbolicTraits
            let family = RichTextCodec.familyKey(f)
            let b = bold ? !allHave : t.contains(.traitBold)
            let i = bold ? t.contains(.traitItalic) : !allHave
            return RichTextCodec.font(family: family, size: f.pointSize, bold: b, italic: i)
        }
    }

    private func toggleLine(_ key: NSAttributedString.Key) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length == 0 {
            var attrs = tv.typingAttributes
            let on = ((attrs[key] as? Int) ?? 0) != 0
            attrs[key] = on ? 0 : NSUnderlineStyle.single.rawValue
            tv.typingAttributes = attrs
            return
        }
        var allOn = true
        tv.textStorage.enumerateAttribute(key, in: range) { value, _, stop in
            if ((value as? Int) ?? 0) == 0 { allOn = false; stop.pointee = true }
        }
        tv.textStorage.beginEditing()
        if allOn { tv.textStorage.removeAttribute(key, range: range) } else { tv.textStorage.addAttribute(key, value: NSUnderlineStyle.single.rawValue, range: range) }
        tv.textStorage.endEditing()
        tv.selectedRange = range
        changed()
    }

    private func setAttribute(_ key: NSAttributedString.Key, _ value: Any) {
        guard let tv = textView else { return }
        let range = tv.selectedRange
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[key] = value
            tv.typingAttributes = attrs
            return
        }
        tv.textStorage.addAttribute(key, value: value, range: range)
        tv.selectedRange = range
        changed()
    }

    private func paragraphRange() -> NSRange? {
        guard let tv = textView else { return nil }
        return (tv.text as NSString).paragraphRange(for: tv.selectedRange)
    }

    private func setAlignment(_ alignment: NSTextAlignment) {
        guard let tv = textView, let range = paragraphRange() else { return }
        let p = NSMutableParagraphStyle()
        p.alignment = alignment
        if range.length == 0 {
            var attrs = tv.typingAttributes
            attrs[.paragraphStyle] = p
            tv.typingAttributes = attrs
            return
        }
        tv.textStorage.addAttribute(.paragraphStyle, value: p, range: range)
        changed()
    }

    private func toggleHeading() {
        guard let tv = textView, let range = paragraphRange() else { return }
        if range.length == 0 {
            transformFonts { f in
                let isHeading = f.pointSize >= 22 && f.fontDescriptor.symbolicTraits.contains(.traitBold)
                return RichTextCodec.font(family: RichTextCodec.familyKey(f), size: isHeading ? RichTextCodec.baseFontSize : 22, bold: !isHeading, italic: false)
            }
            return
        }
        let first = (tv.textStorage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont) ?? defaultFont
        let isHeading = first.pointSize >= 22 && first.fontDescriptor.symbolicTraits.contains(.traitBold)
        tv.textStorage.beginEditing()
        tv.textStorage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let f = (value as? UIFont) ?? self.defaultFont
            let nf = RichTextCodec.font(family: RichTextCodec.familyKey(f), size: isHeading ? RichTextCodec.baseFontSize : 22, bold: !isHeading, italic: false)
            tv.textStorage.addAttribute(.font, value: nf, range: sub)
        }
        tv.textStorage.endEditing()
        changed()
    }

    private func clearFormatting() {
        guard let tv = textView else { return }
        var range = tv.selectedRange
        if range.length == 0, let p = paragraphRange() { range = p }
        tv.typingAttributes = RichTextCodec.defaultAttributes
        guard range.length > 0 else { return }
        tv.textStorage.beginEditing()
        tv.textStorage.setAttributes(RichTextCodec.defaultAttributes, range: range)
        tv.textStorage.endEditing()
        changed()
    }

    private func toggleList(numbered: Bool) {
        guard let tv = textView, let range = paragraphRange() else { return }
        let ns = tv.text as NSString
        var paragraphs: [NSRange] = []
        var loc = range.location
        repeat {
            let p = ns.paragraphRange(for: NSRange(location: loc, length: 0))
            paragraphs.append(p)
            loc = p.location + p.length
        } while loc < range.location + range.length && loc < ns.length
        let lines = paragraphs.map { ns.substring(with: $0) }
        let allListed = lines.allSatisfy { line in
            guard let p = ListFormatting.prefix(of: line) else { return false }
            return numbered ? p.marker != ListFormatting.bullet : p.marker == ListFormatting.bullet
        }
        let storage = tv.textStorage
        storage.beginEditing()
        // De trás para frente, para as posições não mudarem.
        for (index, p) in paragraphs.enumerated().reversed() {
            let line = lines[index]
            if let existing = ListFormatting.prefix(of: line) {
                storage.replaceCharacters(in: NSRange(location: p.location, length: (existing.marker as NSString).length), with: "")
            }
            if !allListed {
                let marker = numbered ? "\(index + 1). " : ListFormatting.bullet
                let attrs = p.length > 0 && p.location < storage.length ? storage.attributes(at: p.location, effectiveRange: nil) : tv.typingAttributes
                storage.insert(NSAttributedString(string: marker, attributes: attrs), at: p.location)
            }
        }
        storage.endEditing()
        // Cursor no fim do parágrafo, pronto para continuar escrevendo.
        let updated = tv.text as NSString
        let para = updated.paragraphRange(for: NSRange(location: min(range.location, updated.length), length: 0))
        var end = para.location + para.length
        if end > para.location, end <= updated.length, updated.substring(with: NSRange(location: end - 1, length: 1)) == "\n" { end -= 1 }
        tv.selectedRange = NSRange(location: end, length: 0)
        changed()
    }
}
