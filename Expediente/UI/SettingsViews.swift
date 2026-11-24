import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @State private var editingProfile = false
    @State private var changingPassword = false
    @State private var newRecoveryKey: String?
    @State private var confirmNewRecovery = false
    @State private var exportingBackup = false
    @State private var importingBackup = false
    @State private var pendingRestore: BackupFile?
    @State private var showLGPD = false
    @State private var confirmErase = false
    @State private var biometrics = Biometrics.isEnabled

    var body: some View {
        let s = store.db.settings
        Form {
            Section("Perfil") {
                Button { router.open(.profile) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.db.professional.fullName.isEmpty ? "Seu nome" : store.db.professional.fullName).foregroundStyle(.primary)
                            Text([store.db.professional.subtitle, store.db.settings.businessArea.label]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            }

            Section {
                if Biometrics.isAvailable {
                    Toggle("Entrar com \(Biometrics.name)", isOn: $biometrics)
                        .onChange(of: biometrics) { _, on in toggleBiometrics(on) }
                }
                Button("Trocar senha") { changingPassword = true }
                Button("Gerar nova chave de recuperação") { confirmNewRecovery = true }
                Picker("Bloquear o app", selection: binding(\.lockAfterSeconds)) {
                    Text("Ao sair do app").tag(0)
                    Text("Depois de 1 minuto").tag(60)
                    Text("Depois de 5 minutos").tag(300)
                    Text("Depois de 15 minutos").tag(900)
                }
                Toggle("Buscar o endereço pelo CEP (ViaCEP)", isOn: binding(\.cepLookup))
                Button { router.open(.auditLog) } label: {
                    HStack {
                        Label("Registro de acessos", systemImage: "list.bullet.rectangle.portrait")
                        Spacer()
                        if store.auditIntegrity().isIntact {
                            Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.paid)
                        } else {
                            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(Theme.unpaid)
                        }
                    }
                }
            } header: {
                Text("Segurança")
            } footer: {
                Text("Os dados ficam neste aparelho, cifrados (AES-256). Sem a senha e sem a chave de recuperação, não há como abri-los. A busca pelo CEP envia só o CEP digitado ao ViaCEP.")
            }

            Section {
                Stepper("Início do expediente: \(s.workdayStartHour)h", value: binding(\.workdayStartHour), in: 0...22)
                Stepper("Fim do expediente: \(s.workdayEndHour)h", value: binding(\.workdayEndHour), in: (s.workdayStartHour + 1)...24)
                DurationPicker("Duração padrão", minutes: binding(\.defaultDurationMinutes))
                DurationPicker("Primeiro atendimento", minutes: Binding(get: { s.firstSessionDurationMinutes }, set: { v in
                    store.update { db in
                        db.settings.firstSessionDurationMinutes = v
                        // A tag do primeiro atendimento acompanha (a duração própria da tag e a de Ajustes ficam iguais).
                        if let t = db.firstSessionTag(), let i = db.tags.firstIndex(where: { $0.id == t.id }) { db.tags[i].durationMinutes = v }
                    }
                }))
                Picker("Tag do primeiro atendimento", selection: Binding(get: { store.db.firstSessionTag()?.id }, set: { v in store.update { $0.settings.firstSessionTagID = v } })) {
                    Text("Nenhuma").tag(UUID?.none)
                    ForEach(store.db.tags) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                PriceSetting(cents: store.db.settings.defaultPriceCents) { v in store.update { $0.settings.defaultPriceCents = v } }
                Toggle("Valor por \(Term.client)", isOn: binding(\.priceByClient))
                if s.priceByClient {
                    Label("Com a chave ligada, o valor registrado no cadastro de cada \(Term.client) vale sempre, independentemente da tag usada. O valor por tag deixa de ser usado, e o retorno continua sem custo, a não ser que você digite um valor no atendimento.",
                          systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ligue para cobrar um valor fixo de cada \(Term.client), definido no cadastro dele, em qualquer serviço.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Local padrão (endereço, Online ou link)", text: binding(\.defaultLocation), axis: .vertical)
                    .lineLimit(1...3)
                Picker("Avisar antes de cada atendimento", selection: binding(\.reminderMinutesBefore)) {
                    Text("Não avisar").tag(0)
                    Text("10 minutos antes").tag(10)
                    Text("15 minutos antes").tag(15)
                    Text("30 minutos antes").tag(30)
                    Text("1 hora antes").tag(60)
                    Text("2 horas antes").tag(120)
                    Text("1 dia antes").tag(1440)
                }
                Button { router.open(.agendaSettings) } label: {
                    HStack {
                        Text("Dias de atendimento, feriados e intervalos").foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                Button { router.open(.tags) } label: {
                    HStack {
                        Text("Tags").foregroundStyle(.primary)
                        Spacer()
                        HStack(spacing: -4) {
                            ForEach(store.db.tags.prefix(5)) { t in Circle().fill(Color(hex: t.colorHex)).frame(width: 14, height: 14) }
                        }
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Agenda")
            } footer: {
                Text("Cada tag é um tipo de serviço, com duração, valor e mensagem próprios. O local padrão vale para os atendimentos sem local. O aviso antes do atendimento aparece neste iPhone.")
            }

            Section("Cobrança, WhatsApp e documentos") {
                settingsLink("Pix para cobrança", value: Pix.isConfigured(store.db.settings) ? "Configurado" : "Não configurado", route: .pixSettings)
                settingsLink("Mensagens do WhatsApp", value: store.db.settings.whatsAppTemplate.isEmpty ? "Padrão" : "Personalizada", route: .whatsAppMessage)
                settingsLink("Cabeçalho e rodapé dos PDFs", value: nil, route: .documentLayout)
                settingsLink("Notas fiscais (NFS-e)", value: store.db.fiscal.environment.shortLabel, route: .nfseSettings)
                settingsLink("Certificados digitais", value: store.db.certificates.isEmpty ? "Nenhum" : "\(store.db.certificates.count)", route: .certificates)
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Altura das linhas: \(Int(s.patientRowHeight)) pt")
                    Slider(value: binding(\.patientRowHeight), in: 44...110, step: 2)
                }
                HStack(spacing: 12) {
                    Circle().fill(Theme.plum.opacity(0.85)).frame(width: 38, height: 38)
                    Text("Exemplo de \(Term.client)")
                    Spacer()
                }
                .frame(minHeight: s.patientRowHeight)
                .background(Color(uiColor: .tertiarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } header: {
                Text("Lista de \(Term.clients)")
            } footer: {
                Text("Linhas mais altas evitam tocar no \(Term.client) errado.")
            }

            Section {
                Toggle("Aviso de atendimentos sem anotação", isOn: binding(\.endOfDayReminder))
                if s.endOfDayReminder || s.reminderMinutesBefore > 0 {
                    Toggle("Mostrar nomes nos avisos", isOn: binding(\.reminderShowsNames))
                }
            } header: {
                Text("Notificações")
            } footer: {
                Text("O aviso de anotações aparece 5 minutos depois do fim do último atendimento do dia. Com os nomes ligados, o nome dos \(Term.clients) pode aparecer na tela bloqueada, conforme os ajustes de notificações do iPhone.")
            }

            Section {
                Button { exportingBackup = true } label: { Label("Exportar backup cifrado", systemImage: "externaldrive.badge.icloud") }
                Button { importingBackup = true } label: { Label("Restaurar um backup", systemImage: "arrow.down.doc") }
                Toggle("Incluir no backup do iCloud do iPhone", isOn: binding(\.includeInDeviceBackup))
            } header: {
                Text("Backup")
            } footer: {
                Text("Nada sai do iPhone sozinho. O backup sai cifrado e abre com a sua senha ou com a chave de recuperação. Salve em Arquivos, Google Drive, iCloud Drive ou onde preferir, e faça com frequência: sem backup, perder o iPhone é perder os dados.")
            }

            Section("Sobre") {
                Button("Aviso sobre a LGPD") { showLGPD = true }
                LabeledContent("Versão", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("Desenvolvido por", value: "Color Software")
            }

            Section {
                Button("Apagar a conta e todos os dados deste aparelho", role: .destructive) { confirmErase = true }
            }
        }
        .navigationTitle("Ajustes")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.db.settings) { old, new in
            if old.includeInDeviceBackup != new.includeInDeviceBackup { store.vault.setIncludedInDeviceBackup(new.includeInDeviceBackup) }
            if old.endOfDayReminder != new.endOfDayReminder || old.reminderShowsNames != new.reminderShowsNames
                || old.reminderMinutesBefore != new.reminderMinutesBefore { app.rescheduleReminders() }
        }
        .sheet(isPresented: $changingPassword) { ChangePasswordView().environmentObject(store).environmentObject(toaster) }
        .sheet(isPresented: Binding(get: { newRecoveryKey != nil }, set: { if !$0 { newRecoveryKey = nil } })) {
            NavigationStack {
                RecoveryKeyPanel(key: newRecoveryKey ?? "", onDone: { newRecoveryKey = nil })
                    .navigationTitle("Nova chave")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showLGPD) {
            NavigationStack {
                ScrollView { LGPDText().padding() }
                    .navigationTitle("LGPD")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { showLGPD = false } } }
            }
        }
        .sheet(item: $pendingRestore) { file in
            RestoreBackupSheet(file: file, mode: .overCurrent).environmentObject(app).environmentObject(store)
        }
        .alert("Gerar nova chave de recuperação?", isPresented: $confirmNewRecovery) {
            Button("Gerar") {
                do {
                    newRecoveryKey = try store.vault.regenerateRecoveryKey(key: store.key)
                    store.audit(.recoveryKeyRegenerated)
                } catch {
                    toaster.show(error.localizedDescription)
                }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A chave atual deixa de funcionar. Backups antigos continuam abrindo com a chave da época em que foram feitos.")
        }
        .confirmationDialog("Apagar tudo?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Apagar conta e dados", role: .destructive) { app.eraseEverything() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("\(Term.Clients), agenda, anotações, financeiro e o registro de acessos serão apagados deste aparelho. Isso não pode ser desfeito. Faça um backup antes, se precisar guardar os registros.")
        }
        .exportFlow(isPresented: $exportingBackup, allowsPassword: false, fileName: Backup.fileName(), makeData: {
            try? store.makeBackup()
        }, onExported: {
            store.audit(.backupExported)
        })
        .fileImporter(isPresented: $importingBackup, allowedContentTypes: [.expedienteBackup, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingRestore = try Backup.parse(Data(contentsOf: url))
            } catch {
                toaster.show(BackupError.invalidFile.localizedDescription)
            }
        }
    }

    private func settingsLink(_ title: String, value: String?, route: Route) -> some View {
        Button { router.open(route) } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { store.db.settings[keyPath: keyPath] }, set: { v in store.update { $0.settings[keyPath: keyPath] = v } })
    }

    private func toggleBiometrics(_ on: Bool) {
        if on {
            if Biometrics.enable(key: store.key.rawData) {
                store.audit(.biometricsEnabled)
            } else {
                biometrics = false
                toaster.show("Não foi possível ativar. Confira se o iPhone tem código e \(Biometrics.name) configurados.")
            }
        } else if Biometrics.isEnabled {
            Biometrics.disable()
            store.audit(.biometricsDisabled)
        }
    }
}

extension BackupFile: Identifiable {
    var id: Date { createdAt }
}

struct PriceSetting: View {
    let cents: Int?
    let onChange: (Int?) -> Void
    @State private var text = ""
    var body: some View {
        HStack {
            Text("Valor padrão do atendimento")
            Spacer()
            MoneyField("0,00", text: $text)
                .frame(maxWidth: 120)
                .onChange(of: text) { _, t in onChange(Formatters.parseMoney(Formatters.moneyMask(t))) }
        }
        .onAppear { text = Formatters.moneyMasked(cents) }
    }
}

// MARK: - Senha

struct ChangePasswordView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new1 = ""
    @State private var new2 = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section { SecureField("Senha atual", text: $current) }
                Section {
                    SecureField("Nova senha (mínimo 8 caracteres)", text: $new1)
                    SecureField("Repita a nova senha", text: $new2)
                } footer: {
                    if let error { Text(error).foregroundStyle(Theme.unpaid) }
                }
            }
            .navigationTitle("Trocar senha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else {
                        Button("Salvar") { save() }.disabled(current.isEmpty || new1.count < Vault.minimumPasswordLength || new1 != new2)
                    }
                }
            }
        }
    }

    private func save() {
        working = true
        let vault = store.vault, key = store.key, cur = current, n = new1
        Task {
            let ok = await Task.detached { vault.verify(key: key, password: cur) }.value
            guard ok else { error = "A senha atual não confere."; working = false; return }
            do {
                try await Task.detached { try vault.changePassword(key: key, newPassword: n) }.value
                store.audit(.passwordChanged)
                toaster.show("Senha alterada.")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: - Tags

struct TagsView: View {
    @EnvironmentObject var store: Store
    @State private var editing: Tag?

    var body: some View {
        List {
            Section {
                ForEach(store.db.tags) { t in
                    Button { editing = t } label: {
                        HStack {
                            Circle().fill(Color(hex: t.colorHex)).frame(width: 22, height: 22)
                            Text(t.name).foregroundStyle(.primary)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Formatters.duration(store.db.duration(for: t.id))).font(.subheadline).foregroundStyle(.secondary)
                                if let price = priceLabel(t) { Text(price).font(.caption).foregroundStyle(.secondary) }
                            }
                            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { idx in idx.map { store.db.tags[$0].id }.forEach(store.deleteTag) }
                .onMove { store.moveTags(from: $0, to: $1) }
            } footer: {
                Text("Cada tag é um tipo de serviço: pinta o horário na agenda e define a duração, o valor padrão e a mensagem de WhatsApp. Pode ser trocada a qualquer momento no agendamento.")
            }
            Section {
                Button { editing = Tag(name: "", colorHex: TagPalette.colors[5]) } label: { Label("Nova tag", systemImage: "plus") }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { t in
            TagEditor(tag: t, defaultMinutes: store.db.settings.defaultDurationMinutes,
                      isFirstSession: store.db.firstSessionTag()?.id == t.id,
                      isReturn: store.db.returnTag()?.id == t.id,
                      priceByClient: store.db.settings.priceByClient,
                      firstSessionMinutes: store.db.settings.firstSessionDurationMinutes,
                      generalMessage: WhatsAppMessage.template(store.db.settings)) { tag in
                store.saveTag(tag)
                if store.db.firstSessionTag()?.id == tag.id, let d = tag.durationMinutes {
                    store.update { $0.settings.firstSessionDurationMinutes = d }
                }
            }
        }
    }
}

extension TagsView {
    /// Valor padrão da tag na lista ("Sem custo" no retorno sem valor); nil = usa o do cliente ou o padrão.
    fileprivate func priceLabel(_ t: Tag) -> String? {
        if let p = store.db.tagPrice(t), p > 0 { return Formatters.money(p) }
        return store.db.returnTag()?.id == t.id ? "Sem custo" : nil
    }
}

enum TagPalette {
    /// Tons que não se confundem com as cores de pagamento e presença.
    static let colors = ["#B39DDB", "#F48FB1", "#C98B6B", "#E0B33C", "#9E9E9E", "#80CBC4", "#90A4AE", "#CE93D8", "#FFAB91", "#A5D6A7", "#81D4FA", "#BCAAA4"]
}

struct TagEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var tag: Tag
    let defaultMinutes: Int
    let isFirstSession: Bool
    let isReturn: Bool
    let priceByClient: Bool
    let firstSessionMinutes: Int
    let generalMessage: String
    let onSave: (Tag) -> Void
    @State private var useDefault = true
    @State private var minutes = 60
    @State private var priceText = ""
    @State private var message = ""

    init(tag: Tag, defaultMinutes: Int, isFirstSession: Bool, isReturn: Bool, priceByClient: Bool, firstSessionMinutes: Int,
         generalMessage: String, onSave: @escaping (Tag) -> Void) {
        _tag = State(initialValue: tag)
        self.defaultMinutes = defaultMinutes
        self.isFirstSession = isFirstSession
        self.isReturn = isReturn
        self.priceByClient = priceByClient
        self.firstSessionMinutes = firstSessionMinutes
        self.generalMessage = generalMessage
        self.onSave = onSave
        let own = tag.durationMinutes ?? (isFirstSession ? firstSessionMinutes : nil)
        _useDefault = State(initialValue: own == nil && !isFirstSession)
        _minutes = State(initialValue: own ?? defaultMinutes)
        _priceText = State(initialValue: Formatters.moneyMasked(tag.defaultPriceCents))
        _message = State(initialValue: tag.whatsAppMessage ?? "")
    }

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nome") { TextField("Nome da tag", text: $tag.name) }
                Section {
                    if isFirstSession {
                        DurationPicker("Duração", minutes: $minutes)
                    } else {
                        DurationPicker("Duração", minutes: $minutes, useDefault: $useDefault, defaultLabel: Formatters.duration(defaultMinutes))
                    }
                } header: {
                    Text("Duração deste serviço")
                } footer: {
                    Text(isFirstSession
                         ? "Esta é a tag do primeiro atendimento: a duração também vale em Ajustes › Agenda › Primeiro atendimento."
                         : "Ao escolher esta tag no agendamento, o atendimento já vem com esta duração.")
                }
                Section {
                    HStack {
                        Text("Valor")
                        Spacer()
                        MoneyField(isReturn ? "Sem custo" : "Padrão", text: $priceText)
                            .disabled(priceByClient)
                    }
                } header: {
                    Text("Valor deste serviço")
                } footer: {
                    Text(priceByClient
                         ? "A chave \"Valor por \(Term.client)\" (Ajustes › Agenda) está ligada: vale o valor do cadastro de cada \(Term.client), e o valor da tag não é usado."
                         : isReturn
                         ? "O retorno parte do princípio de que não tem custo. Deixe em branco para manter assim ou digite um valor para cobrar. O valor digitado num atendimento tem prioridade."
                         : "Em branco, vale o valor do \(Term.client) ou o valor padrão de Ajustes. O valor digitado num atendimento tem prioridade, e o valor da tag vale mais que o do \(Term.client).")
                }
                Section {
                    TextField(generalMessage, text: $message, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: message) { _, m in
                            if m.count > WhatsAppMessage.maxTemplateLength { message = String(m.prefix(WhatsAppMessage.maxTemplateLength)) }
                        }
                    FieldButtons(text: $message, fields: [WhatsAppMessage.nameField, WhatsAppMessage.dateField,
                                                          WhatsAppMessage.timeField, WhatsAppMessage.placeField])
                    if !trimmedMessage.isEmpty {
                        Button("Usar a mensagem geral de Ajustes", role: .destructive) { message = "" }
                    }
                } header: {
                    Text("Mensagem do WhatsApp")
                } footer: {
                    Text("Vai no botão do WhatsApp da agenda, nos atendimentos com esta tag. Em branco, vale a mensagem geral de Ajustes.")
                }
                if !trimmedMessage.isEmpty {
                    Section("Como chega para o \(Term.client)") {
                        Text(WhatsAppMessage.compose(trimmedMessage, firstName: "Ana",
                                                     start: Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date()) ?? Date(),
                                                     place: "Rua das Flores, 100"))
                            .padding(12)
                            .background(Theme.whatsApp.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                Section("Cor") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(TagPalette.colors, id: \.self) { hex in
                            Button { tag.colorHex = hex } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(Theme.plum, lineWidth: tag.colorHex == hex ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cor \(hex)")
                        }
                    }
                    .padding(.vertical, 6)
                }
                Section("Prévia") {
                    HStack {
                        Text("16:00").font(.headline.monospacedDigit())
                        Text(Term.Client).font(.headline)
                        Spacer()
                        Text(Formatters.duration(useDefault ? defaultMinutes : minutes)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(hex: tag.colorHex).opacity(Theme.appointmentTint), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle(tag.name.isEmpty ? "Nova tag" : tag.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") {
                        tag.durationMinutes = useDefault ? nil : minutes
                        tag.defaultPriceCents = Formatters.parseMoney(priceText)
                        tag.whatsAppMessage = trimmedMessage.isEmpty ? nil : trimmedMessage
                        onSave(tag)
                        dismiss()
                    }
                    .disabled(tag.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Registro de acessos

struct AuditLogView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let integrity = store.auditIntegrity()
        List {
            Section {
                switch integrity {
                case .intact:
                    Label("Registro íntegro: nenhum item foi alterado ou apagado.", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(Theme.paid)
                case .tampered(let reason):
                    Label("Alteração detectada. \(reason)", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(Theme.unpaid)
                }
            } footer: {
                Text("Cada item guarda o código (SHA-256) do anterior. Ninguém pode editar ou apagar itens pelo app, e qualquer mudança feita fora dele é detectada aqui.")
            }
            Section("\(store.auditEntries.count) registros") {
                ForEach(store.auditEntries.reversed()) { e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: e.event.symbol)
                            .foregroundStyle(e.event == .loginFailed ? Theme.unpaid : Theme.plum)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.event.label).font(.subheadline.weight(.semibold))
                            Text(AuditLog.dateFormatter.string(from: e.date)).font(.caption).foregroundStyle(.secondary)
                            if !e.detail.isEmpty { Text(e.detail).font(.caption).foregroundStyle(.secondary) }
                            Text("\(e.actor) · \(e.device)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Registro de acessos")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Botões que inserem campos ({nome}, {horário}…) no fim do texto de uma mensagem.
struct FieldButtons: View {
    @Binding var text: String
    let fields: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(fields, id: \.self) { f in
                    Button(f) { text += (text.hasSuffix(" ") || text.hasSuffix("\n") || text.isEmpty ? "" : " ") + f }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
