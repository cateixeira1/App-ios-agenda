import SwiftUI

extension Theme {
    /// Desmarcada com aviso (cinza-azulado, diferente de falta).
    static let cancelled = Color(red: 0.42, green: 0.48, blue: 0.56)
    /// Verde do botão do WhatsApp.
    static let whatsApp = Color(red: 0.145, green: 0.827, blue: 0.4)
}

// MARK: - Campos com máscara

/// Campo de telefone, CPF, CNPJ ou CEP: pontua enquanto se digita e limita os caracteres.
struct MaskedField: View {
    let title: String
    let kind: MaskKind
    @Binding var text: String
    var prompt: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: Binding(get: { text }, set: { text = Masks.format(kind, $0) }), prompt: prompt.map(Text.init))
                .keyboardType(kind == .phone ? .phonePad : (kind == .cnpj ? .asciiCapable : .numberPad))
                .textInputAutocapitalization(kind == .cnpj ? .characters : .never)
                .autocorrectionDisabled()
            if let problem = Masks.problem(kind, text) {
                Text(problem).font(.caption).foregroundStyle(Theme.unpaid)
            } else if kind == .phone && !Masks.isCompletePhone(Masks.phoneToSave(text)) {
                Text("Telefone incompleto.").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

/// Telefone do paciente: já começa com o +55; o profissional digita o DDD e o número.
struct PhoneField: View {
    let title: String
    @Binding var text: String

    var body: some View {
        MaskedField(title: title, kind: .phone, text: Binding(get: { Masks.phoneWithPrefix(text) }, set: { new in
            // Apagar tudo deixa só o +55 (o campo nunca fica sem o código do país).
            let t = new.trimmingCharacters(in: .whitespaces)
            text = t.isEmpty || t == "+" || t == "+5" ? Masks.phonePrefix : new
        }))
    }
}

// MARK: - Endereço com CEP

/// Endereço em partes, com o CEP primeiro: ao completar o CEP, busca no ViaCEP (se estiver ligado em Ajustes).
struct AddressFields: View {
    @Binding var address: PostalAddress
    let lookupEnabled: Bool
    @State private var status: String?
    @State private var searching = false
    @State private var lastLookup = ""

    var body: some View {
        HStack {
            MaskedField(title: "CEP", kind: .cep, text: $address.cep)
            if searching { ProgressView() }
        }
        .onChange(of: address.cep) { _, cep in lookup(cep) }
        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        TextField("Logradouro", text: $address.street).textInputAutocapitalization(.words)
        HStack {
            TextField("Número", text: $address.number).keyboardType(.numbersAndPunctuation).frame(maxWidth: 110)
            Divider()
            TextField("Complemento", text: $address.complement)
        }
        TextField("Bairro", text: $address.district).textInputAutocapitalization(.words)
        HStack {
            TextField("Município", text: $address.city).textInputAutocapitalization(.words)
            Divider()
            TextField("UF", text: Binding(get: { address.state }, set: { address.state = String($0.uppercased().prefix(2)) }))
                .textInputAutocapitalization(.characters)
                .frame(maxWidth: 50)
        }
    }

    private func lookup(_ cep: String) {
        let d = Masks.digits(cep)
        guard lookupEnabled, d.count == Masks.cepDigits, d != lastLookup else { return }
        lastLookup = d
        searching = true
        status = nil
        Task {
            do {
                if let r = try await CepLookup.find(d) {
                    CepLookup.fill(&address, with: r)
                    status = r.street.isEmpty ? "CEP geral da cidade: preencha o logradouro e o bairro." : "Endereço preenchido pelo CEP (ViaCEP). Confira e complete o número."
                } else {
                    status = "CEP não encontrado. Preencha à mão."
                }
            } catch {
                status = "Sem conexão com o ViaCEP. Preencha à mão."
            }
            searching = false
        }
    }
}

// MARK: - Nome do cliente clicável

/// Só o nome é clicável e abre o cadastro do paciente; a seta de voltar retorna à tela anterior.
struct PatientNameLink: View {
    @EnvironmentObject var store: Store
    let patientID: UUID?
    var font: Font = .headline
    var lineLimit: Int? = 2

    var body: some View {
        let name = store.db.patient(patientID)?.name ?? Term.Client
        if let patientID, store.db.patient(patientID) != nil {
            NavigationLink(value: Route.patient(patientID)) {
                Text(name).font(font).foregroundStyle(.primary).lineLimit(lineLimit).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Abre o cadastro do \(Term.client)")
        } else {
            Text(name).font(font).lineLimit(lineLimit)
        }
    }
}

// MARK: - Duração

/// Duração em minutos: as mais comuns e qualquer valor de 5 em 5 minutos.
struct DurationPicker: View {
    let title: String
    @Binding var minutes: Int
    var allowsDefault = false
    var defaultLabel = "Padrão"
    @Binding var useDefault: Bool

    init(_ title: String, minutes: Binding<Int>) {
        self.title = title
        _minutes = minutes
        _useDefault = .constant(false)
    }

    init(_ title: String, minutes: Binding<Int>, useDefault: Binding<Bool>, defaultLabel: String) {
        self.title = title
        _minutes = minutes
        _useDefault = useDefault
        allowsDefault = true
        self.defaultLabel = defaultLabel
    }

    static let common = [20, 30, 40, 45, 50, 60, 75, 80, 90, 100, 120, 150, 180]

    var body: some View {
        if allowsDefault {
            Toggle("Usar a duração padrão (\(defaultLabel))", isOn: $useDefault)
        }
        if !allowsDefault || !useDefault {
            Stepper(value: $minutes, in: 5...480, step: 5) {
                HStack {
                    Text(title)
                    Spacer()
                    Menu {
                        ForEach(Array(Set(DurationPicker.common + [minutes])).sorted(), id: \.self) { m in
                            Button(Formatters.duration(m)) { minutes = m }
                        }
                    } label: {
                        Text(Formatters.duration(minutes)).monospacedDigit().foregroundStyle(Theme.plum)
                    }
                }
            }
        }
    }
}

// MARK: - Valor em reais

/// Campo de valor: o teclado só tem números e o app põe o ponto e a vírgula sozinho (digitar 18000 mostra 180,00).
struct MoneyField: View {
    let placeholder: String
    @Binding var text: String

    init(_ placeholder: String = "0,00", text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .onChange(of: text) { _, t in
                let masked = Formatters.moneyMask(t)
                if masked != t { text = masked }
            }
            .accessibilityLabel("Valor em reais")
    }
}

// MARK: - Botão do WhatsApp

/// Balão de conversa verde. Abre o WhatsApp na conversa do paciente com a mensagem já escrita.
struct WhatsAppButton: View {
    @EnvironmentObject var store: Store
    let appointment: Appointment
    let onBlocked: (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            let p = store.db.patient(appointment.patientID)
            if let reason = WhatsAppMessage.blockReason(p) {
                onBlocked(reason)
            } else if let url = WhatsAppMessage.link(for: appointment, in: store.db) {
                openURL(url)
            }
        } label: {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 30)
                .background(Theme.whatsApp, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mensagem no WhatsApp")
        .accessibilityHint("Abre o WhatsApp na conversa do \(Term.client) com a mensagem de confirmação")
    }
}

/// Pagamento ou, no retorno sem custo e no atendimento de pacote, o aviso no lugar do campo.
struct PaymentOrNoCharge: View {
    @EnvironmentObject var store: Store
    let appointment: Appointment
    var compact = true

    var body: some View {
        if Billing.isNoCharge(appointment, in: store.db) {
            StatusBadge(text: Billing.noChargeLabel(appointment, in: store.db), color: Theme.attended)
        } else if appointment.isCancelled {
            EmptyView()
        } else {
            PaymentField(status: appointment.payment, compact: compact) { store.setPayment(appointment.id, $0) }
        }
    }
}

/// Selo da sessão no histórico: presença, falta, cancelada ou agendada.
struct SessionBadgeView: View {
    let badge: SessionBadge
    var body: some View {
        switch badge {
        case .presence: StatusBadge(text: badge.label, color: Theme.paid)
        case .absence: StatusBadge(text: badge.label, color: Theme.missed)
        case .cancelled: StatusBadge(text: badge.label, color: Theme.cancelled)
        case .scheduled: StatusBadge(text: badge.label, color: .secondary)
        }
    }
}

/// Selo pequeno de pagamento (só leitura).
struct PaymentSeal: View {
    let status: PaymentStatus?
    var body: some View {
        switch status {
        case .paid:
            Text("Pago").font(.caption.weight(.bold)).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.paid, in: Capsule())
        case .unpaid:
            Text("Não pago").font(.caption.weight(.bold)).foregroundStyle(.black)
                .padding(.horizontal, 8).padding(.vertical, 4).background(Theme.unpaid, in: Capsule())
        case .none:
            EmptyView()
        }
    }
}
