import SwiftUI
import UIKit

enum ExportText {
    /// Texto definido para o aviso exibido antes de qualquer envio ou exportação.
    static let warning = "Podem haver riscos ao exportar informações sensíveis. Utilize apenas sistemas confiáveis."
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Folha de compartilhamento do iOS (WhatsApp, e-mail, Arquivos, Drive, AirDrop…).
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, completed, _, _ in onComplete(completed) }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Fluxo de exportação: aviso de risco → com ou sem senha → compartilhar.
struct ExportFlowModifier: ViewModifier {
    @Binding var isPresented: Bool
    let allowsPassword: Bool
    let fileName: String
    let makeData: () -> Data?
    let onExported: () -> Void

    @State private var askFormat = false
    @State private var askPassword = false
    @State private var password = ""
    @State private var share: ShareItem?
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .alert("Aviso", isPresented: $isPresented) {
                Button("Continuar") {
                    // Espera o aviso fechar antes de abrir a próxima pergunta.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        if allowsPassword { askFormat = true } else { prepare(password: nil) }
                    }
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text(ExportText.warning)
            }
            .confirmationDialog("Como você quer enviar?", isPresented: $askFormat, titleVisibility: .visible) {
                Button("PDF protegido por senha") {
                    password = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { askPassword = true }
                }
                Button("PDF sem senha") { prepare(password: nil) }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Com senha, o PDF só abre com a senha que você combinar com quem vai receber. Envie a senha por outro meio.")
            }
            .alert("Senha do PDF", isPresented: $askPassword) {
                SecureField("Senha (mínimo 4 caracteres)", text: $password)
                Button("Gerar PDF") { prepare(password: password) }
                    .disabled(password.count < 4)
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Quem receber o arquivo vai precisar desta senha para abrir.")
            }
            .alert("Não foi possível gerar o arquivo.", isPresented: $failed) { Button("OK", role: .cancel) {} }
            .sheet(item: $share) { item in
                ShareSheet(url: item.url) { completed in
                    if completed { onExported() }
                    share = nil
                }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
            }
    }

    private func prepare(password: String?) {
        guard var data = makeData() else { failed = true; return }
        if let password, password.count >= 4 {
            guard let protected = PDFExporter.protect(data, password: password) else { failed = true; return }
            data = protected
        }
        // Pequena espera para a folha abrir depois que o alerta fechar.
        let url = TemporaryFiles.write(data, name: fileName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { share = ShareItem(url: url) }
    }
}

extension View {
    func exportFlow(isPresented: Binding<Bool>, allowsPassword: Bool = true, fileName: String,
                    makeData: @escaping () -> Data?, onExported: @escaping () -> Void) -> some View {
        modifier(ExportFlowModifier(isPresented: isPresented, allowsPassword: allowsPassword, fileName: fileName,
                                    makeData: makeData, onExported: onExported))
    }
}

enum FileNames {
    static func safe(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive], locale: Formatters.locale)
        let allowed = folded.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        return String(allowed).replacingOccurrences(of: "--", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
