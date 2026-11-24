import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Perfil e área de atuação

struct ProfileView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    @State private var p = Professional()
    @State private var office = PostalAddress()
    @State private var term: ClientTerm = .client
    @State private var area: BusinessArea = .general
    @State private var confirmArea: BusinessArea?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                TextField("Nome completo", text: $p.fullName).textInputAutocapitalization(.words)
                TextField("Profissão (ex.: Cabeleireira, Personal trainer)", text: $p.occupation).textInputAutocapitalization(.sentences)
                TextField("Registro profissional (opcional)", text: $p.registration)
                PhoneField(title: "Telefone", text: $p.phone)
                LabeledContent("E-mail de acesso", value: p.email)
            } footer: {
                Text("Nome, profissão e registro (ex.: OAB, CREF, CRN) saem nos recibos e relatórios.")
            }
            Section {
                Picker("Como chamar quem você atende", selection: $term) {
                    ForEach(ClientTerm.allCases) { Text($0.label).tag($0) }
                }
                Picker("Área de atuação", selection: Binding(get: { area }, set: { new in
                    if new != area { confirmArea = new }
                })) {
                    ForEach(BusinessArea.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
            } header: {
                Text("Área")
            } footer: {
                Text("O nome escolhido aparece em todo o app (ex.: \"Alunos\", \"Novo paciente\"). A área sugere as tags de serviço.")
            }
            Section {
                AddressFields(address: $office, lookupEnabled: store.db.settings.cepLookup)
            } header: {
                Text("Endereço de atendimento")
            } footer: {
                Text("Sai nos recibos, numa linha só. O local padrão dos atendimentos fica em Ajustes › Agenda.")
            }
        }
        .navigationTitle("Perfil")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Salvar") { save() }.disabled(p.fullName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("Trocar a área de atuação?", isPresented: Binding(get: { confirmArea != nil }, set: { if !$0 { confirmArea = nil } }),
                            titleVisibility: .visible, presenting: confirmArea) { a in
            Button("Trocar as tags pelas de \(a.label)") {
                store.applyBusinessArea(a, term: a.suggestedTerm)
                area = a
                term = a.suggestedTerm
                toaster.show("Tags de \(a.label) prontas.")
            }
            Button("Só mudar a área, sem mexer nas tags") {
                store.update { $0.settings.businessArea = a }
                area = a
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("As tags que ainda não foram usadas na agenda são trocadas pelas sugeridas. As já usadas ficam.")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            p = store.db.professional
            p.phone = Masks.phoneWithPrefix(p.phone)
            term = store.db.settings.clientTerm
            area = store.db.settings.businessArea
            office = p.office ?? (p.officeAddress.isEmpty ? PostalAddress() : PostalAddress.fromLegacy(p.officeAddress))
        }
    }

    private func save() {
        var q = p
        q.phone = Masks.phoneToSave(q.phone)
        q.occupation = q.occupation.trimmingCharacters(in: .whitespaces)
        q.registration = q.registration.trimmingCharacters(in: .whitespaces)
        q.office = office.isEmpty ? nil : office
        q.officeAddress = office.compose()
        store.saveProfessional(q)
        if store.db.settings.clientTerm != term { store.update { $0.settings.clientTerm = term } }
        try? store.vault.updateProfile(firstName: q.firstName, email: q.email)
        toaster.show("Perfil salvo.")
        dismiss()
    }
}

// MARK: - Pix

