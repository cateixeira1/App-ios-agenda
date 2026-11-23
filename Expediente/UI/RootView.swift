import SwiftUI

enum Route: Hashable {
    case agenda(Date)
    case patients
    case patient(UUID)
    case patientHistory(UUID)
    case notes
    case patientNotes(UUID)
    case noteForAppointment(UUID)
    case note(UUID)
    case newNote(patientID: UUID)
    case finance
    case reports
    case invoices
    case settings
    case auditLog
    case tags
    case patientSessions(UUID)
    case agendaSettings
    case certificates
    case documentLayout
    case whatsAppMessage
    case nfseSettings
    case profile
    // Novidades do Expediente.
    case packages
    case package(UUID)
    case patientPackages(UUID)
    case expenses
    case pixSettings
}

/// Navegação e folhas abertas a partir de qualquer tela.
@MainActor
final class Router: ObservableObject {
    @Published var path: [Route] = []
    @Published var editor: AppointmentDraft?
    /// Blocos de funções (menu ☰ da agenda).
    @Published var showsMenu = false

    func open(_ r: Route) {
        showsMenu = false
        path.append(r)
    }

    func newAppointment(start: Date? = nil, patientID: UUID? = nil) {
        showsMenu = false
        editor = AppointmentDraft(appointmentID: nil, start: start, patientID: patientID)
    }

    func edit(_ appointmentID: UUID) {
        editor = AppointmentDraft(appointmentID: appointmentID, start: nil, patientID: nil)
    }
}

struct AppointmentDraft: Identifiable {
    let id = UUID()
    let appointmentID: UUID?
    let start: Date?
    let patientID: UUID?
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch app.phase {
            case .setup:
                SetupFlow()
            case .locked:
                LockView()
            case .unlocked:
                if let store = app.store {
                    MainView()
                        .environmentObject(store)
                } else {
                    LockView()
                }
            }
            // Esconde o conteúdo na troca de apps (miniatura do multitarefa).
            if scenePhase != .active && !app.isDemo {
                PrivacyCover()
            }
        }
        .tint(Theme.plum)
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Image("Logo").resizable().scaledToFit().frame(width: 120)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: Store
    @StateObject private var router = Router()
    @StateObject private var toaster = Toaster()

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
        .environmentObject(router)
        .environmentObject(toaster)
        .sheet(item: $router.editor) { draft in
            AppointmentEditor(draft: draft)
                .environmentObject(store)
                .environmentObject(router)
                .environmentObject(toaster)
        }
        .sheet(isPresented: $router.showsMenu) {
            FunctionMenu()
                .environmentObject(app)
                .environmentObject(store)
                .environmentObject(router)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .overlay { ToastOverlay(toaster: toaster) }
        .onAppear { DemoNavigator.apply(router: router, store: store) }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        RouteView(route: route)
    }
}

/// Tela de cada rota (usada na navegação principal e dentro das folhas, para o nome clicável funcionar em qualquer lugar).
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .agenda(let day): AgendaView(initialDay: day)
        case .patients: PatientsListView()
        case .patient(let id): PatientDetailView(patientID: id)
        case .patientHistory(let id), .patientSessions(let id): PatientSessionsView(patientID: id)
        case .notes: NotesHomeView()
        case .patientNotes(let id): PatientNotesView(patientID: id)
        case .noteForAppointment(let id): NoteEditorView(target: .appointment(id))
        case .note(let id): NoteEditorView(target: .existing(id))
        case .newNote(let pid): NoteEditorView(target: .newForPatient(pid))
        case .finance: FinanceView()
        case .reports: ReportsView()
        case .invoices: InvoicesView()
        case .settings: SettingsView()
        case .auditLog: AuditLogView()
        case .tags: TagsView()
        case .agendaSettings: AgendaSettingsView()
        case .certificates: CertificatesView()
        case .documentLayout: DocumentLayoutView()
        case .whatsAppMessage: WhatsAppMessageView()
        case .nfseSettings: NfseSettingsView()
        case .profile: ProfileView()
        case .packages: PackagesListView(patientID: nil)
        case .patientPackages(let id): PackagesListView(patientID: id)
        case .package(let id): PackageDetailView(packageID: id)
        case .expenses: ExpensesView()
        case .pixSettings: PixSettingsView()
        }
    }
}

extension View {
    /// Navegação para as rotas dentro de uma folha (ex.: o nome do cliente clicável no agendamento).
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteView(route: $0) }
    }
}
