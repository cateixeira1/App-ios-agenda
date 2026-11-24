import SwiftUI

enum EditorTarget: Hashable {
    case appointment(UUID)
    case existing(UUID)
    case newForPatient(UUID)
}

// MARK: - Bloco "Anotações"

struct NotesHomeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    @State private var query = ""

    var body: some View {
        let now = Date()
        let pending = Documentation.pending(in: store.db, now: now, days: 7)
        let patients = query.isEmpty ? store.activePatients : NameMatcher.suggestions(for: query, in: store.activePatients, limit: 100)
        List {
            if query.isEmpty && !pending.isEmpty {
                Section {
                    ForEach(pending.prefix(20)) { a in
                        Button { router.open(.noteForAppointment(a.id)) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(store.db.patient(a.patientID)?.name ?? Term.Client).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                    Text(Formatters.dateTime.string(from: a.start) + (store.db.tag(a.tagID).map { " · \($0.name)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.pencil").foregroundStyle(Theme.plum)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Atendimentos sem anotação (7 dias)")
                } footer: {
                    Text("Atendimentos já encerrados sem anotação com texto. Faltas e cancelamentos não aparecem.")
                }
            }
            Section(Term.Clients) {
                ForEach(patients) { p in
                    Button { router.open(.patientNotes(p.id)) } label: {
                        HStack {
                            Text(p.name).foregroundStyle(.primary)
                            Spacer()
                            let n = store.db.notes.filter { $0.patientID == p.id }.count
                            Text(n == 1 ? "1 anotação" : "\(n) anotações").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: max(36, store.db.settings.patientRowHeight - 16))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Buscar \(Term.client)")
        .navigationTitle("Anotações")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PatientNotesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: Router
    let patientID: UUID

    var body: some View {
        let notes = store.notes(of: patientID)
        List {
            if notes.isEmpty { EmptyStateView(symbol: "square.and.pencil", title: "Nenhuma anotação").listRowBackground(Color.clear) }
            ForEach(notes) { n in
                Button { router.open(.note(n.id)) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(appointmentID: n.appointmentID, fallback: n.createdAt)).font(.subheadline.weight(.semibold))
                        Text(n.body.plain.isEmpty ? "Sem texto" : n.body.plain).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(store.db.patient(patientID)?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.open(.newNote(patientID: patientID)) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Nova anotação")
            }
        }
    }

    private func title(appointmentID: UUID?, fallback: Date) -> String {
        if let a = store.appointment(appointmentID) { return "Atendimento de " + Formatters.dateTime.string(from: a.start) }
        return "Anotação de " + Formatters.dateTime.string(from: fallback)
    }
}

// MARK: - Anotação do atendimento

struct NoteEditorView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var toaster: Toaster
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget
    @State private var note: SessionNote?
    @State private var exporting = false
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let note {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            header(note)
                            RichTextEditor(initial: note.body, placeholder: "Anotações do atendimento…", minHeight: 360,
                                           autoFocus: note.body.isBlank) { rich in
                                self.note?.body = rich
                                persist()
                            }
                            .padding(10)
                            .cardStyle()
                            Text("Fica cifrada só neste aparelho. Use para o que foi feito, combinado ou pedido.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .background(Theme.background)
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Anotação")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { exporting = true } label: { Label("Exportar ou enviar PDF", systemImage: "square.and.arrow.up") }
                        .disabled(note?.body.isBlank ?? true)
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Excluir anotação", systemImage: "trash") }
                        .disabled(note.map { n in !store.db.notes.contains { $0.id == n.id } } ?? true)
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .exportFlow(isPresented: $exporting, fileName: exportName(), makeData: {
            guard let note else { return nil }
            return PDFExporter.render(PDFExporter.noteDocument(note, db: store.db), footer: "Anotação de atendimento")
        }, onExported: {
            store.audit(.recordExported, "Anotação de \(store.db.patient(note?.patientID)?.name ?? "")")
        })
        .confirmationDialog("Excluir esta anotação?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Excluir", role: .destructive) {
                if let id = note?.id { store.deleteNote(id) }
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        }
        .onAppear(perform: resolve)
        .onDisappear { store.flush() }
    }

    @ViewBuilder
    private func header(_ n: SessionNote) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.db.patient(n.patientID)?.name ?? "").font(.title3.bold())
            if let a = store.appointment(n.appointmentID) {
                Text("Atendimento de \(Formatters.dateTime.string(from: a.start))").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Criada em \(Formatters.dateTime.string(from: n.createdAt))").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func resolve() {
        guard note == nil else { return }
        switch target {
        case .existing(let id):
            note = store.db.notes.first { $0.id == id }
        case .appointment(let aid):
            if let existing = store.note(for: aid) {
                note = existing
            } else if let a = store.appointment(aid) {
                note = SessionNote(patientID: a.patientID, appointmentID: aid)
            }
        case .newForPatient(let pid):
            note = SessionNote(patientID: pid, appointmentID: nil)
        }
    }

    /// Só grava quando há texto, ou quando a anotação já existia.
    private func persist() {
        guard let note else { return }
        let exists = store.db.notes.contains { $0.id == note.id }
        if exists || !note.body.isBlank { store.saveNote(note) }
    }

    private func exportName() -> String {
        let name = FileNames.safe(store.db.patient(note?.patientID)?.name ?? Term.client)
        return "Anotacao-\(name)-\(Formatters.isoDay.string(from: note?.createdAt ?? Date())).pdf"
    }
}