struct PixSettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @State private var key = ""
    @State private var name = ""
    @State private var city = ""
    @State private var loaded = false

    var body: some View {
        let detected = Pix.normalizeKey(key)
        let sample = Pix.payload(key: key, name: name, city: city, amountCents: 15_000)
        Form {
            Section {
                TextField("Chave Pix (CPF, CNPJ, telefone, e-mail ou aleatória)", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !key.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let d = detected {
                        Label("Chave reconhecida: \(d.kind.label)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(Theme.paid)
                    } else {
                        Label("Não parece uma chave Pix. Telefone com +55 e DDD; CPF e CNPJ só com números ou com pontos.",
                              systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                TextField("Nome de quem recebe", text: $name).textInputAutocapitalization(.words)
                TextField("Cidade", text: $city).textInputAutocapitalization(.words)
            } header: {
                Text("Recebimento")
            } footer: {
                Text("Use o nome e a cidade cadastrados no seu banco. Com o Pix configurado, as cobranças pelo WhatsApp levam o código copia e cola com o valor já preenchido. O código é gerado no iPhone; o app não fala com o banco e não confirma o pagamento: marque como pago quando o dinheiro cair.")
            }
            if let sample {
                Section {
                    Text(sample).font(.caption.monospaced()).textSelection(.enabled)
                    Button { UIPasteboard.general.string = sample; toaster.show("Código copiado.") } label: {
                        Label("Copiar exemplo de R$ 150,00", systemImage: "doc.on.doc")
                    }
                } header: {
                    Text("Exemplo de copia e cola")
                } footer: {
                    Text("Para testar, cole no app do seu banco (Pix › Copia e cola) e confira o nome antes de pagar.")
                }
            }
        }
        .navigationTitle("Pix")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let s = store.db.settings
            key = s.pixKey
            name = s.pixName.isEmpty ? (store.db.fiscal.legalName.isEmpty ? store.db.professional.fullName : store.db.fiscal.legalName) : s.pixName
            city = s.pixCity.isEmpty ? (store.db.professional.office?.city ?? "") : s.pixCity
        }
        .onDisappear {
            store.update { db in
                db.settings.pixKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                db.settings.pixName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                db.settings.pixCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

// MARK: - Dias de atendimento, feriados e intervalos

struct AgendaSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var editingHoliday: CustomHoliday?
    @State private var editingBreak: WorkBreak?

    private let weekdays = [(1, "Segunda"), (2, "Terça"), (3, "Quarta"), (4, "Quinta"), (5, "Sexta"), (6, "Sábado"), (0, "Domingo")]

    var body: some View {
        let s = store.db.settings
        let year = Calendar.current.component(.year, from: Date())
        let upcoming = (Holidays.list(year, settings: s) + Holidays.list(year + 1, settings: s))
            .filter { $0.date >= Calendar.current.startOfDay(for: Date()) }.prefix(8)
        Form {
            Section {
                ForEach(weekdays, id: \.0) { d in
                    Toggle(d.1, isOn: Binding(get: { s.workDays.contains(d.0) }, set: { on in
                        store.update { db in
                            if on { db.settings.workDays = Array(Set(db.settings.workDays + [d.0])).sorted() } else { db.settings.workDays.removeAll { $0 == d.0 } }
                        }
                    }))
                }
            } header: {
                Text("Dias de atendimento")
            } footer: {
                Text("Retornos e atendimentos recorrentes que caem num dia sem atendimento, num fim de semana ou num feriado voltam para o dia útil anterior, com a sua aprovação.")
            }
            Section {
                Toggle("Carnaval e Corpus Christi são folga", isOn: Binding(get: { s.optionalHolidaysOff }, set: { v in store.update { $0.settings.optionalHolidaysOff = v } }))
                ForEach(Array(upcoming), id: \.date) { h in
                    LabeledContent(h.name, value: Formatters.shortDate.string(from: h.date))
                }
            } header: {
                Text("Feriados nacionais")
            } footer: {
                Text("Conforme a Portaria MGI nº 11.460/2025. Carnaval e Corpus Christi são pontos facultativos.")
            }
            Section {
                ForEach(s.customHolidays) { h in
                    Button { editingHoliday = h } label: {
                        LabeledContent(h.name.isEmpty ? "Feriado" : h.name,
                                       value: h.yearly ? Formatters.dayMonth.string(from: h.date) + " (todo ano)" : Formatters.shortDate.string(from: h.date))
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in store.update { db in db.settings.customHolidays.remove(atOffsets: idx) } }
                Button { editingHoliday = CustomHoliday(date: Date()) } label: { Label("Incluir feriado próprio", systemImage: "plus") }
            } header: {
                Text("Feriados próprios")
            } footer: {
                Text("Feriados do estado, do município, férias ou recesso.")
            }
            Section {
                ForEach(s.breaks) { b in
                    Button { editingBreak = b } label: {
                        LabeledContent(b.title, value: "\(b.timeRange) · \(WorkBreaks.daysLabel(b))")
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { idx in store.update { db in db.settings.breaks.remove(atOffsets: idx) } }
                Button { editingBreak = WorkBreak() } label: { Label("Incluir intervalo", systemImage: "plus") }
            } header: {
                Text("Intervalos sem atendimento")
            } footer: {
                Text("Ex.: almoço. A agenda mostra o intervalo listrado e o app avisa antes de marcar um atendimento nele.")
            }
        }
        .navigationTitle("Dias e feriados")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingHoliday) { h in
            HolidayEditor(holiday: h) { saved in
                store.update { db in
                    if let i = db.settings.customHolidays.firstIndex(where: { $0.id == saved.id }) { db.settings.customHolidays[i] = saved } else { db.settings.customHolidays.append(saved) }
                }
            }
        }
        .sheet(item: $editingBreak) { b in
            BreakEditor(workBreak: b) { saved in
                store.update { db in
                    if let i = db.settings.breaks.firstIndex(where: { $0.id == saved.id }) { db.settings.breaks[i] = saved } else { db.settings.breaks.append(saved) }
                }
            }
        }
    }
}

struct HolidayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var holiday: CustomHoliday
    let onSave: (CustomHoliday) -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome (ex.: Aniversário da cidade)", text: $holiday.name)
                DatePicker("Data", selection: $holiday.date, displayedComponents: .date).environment(\.locale, Formatters.locale)
                Toggle("Repete todo ano", isOn: $holiday.yearly)
            }
            .navigationTitle("Feriado")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { onSave(holiday); dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}

struct BreakEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var workBreak: WorkBreak
    let onSave: (WorkBreak) -> Void
    private let weekdays = [(1, "seg"), (2, "ter"), (3, "qua"), (4, "qui"), (5, "sex"), (6, "sáb"), (0, "dom")]

    private func time(_ minutes: Int) -> Date {
        Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    private func minutes(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome (ex.: Almoço)", text: $workBreak.name)
                DatePicker("Início", selection: Binding(get: { time(workBreak.startMinutes) }, set: { workBreak.startMinutes = minutes($0) }),
                           displayedComponents: .hourAndMinute)
                DatePicker("Fim", selection: Binding(get: { time(workBreak.endMinutes) }, set: { workBreak.endMinutes = minutes($0) }),
                           displayedComponents: .hourAndMinute)
                if !workBreak.isValid { Text("O fim precisa ser depois do início.").font(.caption).foregroundStyle(Theme.unpaid) }
                Section {
                    HStack(spacing: 4) {
                        ForEach(weekdays, id: \.0) { d in
                            let on = workBreak.days.contains(d.0)
                            Button {
                                if on { workBreak.days.removeAll { $0 == d.0 } } else { workBreak.days.append(d.0) }
                            } label: {
                                Text(d.1).font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .background(on ? Theme.plum : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                                    .foregroundStyle(on ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Dias")
                } footer: {
                    Text("Nenhum dia marcado = todos os dias.")
                }
            }
            .environment(\.locale, Formatters.locale)
            .navigationTitle("Intervalo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { onSave(workBreak); dismiss() }.disabled(!workBreak.isValid) }
            }
        }
    }
}

// MARK: - Certificados digitais

extension UTType {
    static let pfxFile = UTType(filenameExtension: "pfx") ?? .data
    static let p12File = UTType(filenameExtension: "p12") ?? .data
}

struct CertificatesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @State private var importing = false
    @State private var pendingFile: Data?
    @State private var password = ""
    @State private var askPassword = false
    @State private var remember = false
    @State private var errorText: String?
    @State private var removing: CertificateEntry?

    var body: some View {
        let now = Date()
        List {
            if store.db.certificates.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        EmptyStateView(symbol: "checkmark.seal", title: "Nenhum certificado",
                                       message: "Adicione o certificado A1 (arquivo .pfx ou .p12) para emitir NFS-e pelo app.")
                        Button { importing = true } label: { Label("Adicionar certificado A1", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.db.certificates) { c in
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(c.holderName).font(.headline)
                            Spacer()
                            if c.isDefault { StatusBadge(text: "Padrão", color: Theme.plum) }
                        }
                        Text("\(c.typeLabel) · \(c.kindLabel)").font(.subheadline).foregroundStyle(.secondary)
                        Text("Emitido por \(c.issuer)").font(.caption).foregroundStyle(.secondary)
                        if c.isExpired(now: now) {
                            Text("Venceu em \(Formatters.shortDate.string(from: c.notAfter))").font(.caption.weight(.semibold)).foregroundStyle(Theme.unpaid)
                        } else {
                            Text("Válido até \(Formatters.shortDate.string(from: c.notAfter))\(c.expiresSoon(now: now) ? " · vence em \(c.daysLeft(now: now)) dias" : "")")
                                .font(.caption).foregroundStyle(c.expiresSoon(now: now) ? .orange : .secondary)
                        }
                        if !c.canSignOnThisDevice {
                            Text("Certificado A3 (token ou cartão): o iPhone não tem driver para ele.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !c.isIcpBrasil {
                            Text("Este certificado não é da ICP-Brasil: o Sistema Nacional da NFS-e pode recusar.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if !c.isDefault && c.canSignOnThisDevice { Button("Usar como padrão") { store.setDefaultCertificate(c.id) } }
                    if c.canSignOnThisDevice {
                        if CertificateKeys.savedPassword(for: c.id) != nil {
                            Button("Esquecer a senha guardada") {
                                CertificateKeys.forgetPassword(for: c.id)
                                toaster.show("A senha será pedida a cada assinatura.")
                            }
                        }
                    }
                    Button("Remover", role: .destructive) { removing = c }
                }
            }
            if !store.db.certificates.isEmpty {
                Section {
                    Button { importing = true } label: { Label("Adicionar certificado A1", systemImage: "plus") }
                } footer: {
                    Text("O arquivo do certificado fica cifrado dentro do app. A senha só é guardada se você pedir, no Keychain deste iPhone (não vai para backups nem para outros aparelhos).")
                }
            }
        }
        .navigationTitle("Certificados digitais")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pkcs12, .pfxFile, .p12File, .data]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingFile = try? Data(contentsOf: url)
            password = ""
            remember = false
            if pendingFile != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { askPassword = true } }
        }
        .sheet(isPresented: $askPassword) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Senha do certificado", text: $password)
                        Toggle("Guardar a senha neste iPhone", isOn: $remember)
                    } footer: {
                        Text("Sem guardar, o app pede a senha a cada assinatura.")
                    }
                }
                .navigationTitle("Senha do certificado")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { askPassword = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("Adicionar") { add() }.disabled(password.isEmpty) }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Não foi possível adicionar", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Remover o certificado?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { c in
            Button("Remover \(c.holderName)", role: .destructive) {
                CertificateKeys.forgetPassword(for: c.id)
                store.removeCertificate(c.id)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("As notas já emitidas continuam válidas.")
        }
    }

    private func add() {
        guard let file = pendingFile else { return }
        do {
            let open = try CertificateKeys.open(pfx: file, password: password)
            let entry = try store.addCertificate(open.info.entry(kind: .a1), pfx: file)
            if remember { CertificateKeys.savePassword(password, for: entry.id) }
            askPassword = false
            pendingFile = nil
            toaster.show("Certificado de \(entry.holderName) adicionado.")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Cabeçalho e rodapé

struct DocumentLayoutView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @State private var headerItem: PhotosPickerItem?
    @State private var footerItem: PhotosPickerItem?
    @State private var preview = false

    var body: some View {
        let layout = store.db.settings.documentLayout
        Form {
            band("Cabeçalho", layout.header, header: true, item: $headerItem)
            band("Rodapé", layout.footer, header: false, item: $footerItem)
            Section {
                Button { preview = true } label: { Label("Ver um exemplo em PDF", systemImage: "doc.richtext") }
            } footer: {
                Text("Vale para os PDFs de recibos, relatórios e anotações.")
            }
        }
        .navigationTitle("Cabeçalho e rodapé")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: headerItem) { _, item in load(item, header: true) }
        .onChange(of: footerItem) { _, item in load(item, header: false) }
        .exportFlow(isPresented: $preview, allowsPassword: false, fileName: "Exemplo-recibo.pdf", makeData: {
            let p = Patient(name: "\(Term.Client) de exemplo")
            let text = PDFExporter.receiptDocument(patient: p, items: [("Atendimento em \(Formatters.dateTime.string(from: Date()))", 15_000)],
                                                   paidAt: Date(), method: .pix, db: store.db)
            return PDFExporter.render(text, footer: "Recibo", letterhead: PDFExporter.letterhead(store))
        }, onExported: {})
    }

    @ViewBuilder
    private func band(_ title: String, _ b: DocumentBand, header: Bool, item: Binding<PhotosPickerItem?>) -> some View {
        Section(title) {
            TextField("Texto (ex.: nome, endereço, telefone)", text: Binding(get: { b.text }, set: { v in
                store.update { db in if header { db.settings.documentLayout.header.text = v } else { db.settings.documentLayout.footer.text = v } }
            }), axis: .vertical)
            .lineLimit(2...6)
            if let data = store.documentImage(b), let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 80)
                Stepper("Altura da imagem: \(Int(b.imageHeightMm)) mm", value: Binding(get: { b.imageHeightMm }, set: { v in
                    store.update { db in if header { db.settings.documentLayout.header.imageHeightMm = v } else { db.settings.documentLayout.footer.imageHeightMm = v } }
                }), in: 8...60, step: 2)
                Button("Remover imagem", role: .destructive) { try? store.setDocumentImage(header: header, image: nil, name: "") }
            }
            PhotosPicker(selection: item, matching: .images) {
                Label(b.imageID == nil ? "Escolher imagem (timbre)" : "Trocar imagem", systemImage: "photo")
            }
        }
    }

    private func load(_ item: PhotosPickerItem?, header: Bool) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
               let png = img.pngData() {
                try? store.setDocumentImage(header: header, image: png, name: header ? "cabecalho.png" : "rodape.png")
                toaster.show("Imagem salva.")
            }
        }
    }
}

// MARK: - Mensagens do WhatsApp

struct WhatsAppMessageView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var charge = ""
    @State private var loaded = false
    @State private var confirmRestore = false

    private var sampleStart: Date {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: tomorrow) ?? Date()
    }

    var body: some View {
        Form {
            Section {
                TextField(WhatsAppMessage.defaultTemplate, text: $text, axis: .vertical)
                    .lineLimit(3...10)
                    .onChange(of: text) { _, t in save(t) }
                FieldButtons(text: $text, fields: [WhatsAppMessage.nameField, WhatsAppMessage.dateField,
                                                   WhatsAppMessage.timeField, WhatsAppMessage.placeField])
            } header: {
                Text("Confirmação do horário")
            } footer: {
                Text("\(WhatsAppMessage.nameField) vira o primeiro nome do \(Term.client); \(WhatsAppMessage.dateField), \"hoje\", \"amanhã\" ou o dia; \(WhatsAppMessage.timeField), o horário; \(WhatsAppMessage.placeField), o local. Salvo automaticamente. Cada tag pode ter a própria mensagem (Ajustes › Tags).")
            }
            Section("Como chega para o \(Term.client)") {
                Text(WhatsAppMessage.compose(text, firstName: "Ana", start: sampleStart, place: "Rua das Flores, 100"))
                    .padding(12)
                    .background(Theme.whatsApp.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
            Section {
                TextField(WhatsAppMessage.chargeTemplate(AppSettings()), text: $charge, axis: .vertical)
                    .lineLimit(3...10)
                    .onChange(of: charge) { _, t in saveCharge(t) }
                FieldButtons(text: $charge, fields: [WhatsAppMessage.nameField, WhatsAppMessage.valueField,
                                                     WhatsAppMessage.dateField, WhatsAppMessage.pixField])
            } header: {
                Text("Cobrança")
            } footer: {
                Text("Usada no botão Cobrar. \(WhatsAppMessage.valueField) vira o valor; \(WhatsAppMessage.dateField), a data do atendimento; \(WhatsAppMessage.pixField), o Pix copia e cola com o valor (Ajustes › Pix). Em branco, vale a mensagem padrão.")
            }
            Section {
                Text("1. Na agenda, cada atendimento de hoje em diante tem o botão verde do WhatsApp; os já realizados e não pagos têm o botão Cobrar.")
                Text("2. O botão abre o WhatsApp na conversa do \(Term.client), com a mensagem já escrita.")
                Text("3. Confira, mude o que quiser e aperte enviar no próprio WhatsApp.")
                Text("4. O número é o do cadastro do \(Term.client), com o +55 e o DDD. Sem telefone ou sem DDD, o botão avisa o que falta.")
            } header: {
                Text("Como funciona")
            } footer: {
                Text("Nada é enviado sozinho: o Expediente não usa a API da Meta nem servidor.")
            }
            .font(.subheadline)
            Section {
                Button("Voltar às mensagens padrão") { confirmRestore = true }
                    .disabled(store.db.settings.whatsAppTemplate.isEmpty && store.db.settings.chargeTemplate.isEmpty)
            }
        }
        .navigationTitle("Mensagens do WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            text = WhatsAppMessage.template(store.db.settings)
            charge = store.db.settings.chargeTemplate
        }
        .alert("Voltar às mensagens padrão?", isPresented: $confirmRestore) {
            Button("Usar as padrão") {
                text = WhatsAppMessage.defaultTemplate
                charge = ""
            }
            Button("Cancelar", role: .cancel) {}
        } message: { Text("“\(WhatsAppMessage.defaultTemplate)”") }
    }

    /// Igual à padrão = guarda vazio (acompanha a padrão se ela mudar numa versão nova).
    private func save(_ t: String) {
        let trimmed = String(t.prefix(WhatsAppMessage.maxTemplateLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty || trimmed == WhatsAppMessage.defaultTemplate ? "" : trimmed
        if value != store.db.settings.whatsAppTemplate { store.update { $0.settings.whatsAppTemplate = value } }
    }

    private func saveCharge(_ t: String) {
        let value = String(t.prefix(WhatsAppMessage.maxTemplateLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        if value != store.db.settings.chargeTemplate { store.update { $0.settings.chargeTemplate = value } }
    }
}

// MARK: - NFS-e

struct NfseSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var f = FiscalProfile()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Picker("Ambiente", selection: $f.environment) {
                    ForEach(NfseEnvironment.allCases) { Text($0.shortLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(f.environment.label).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Sistema Nacional da NFS-e")
            } footer: {
                Text("Comece em homologação (testes). Nesta versão, a emissão pelo app atende só prestadores de \(Nfse.santoAndreName) optantes pelo Simples Nacional. Nos demais casos, use o controle de notas e o atalho para o Emissor Nacional.")
            }
            Section("Prestador") {
                MaskedField(title: "CNPJ", kind: .cnpj, text: $f.document)
                TextField("Razão social", text: $f.legalName)
                TextField("Inscrição municipal", text: $f.municipalRegistration).keyboardType(.numbersAndPunctuation)
                PhoneField(title: "Telefone", text: $f.fiscalPhone)
                TextField("E-mail", text: $f.fiscalEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                Picker("Simples Nacional", selection: $f.simplesOption) {
                    Text("ME/EPP").tag(3)
                    Text("MEI").tag(2)
                    Text("Não optante").tag(1)
                }
            }
            Section {
                TextField("Código de tributação nacional (6 dígitos)", text: $f.nationalTaxCode).keyboardType(.numberPad)
                Text("Informado: \(Nfse.taxCodeLabel(Nfse.onlyDigits(f.nationalTaxCode)))").font(.caption).foregroundStyle(.secondary)
                TextField("Código NBS (opcional, 9 dígitos)", text: $f.nbsCode).keyboardType(.numberPad)
                TextField("Tributos aproximados no Simples (%, opcional)", text: $f.approxTaxPercent).keyboardType(.decimalPad)
                TextField("Descrição na nota ({data} = dia do atendimento)", text: $f.nfseDescription, axis: .vertical)
            } header: {
                Text("Serviço")
            } footer: {
                Text("O código de tributação depende do serviço (ex.: 06.01.01 para cabeleireiros). Confirme os códigos com o seu contador.")
            }
            Section {
                TextField("Série da DPS", text: $f.dpsSeries).keyboardType(.numberPad)
                Picker("Certificado", selection: $f.certificateID) {
                    Text("O padrão").tag(UUID?.none)
                    ForEach(store.db.certificates.filter(\.canSignOnThisDevice)) { Text($0.holderName).tag(UUID?.some($0.id)) }
                }
            } header: {
                Text("Envio")
            } footer: {
                Text("Se você também emite notas por outro sistema, use uma série diferente aqui. Antes de cada número novo o app confere no Sistema Nacional se ele já foi usado.")
            }
        }
        .navigationTitle("NFS-e")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            f = store.db.fiscal
            f.fiscalPhone = Masks.phoneWithPrefix(f.fiscalPhone)
        }
        .onDisappear {
            var g = f
            g.fiscalPhone = Masks.phoneToSave(g.fiscalPhone)
            if g.document.count == 18 { g.personType = .company }
            store.update { $0.fiscal = g }
        }
    }
}
