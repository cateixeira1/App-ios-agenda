import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

enum LGPDNotice {
    static let title = "Proteção de dados (LGPD)"
    /// Texto do aviso exibido no cadastro.
    static let body = "Você é o controlador dos dados das pessoas que atende. Cabe a você conhecer e adequar sua prática profissional às exigências da Lei Geral de Proteção de Dados (LGPD). O uso deste software não faz essa adequação automaticamente, nem supre eventuais descumprimentos."
}

struct LGPDText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LGPDNotice.title, systemImage: "lock.shield").font(.title3.bold())
            Text(LGPDNotice.body).font(.body)
            Text("O Expediente guarda tudo só neste aparelho, cifrado, e não envia dados para nenhum servidor. Quando você exporta ou envia um arquivo, ou abre o WhatsApp, a informação passa a seguir as regras do app ou serviço escolhido.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Primeira configuração

struct SetupFlow: View {
    @EnvironmentObject var app: AppState
    enum Step { case welcome, account, area, lgpd, recovery, biometrics }
    @State private var step: Step = .welcome
    @State private var fullName = ""
    @State private var email = ""
    @State private var occupation = ""
    @State private var area: BusinessArea = .general
    @State private var term: ClientTerm = .client
    @State private var password = ""
    @State private var password2 = ""
    @State private var acceptedLGPD = false
    @State private var recoveryKey = ""
    @State private var working = false
    @State private var error: String?
    @State private var importing = false
    @State private var restoreFile: BackupFile?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .welcome: welcome
                case .account: account
                case .area: areaStep
                case .lgpd: lgpd
                case .recovery:
                    RecoveryKeyPanel(key: recoveryKey) { step = Biometrics.isAvailable ? .biometrics : finish() }
                case .biometrics: biometrics
                }
            }
            .animation(.easeInOut(duration: 0.2), value: step)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.expedienteBackup, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { restoreFile = try Backup.parse(Data(contentsOf: url)) } catch { self.error = BackupError.invalidFile.localizedDescription }
        }
        .sheet(item: $restoreFile) { file in
            RestoreBackupSheet(file: file, mode: .setup).environmentObject(app)
        }
        .onAppear {
            if DemoSeeder.startScreen == "cadastro" { step = .account; fullName = "Caio Teixeira"; email = "caio@exemplo.com"; occupation = "Cabeleireiro" }
            if DemoSeeder.startScreen == "area" { step = .area; area = .beauty }
            if DemoSeeder.startScreen == "lgpd" { step = .lgpd }
            if DemoSeeder.startScreen == "chave" { recoveryKey = RecoveryKey.generate(); step = .recovery }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Image("Logo").resizable().scaledToFit().frame(width: 170)
            Text("Expediente").font(.system(size: 40, weight: .bold, design: .serif))
            Text("Agenda, clientes, cobranças e financeiro de quem trabalha com hora marcada, cifrados no seu iPhone.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
            Spacer()
            Button { step = .account } label: { Text("Criar conta").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            Button("Restaurar um arquivo de backup") { importing = true }
                .font(.subheadline)
                .padding(.bottom, 24)
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.unpaid).padding(.horizontal) }
        }
    }

    private var account: some View {
        Form {
            Section {
                TextField("Nome completo", text: $fullName).textInputAutocapitalization(.words).textContentType(.name)
                TextField("E-mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    .autocorrectionDisabled().textContentType(.username)
                TextField("Profissão (opcional)", text: $occupation).textInputAutocapitalization(.sentences)
            } header: {
                Text("Seus dados")
            } footer: {
                Text("O e-mail serve só para entrar no app. Nada é enviado.")
            }
            Section {
                SecureField("Senha (mínimo 8 caracteres)", text: $password).textContentType(.newPassword)
                SecureField("Repita a senha", text: $password2).textContentType(.newPassword)
            } header: {
                Text("Senha")
            } footer: {
                if !password2.isEmpty && password != password2 {
                    Text("As senhas não são iguais.").foregroundStyle(Theme.unpaid)
                } else {
                    Text("A senha cifra os seus dados. Ela não fica guardada em lugar nenhum.")
                }
            }
        }
        .navigationTitle("Criar conta")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Voltar") { step = .welcome } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Continuar") { step = .area }
                    .disabled(fullName.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@")
                              || password.count < Vault.minimumPasswordLength || password != password2)
            }
        }
    }

    private var areaStep: some View {
        Form {
            Section {
                ForEach(BusinessArea.allCases) { a in
                    Button {
                        area = a
                        term = a.suggestedTerm
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: a.symbol).foregroundStyle(Theme.plum).frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.label).foregroundStyle(.primary)
                                Text(a.presetTags.prefix(4).map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if area == a { Image(systemName: "checkmark").foregroundStyle(Theme.plum).font(.body.weight(.semibold)) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Sua área")
            } footer: {
                Text("Define as tags de serviço sugeridas. Dá para mudar tudo depois em Ajustes.")
            }
            Section {
                Picker("Como chamar quem você atende", selection: $term) {
                    ForEach(ClientTerm.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Aparece em todo o app: \"\(Formatters.capitalizedFirst(term.plural))\", \"Novo \(term.singular)\"…")
            }
        }
        .navigationTitle("Como você trabalha")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Voltar") { step = .account } }
            ToolbarItem(placement: .confirmationAction) { Button("Continuar") { step = .lgpd } }
        }
    }

    private var lgpd: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LGPDText()
                Toggle(isOn: $acceptedLGPD) {
                    Text("Li e entendi o aviso.").font(.body.weight(.medium))
                }
                .toggleStyle(CheckboxToggleStyle())
                if let error { Text(error).foregroundStyle(Theme.unpaid).font(.footnote) }
                Button {
                    create()
                } label: {
                    Group { if working { ProgressView().tint(.white) } else { Text("Criar conta").font(.headline) } }
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!acceptedLGPD || working)
            }
            .padding(24)
        }
        .navigationTitle("Antes de começar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Voltar") { step = .area } } }
    }

    private var biometrics: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: Biometrics.symbol).font(.system(size: 64)).foregroundStyle(Theme.plum)
            Text("Entrar com \(Biometrics.name)?").font(.title2.bold())
            Text("Você pode entrar sem digitar a senha. A senha continua valendo e pode ser usada a qualquer momento.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
            Spacer()
            Button {
                if let key = app.store?.key, Biometrics.enable(key: key.rawData) { app.store?.audit(.biometricsEnabled) }
                step = finish()
            } label: { Text("Usar \(Biometrics.name)").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal, 24)
            Button("Agora não") { step = finish() }.padding(.bottom, 24)
        }
    }

    private func create() {
        working = true
        error = nil
        Task {
            do {
                recoveryKey = try await app.createAccount(fullName: fullName, email: email, occupation: occupation, area: area,
                                                          term: term, password: password)
                password = ""
                password2 = ""
                step = .recovery
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func finish() -> Step {
        app.finishSetup()
        return .biometrics
    }
}

struct CheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(configuration.isOn ? Theme.plum : .secondary)
                configuration.label.foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Mostra a chave de recuperação uma única vez.
struct RecoveryKeyPanel: View {
    let key: String
    let onDone: () -> Void

    static func twoLines(_ key: String) -> String {
        let groups = key.split(separator: "-")
        guard groups.count == 8 else { return key }
        return groups.prefix(4).joined(separator: "-") + "-\n" + groups.suffix(4).joined(separator: "-")
    }
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Sua chave de recuperação", systemImage: "key.fill").font(.title3.bold())
                Text("Se você esquecer a senha, esta chave é o único jeito de abrir os seus dados. Anote em papel ou guarde num gerenciador de senhas. Ela não será mostrada de novo.")
                    .foregroundStyle(.secondary)
                Text(Self.twoLines(key))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(16)
                    .background(Theme.plum.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                Button {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: key]],
                                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    copied = true
                } label: {
                    Label(copied ? "Copiada (some da área de transferência em 2 minutos)" : "Copiar chave", systemImage: "doc.on.doc")
                }
                Toggle(isOn: $saved) { Text("Guardei a chave em local seguro.") }
                    .toggleStyle(CheckboxToggleStyle())
                Button { onDone() } label: { Text("Continuar").font(.headline).frame(maxWidth: .infinity, minHeight: 48) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!saved)
            }
            .padding(24)
        }
    }
}

