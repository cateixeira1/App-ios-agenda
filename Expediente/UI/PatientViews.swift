import ContactsUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Lista

struct PatientsListView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @State private var query = ""
    @State private var editing: Patient?
    @State private var showArchived = false

    var body: some View {
        let list = visiblePatients()
        let rowHeight = store.db.settings.patientRowHeight
        List {
            if list.isEmpty {
                EmptyStateView(symbol: "person.2", title: query.isEmpty ? "Nenhum \(Term.client)" : "Nenhum resultado",
                               message: query.isEmpty ? "Toque em + para cadastrar ou importar dos Contatos." : nil)
                    .listRowBackground(Color.clear)
            }
            ForEach(list) { p in
                Button { router.open(.patient(p.id)) } label: {
                    PatientRow(patient: p)
                        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
        }
        .searchable(text: $query, prompt: "Buscar \(Term.client)")
        .navigationTitle(showArchived ? "Arquivados" : Term.Clients)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editing = Patient(name: "") } label: { Label("Novo \(Term.client)", systemImage: "person.badge.plus") }
                    Button { importFromContacts() } label: { Label("Importar dos Contatos", systemImage: "person.crop.circle.badge.plus") }
                    Divider()
                    Toggle(isOn: $showArchived) { Label("Mostrar arquivados", systemImage: "archivebox") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Adicionar \(Term.client)")
            }
        }
        .sheet(item: $editing) { p in
            PatientEditor(patient: p, isNew: store.db.patient(p.id) == nil)
                .environmentObject(store)
                .environmentObject(toaster)
        }
    }
}

extension PatientsListView {
    func visiblePatients() -> [Patient] {
        let base: [Patient] = showArchived
            ? store.db.patients.filter(\.archived).sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            : store.activePatients
        guard !query.isEmpty else { return base }
        if showArchived {
            return base.filter { NameMatcher.score(query: query, name: $0.name) != nil }
        }
        return NameMatcher.suggestions(for: query, in: base, limit: 100)
    }

    func importFromContacts() {
        ContactPickerPresenter.present { contact in
            guard let contact else { return }
            let c = ContactsBridge.imported(from: contact)
            var p = Patient(name: c.name)
            p.phone = Masks.phone(c.phone)
            p.email = c.email
            editing = p
        }
    }
}

struct PatientRow: View {
    @EnvironmentObject var store: Store
    let patient: Patient