// MARK: - Bloqueio

struct LockView: View {
    @EnvironmentObject var app: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var showRecovery = false
    @FocusState private var focus: Field?
    enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("Logo").resizable().scaledToFit().frame(width: 120).padding(.top, 50)
                Text(app.firstName.isEmpty ? "Olá" : "Olá, \(app.firstName)").font(.largeTitle.bold())
                if Biometrics.isEnabled && Biometrics.isAvailable {
                    Button { Task { await tryBiometrics() } } label: {
                        Label("Entrar com \(Biometrics.name)", systemImage: Biometrics.symbol)
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    Text("ou use a senha").font(.footnote).foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    TextField("E-mail", text: $email)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.username).focused($focus, equals: .email)
                        .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                    SecureField("Senha", text: $password)
                        .textContentType(.password).focused($focus, equals: .password)
                        .submitLabel(.go).onSubmit { unlock() }
                        .padding(12).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                }
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.unpaid) }
                Button { unlock() } label: {
                    Group { if working { ProgressView() } else { Text("Entrar").font(.headline) } }
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .disabled(email.isEmpty || password.isEmpty || working)
                Button("Esqueci a senha") { showRecovery = true }.font(.subheadline)
                Text("Color Software").font(.footnote).foregroundStyle(.tertiary).padding(.top, 36).padding(.bottom, 16)
            }
            .padding(.horizontal, 28)
        }
        .background(Theme.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $showRecovery) { RecoveryUnlockView().environmentObject(app) }
        .onAppear {
            email = app.email
            if Biometrics.isEnabled && Biometrics.isAvailable && !app.isDemo {
                Task { await tryBiometrics() }
            }
        }
    }

    private func tryBiometrics() async {
        if await app.unlockWithBiometrics() == false { focus = .password }
    }

    private func unlock() {
        guard !email.isEmpty, !password.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            do {
                try await app.unlock(email: email, password: password)
                password = ""
            } catch {
                self.error = error.localizedDescription
                password = ""
            }
            working = false
        }
    }
}