    var body: some View {
        let next = store.db.nextSession(of: patient.id)
        HStack(spacing: 12) {
            Text(initials(patient.name))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Theme.plum.opacity(0.85), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(patient.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                if let next {
                    Text("Próximo: \(Formatters.dateTime.string(from: next.start))").font(.caption).foregroundStyle(.secondary)
                } else if !patient.phone.isEmpty {
                    Text(patient.phone).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.count > 1 ? (parts.last?.first.map(String.init) ?? "") : ""
        return (first + last).uppercased()
    }
}

// MARK: - Cadastro

struct PatientEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    @State var patient: Patient
    let isNew: Bool
    @State private var hasBirthDate = false
    @State private var birth = Calendar.current.date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var priceText = ""
    @State private var address = PostalAddress()

    init(patient: Patient, isNew: Bool) {
        var p = patient
        p.phone = Masks.phoneWithPrefix(p.phone)
        _patient = State(initialValue: p)
        self.isNew = isNew
        _hasBirthDate = State(initialValue: patient.birthDate != nil)
        if let b = patient.birthDate { _birth = State(initialValue: b) }
        _priceText = State(initialValue: Formatters.moneyMasked(patient.sessionPriceCents))
        // Endereço antigo (um texto só): vai inteiro para o logradouro e só muda se for editado.
        _address = State(initialValue: patient.addressParts ?? (patient.address.isEmpty ? PostalAddress() : PostalAddress.fromLegacy(patient.address)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nome completo", text: $patient.name).textInputAutocapitalization(.words)
                    PhoneField(title: "Telefone", text: $patient.phone)
                    TextField("E-mail", text: $patient.email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    MaskedField(title: "CPF (para nota fiscal)", kind: .cpf, text: $patient.cpf)
                    Toggle("Data de nascimento", isOn: $hasBirthDate)
                    if hasBirthDate {
                        DatePicker("Nascimento", selection: $birth, in: ...Date(), displayedComponents: .date)
                            .environment(\.locale, Formatters.locale)
                    }
                } header: {
                    Text(Term.Client)
                } footer: {
                    Text("O telefone já vem com o +55: digite o DDD e o número. Os botões do WhatsApp da agenda usam este telefone.")
                }
                Section {
                    AddressFields(address: $address, lookupEnabled: store.db.settings.cepLookup)
                } header: {
                    Text("Endereço")
                } footer: {
                    Text(store.db.settings.cepLookup ? "Ao completar o CEP, o app busca o endereço no ViaCEP (só o CEP é enviado)." : "Busca pelo CEP desligada em Ajustes › Segurança.")
                }
                Section {
                    TextField("Nome do responsável", text: $patient.guardianName).textInputAutocapitalization(.words)
                    PhoneField(title: "Telefone do responsável", text: $patient.guardianPhone)
                    MaskedField(title: "CPF do responsável (nota fiscal em nome de quem paga)", kind: .cpf, text: $patient.guardianCpf)
                } header: {
                    Text("Responsável")
                } footer: {
                    Text("Para \(Term.clients) menores de idade, ou quando outra pessoa paga ou acompanha.")
                }
                Section {
                    HStack {
                        Text("Valor do atendimento")
                        Spacer()
                        MoneyField(Formatters.moneyPlaceholder(store.db.settings.defaultPriceCents), text: $priceText)
                    }
                } header: {
                    Text("Valor")
                } footer: {
                    if store.db.settings.priceByClient {
                        Text("Valor por cliente ligado: este valor vale em todos os atendimentos deste \(Term.client), qualquer que seja a tag. Em branco, vale o valor padrão de Ajustes.")
                    } else {
                        Text("Opcional. Usado quando o atendimento e a tag não têm valor.")
                    }
                }
                Section("Observações") {
                    TextField("Preferências, alergias a produtos, como chegar…", text: $patient.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(isNew ? "Novo \(Term.client)" : "Editar \(Term.client)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salvar") { save() }
                        .disabled(patient.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        patient.name = patient.name.trimmingCharacters(in: .whitespacesAndNewlines)
        patient.phone = Masks.phoneToSave(patient.phone)
        patient.guardianPhone = Masks.phoneToSave(patient.guardianPhone)
        patient.birthDate = hasBirthDate ? birth : nil
        patient.sessionPriceCents = Formatters.parseMoney(priceText)
        let original = store.db.patient(patient.id)
        let unchangedLegacy = original?.addressParts == nil && address == PostalAddress.fromLegacy(original?.address)
        if !unchangedLegacy || original == nil {
            patient.addressParts = address.isEmpty ? nil : address
            patient.address = address.compose()
        }
        if isNew {
            store.addPatient(patient)
            toaster.show("\(patient.name) cadastrado.")
        } else {
            store.updatePatient(patient)
        }
        dismiss()
    }
}

// MARK: - Ficha do cliente

struct PatientDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    let patientID: UUID
    @State private var editing: Patient?
    @State private var showImporter = false
    @State private var preview: URL?
    @State private var confirmDelete = false
    @State private var confirmRemoveConsent = false
    @State private var returnFrom: Appointment?

    var body: some View {
        if let p = store.db.patient(patientID) {
            content(p)
        } else {
            EmptyStateView(symbol: "person.crop.circle.badge.xmark", title: "\(Term.Client) não encontrado")
        }
    }

    private func content(_ p: Patient) -> some View {
        let sessions = store.db.appointments(of: p.id)
        let now = Date()
        let open = Finance.open(store.db, now: now).filter { $0.patientID == p.id }
        let openValue = open.reduce(0) { $0 + store.db.price(of: $1) }
        let last = store.db.lastSession(of: p.id, before: now)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(.title2.bold())
                    if !p.phone.isEmpty { Text(p.phone).foregroundStyle(.secondary) }
                    if !p.email.isEmpty { Text(p.email).foregroundStyle(.secondary) }
                    if p.archived { StatusBadge(text: "Arquivado", color: .secondary) }
                }
                .padding(.vertical, 4)
                HStack(spacing: 10) {
                    Button { router.newAppointment(patientID: p.id) } label: {
                        Label("Agendar", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                    }
                    Button { router.open(.patientNotes(p.id)) } label: {
                        Label("Anotações", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .listRowSeparator(.hidden)
            }

            Section {
                let pkgs = Packages.of(p.id, in: store.db)
                ForEach(pkgs.prefix(3)) { pkg in
                    Button { router.open(.package(pkg.id)) } label: { PackageRow(package: pkg) }
                        .buttonStyle(.plain)
                }
                Button { router.open(.patientPackages(p.id)) } label: {
                    Label(pkgs.isEmpty ? "Vender pacote" : "Todos os pacotes (\(pkgs.count))", systemImage: "square.stack.3d.up")
                }
            } header: {
                Text("Pacotes")
            }

            Section("Atendimentos") {
                Button { router.open(.patientSessions(p.id)) } label: {
                    HStack {
                        Label("Atendimentos do \(Term.client)", systemImage: "list.bullet.rectangle")
                        Spacer()
                        Text("\(sessions.count)").foregroundStyle(.secondary)
                    }
                }
                if let last {
                    LabeledContent("Último atendimento", value: Formatters.dateTime.string(from: last.start))
                    Button { returnFrom = last } label: { Label("Agendar retorno", systemImage: "arrow.uturn.forward.circle") }
                }
                if let next = store.db.nextSession(of: p.id, after: now) {
                    LabeledContent("Próximo atendimento", value: Formatters.dateTime.string(from: next.start))
                }
                if openValue > 0 || !open.isEmpty {
                    LabeledContent("Em aberto") {
                        Text("\(Formatters.money(openValue)) (\(open.count))").foregroundStyle(Theme.unpaid)
                    }
                    Button {
                        if let url = WhatsAppMessage.chargeLink(for: open, in: store.db) { UIApplication.shared.open(url) }
                    } label: { Label("Cobrar em aberto pelo WhatsApp", systemImage: "brazilianrealsign.circle") }
                    .disabled(WhatsAppMessage.chargeLink(for: open, in: store.db) == nil)
                }
            }

            Section {
                if let att = p.consent {
                    Button { openConsent(att) } label: {
                        HStack {
                            Image(systemName: att.fileName.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                                .foregroundStyle(Theme.plum)
                            VStack(alignment: .leading) {
                                Text(att.fileName).foregroundStyle(.primary).lineLimit(1)
                                Text("Anexado em \(Formatters.shortDate.string(from: att.addedAt))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Substituir arquivo") { showImporter = true }
                    Button("Remover", role: .destructive) { confirmRemoveConsent = true }
                } else {
                    Button { showImporter = true } label: { Label("Anexar documento (PDF, Word ou imagem)", systemImage: "paperclip") }
                }
            } header: {
                Text("Contrato ou documento")
            } footer: {
                Text("Contrato, termo, ficha de anamnese ou orçamento. O arquivo fica cifrado no aparelho.")
            }

            if !p.guardianName.isEmpty || !p.cpf.isEmpty || p.birthDate != nil || !p.address.isEmpty || !p.notes.isEmpty || p.sessionPriceCents != nil || !p.guardianCpf.isEmpty {
                Section("Dados") {
                    if let b = p.birthDate { LabeledContent("Nascimento", value: Formatters.shortDate.string(from: b)) }
                    if !p.cpf.isEmpty { LabeledContent("CPF", value: p.cpf) }
                    if let price = p.sessionPriceCents { LabeledContent("Valor do atendimento", value: Formatters.money(price)) }
                    if !p.guardianName.isEmpty { LabeledContent("Responsável", value: "\(p.guardianName) \(p.guardianPhone)") }
                    if !p.guardianCpf.isEmpty { LabeledContent("CPF do responsável", value: p.guardianCpf) }
                    if !p.address.isEmpty { LabeledContent("Endereço", value: p.address) }
                    if !p.notes.isEmpty { Text(p.notes).font(.subheadline) }
                }
            }

            Section {
                Button { exportToContacts(p) } label: { Label("Salvar nos Contatos do iPhone", systemImage: "person.crop.circle.badge.checkmark") }
                Button {
                    var q = p
                    q.archived.toggle()
                    store.updatePatient(q)
                    toaster.show(q.archived ? "\(Term.Client) arquivado." : "\(Term.Client) reativado.")
                } label: {
                    Label(p.archived ? "Reativar \(Term.client)" : "Arquivar \(Term.client)", systemImage: "archivebox")
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Excluir \(Term.client)", systemImage: "trash") }
            }
        }
        .navigationTitle(p.firstName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Editar") { editing = p } }
        }
        .sheet(item: $editing) { patient in
            PatientEditor(patient: patient, isNew: false).environmentObject(store).environmentObject(toaster)
        }
        .sheet(item: $returnFrom) { a in
            ReturnSheet(from: a) { created in
                returnFrom = nil
                toaster.show("Retorno agendado para \(Formatters.dateTime.string(from: created.start)).")
            }
            .environmentObject(store)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: consentTypes) { result in
            importConsent(result, patient: p)
        }
        .quickLookPreview($preview)
        .confirmationDialog("Excluir \(p.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir \(Term.client) e todos os registros", role: .destructive) {
                store.deletePatient(p.id)
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(deleteMessage(last: last))
        }
        .confirmationDialog("Remover o documento?", isPresented: $confirmRemoveConsent, titleVisibility: .visible) {
            Button("Remover", role: .destructive) { store.removeConsent(from: p.id) }
            Button("Manter", role: .cancel) {}
        }
    }

    private var consentTypes: [UTType] {
        var types: [UTType] = [.pdf, .rtf, .plainText, .image]
        for ext in ["doc", "docx"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        return types
    }

    private func deleteMessage(last: Appointment?) -> String {
        var text = "Anotações, atendimentos, pacotes e documentos deste \(Term.client) serão apagados deste aparelho. Se quiser só tirar da lista, use Arquivar."
        if last != nil {
            text += " Se a sua profissão tem prazo de guarda de registros, confira antes de excluir."
        }
        return text
    }

    private func importConsent(_ result: Result<URL, Error>, patient: Patient) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            try store.attachConsent(data, fileName: url.lastPathComponent, to: patient.id)
            toaster.show("Documento anexado.")
        } catch {
            toaster.show("Não foi possível anexar o arquivo.")
        }
    }

    private func openConsent(_ att: Attachment) {
        do {
            let data = try store.consentData(att)
            let url = TemporaryFiles.write(data, name: att.fileName)
            preview = url
        } catch {
            toaster.show("Não foi possível abrir o arquivo.")
        }
    }

    private func exportToContacts(_ p: Patient) {
        Task {
            switch await ContactsBridge.export(p) {
            case .saved: toaster.show("Contato salvo no app Contatos.")
            case .denied: toaster.show("Permita o acesso aos Contatos em Ajustes do iPhone › Expediente.")
            case .failed: toaster.show("Não foi possível salvar o contato.")
            }
        }
    }
}

// MARK: - Contatos

/// Seletor de contatos do iOS. Não pede permissão: só o contato escolhido chega ao app.
/// Ele precisa ser apresentado direto pelo UIKit (dentro de uma folha do SwiftUI ele fecha sozinho).
enum ContactPickerPresenter {
    private static var current: Delegate?

    static func present(onPick: @escaping (CNContact?) -> Void) {
        let picker = CNContactPickerViewController()
        let delegate = Delegate { contact in
            onPick(contact)
            current = nil
        }
        current = delegate
        picker.delegate = delegate
        UIApplication.topViewController()?.present(picker, animated: true)
    }

    final class Delegate: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact?) -> Void
        init(onPick: @escaping (CNContact?) -> Void) { self.onPick = onPick }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) { onPick(contact) }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { onPick(nil) }
    }
}

extension UIApplication {
    static func topViewController() -> UIViewController? {
        let window = shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Arquivos temporários para visualizar ou compartilhar. Apagados ao bloquear e ao abrir o app.
enum TemporaryFiles {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("compartilhar", isDirectory: true)
    }

    static func write(_ data: Data, name: String) -> URL {
        let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let url = dir.appendingPathComponent(safe)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