struct RecoveryUnlockView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $key, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } header: {
                    Text("Chave de recuperação")
                } footer: {
                    Text("A chave que apareceu quando você criou a conta.")
                }
                Section("Nova senha") {
                    SecureField("Nova senha (mínimo 8 caracteres)", text: $new1)
                    SecureField("Repita a nova senha", text: $new2)
                }
                if let error { Section { Text(error).foregroundStyle(Theme.unpaid) } }
            }
            .navigationTitle("Recuperar acesso")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Entrar") { submit() }
                            .disabled(RecoveryKey.normalize(key).count != 32 || new1.count < Vault.minimumPasswordLength || new1 != new2)
                    }
                }
            }
        }
    }

    private func submit() {
        working = true
        error = nil
        Task {
            do {
                try await app.unlockWithRecovery(key, newPassword: new1)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Restaurar backup

struct RestoreBackupSheet: View {
    enum Mode { case setup, overCurrent }
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let file: BackupFile
    let mode: Mode
    @State private var useRecovery = false
    @State private var email = ""
    @State private var password = ""
    @State private var recovery = ""
    @State private var confirmReplace = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Backup de", value: Formatters.dateTime.string(from: file.createdAt))
                    LabeledContent("Conta", value: file.meta.email)
                }
                Section {
                    Picker("Abrir com", selection: $useRecovery) {
                        Text("Senha").tag(false)
                        Text("Chave de recuperação").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if useRecovery {
                        TextField("Chave de recuperação", text: $recovery, axis: .vertical)
                            .font(.system(.body, design: .monospaced)).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    } else {
                        TextField("E-mail", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Senha da época do backup", text: $password)
                    }
                } footer: {
                    if mode == .overCurrent {
                        Text("Os dados atuais deste aparelho serão substituídos pelos do backup. O registro de acessos atual é mantido. Depois, entre com a senha da época do backup.")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(Theme.unpaid) } }
            }
            .navigationTitle("Restaurar backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Restaurar") {
                            if mode == .overCurrent { confirmReplace = true } else { restore() }
                        }
                            .disabled(useRecovery ? RecoveryKey.normalize(recovery).count != 32 : (email.isEmpty || password.isEmpty))
                    }
                }
            }
            .confirmationDialog("Substituir os dados atuais?", isPresented: $confirmReplace, titleVisibility: .visible) {
                Button("Substituir pelos dados do backup", role: .destructive) { restore() }
                Button("Cancelar", role: .cancel) {}
            }
            .onAppear { email = file.meta.email }
        }
    }

    private func restore() {
        working = true
        error = nil
        let file = self.file, email = self.email, password = self.password, recovery = self.recovery, useRecovery = self.useRecovery
        Task {
            do {
                switch mode {
                case .setup:
                    try await app.restoreForSetup(file, email: email, password: useRecovery ? nil : password, recoveryKey: useRecovery ? recovery : nil)
                case .overCurrent:
                    let key = try await Task.detached(priority: .userInitiated) { () -> SymmetricKey in
                        if useRecovery { return try Backup.unlock(file, recoveryKey: recovery) }
                        return try Backup.unlock(file, email: email, password: password)
                    }.value
                    guard let store = app.store else { return }
                    try store.restore(file, key: key)
                    app.reloadAfterRestore()
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
