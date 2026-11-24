import SwiftUI
import UIKit

enum Theme {
    static let plum = Color("AccentColor")
    /// Cores de estado, separadas das cores das tags.
    static let paid = Color(red: 0.204, green: 0.780, blue: 0.349)      // #34C759
    static let unpaid = Color(red: 1.0, green: 0.231, blue: 0.188)      // #FF3B30
    static let attended = Color(red: 0.0, green: 0.478, blue: 1.0)      // #007AFF
    static let missed = Color(red: 0.761, green: 0.369, blue: 0.0)      // #C25E00
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let corner: CGFloat = 14
    /// Intensidade da cor da tag no fundo do agendamento (quanto maior, mais escura).
    static let appointmentTint: Double = 0.34
}

extension Color {
    init(hex: String) {
        self = UIColor(hex: hex).map(Color.init(uiColor:)) ?? .gray
    }
}

extension View {
    func cardStyle() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

// MARK: - Bloco do menu (estilo do app Lembretes)

struct MenuTile: View {
    let title: String
    let symbol: String
    let color: Color
    var count: String? = nil
    var fullWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: fullWidth ? .center : .top) {
                if fullWidth {
                    icon
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    if let count { Text(count).font(.title3.bold()).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        icon
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 4)
                    if let count {
                        Text(count).font(.title2.bold()).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: fullWidth ? 56 : 112, maxHeight: fullWidth ? nil : 112, alignment: .topLeading)
            .cardStyle()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color, in: Circle())
    }
}

// MARK: - Campo "Pagamento"

/// Campo "Pagamento" com "Sim" e "Não". Verde com letras pretas quando pago; vermelho quando não pago.
struct PaymentField: View {
    let status: PaymentStatus?
    var compact = false
    let onChange: (PaymentStatus?) -> Void

    private var fill: Color {
        switch status {
        case .paid: return Theme.paid
        case .unpaid: return Theme.unpaid
        case .none: return Color(uiColor: .tertiarySystemFill)
        }
    }

    var body: some View {
        VStack(spacing: compact ? 3 : 6) {
            Text("Pagamento")
                .font(compact ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(status == nil ? Color.primary : Color.black)
            HStack(spacing: compact ? 8 : 14) {
                box("Sim", selected: status == .paid) { onChange(status == .paid ? nil : .paid) }
                box("Não", selected: status == .unpaid) { onChange(status == .unpaid ? nil : .unpaid) }
            }
        }
        .padding(.horizontal, compact ? 8 : 14)
        .padding(.vertical, compact ? 5 : 10)
        .background(fill, in: RoundedRectangle(cornerRadius: compact ? 9 : 12, style: .continuous))
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: status)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pagamento")
    }

    private func box(_ label: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                Text(label).lineLimit(1)
            }
            .font(compact ? .caption.weight(.medium) : .body.weight(.medium))
            .foregroundStyle(status == nil ? Color.primary : Color.black)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(selected ? ", selecionado" : "")")
    }
}

// MARK: - Tags

struct TagChip: View {
    let tag: Tag?
    var selected = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tag.map { Color(hex: $0.colorHex) } ?? Color.gray.opacity(0.4)).frame(width: 10, height: 10)
            Text(tag?.name ?? "Sem tag").font(.subheadline)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected ? (tag.map { Color(hex: $0.colorHex).opacity(0.28) } ?? Color.gray.opacity(0.2))
                                    : Color(uiColor: .tertiarySystemFill)))
        .overlay(Capsule().stroke(selected ? Theme.plum : .clear, lineWidth: 1.5))
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // No escuro, texto claro sobre a cor mais forte: o texto colorido sumia no fundo dos cartões.
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(scheme == .dark ? Color.white : color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(scheme == .dark ? 0.6 : 0.14), in: Capsule())
    }
}

// MARK: - Cabeçalho com logo

struct Greeting: View {
    let firstName: String
    var body: some View {
        HStack(spacing: 12) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 52, height: 46)
                .accessibilityHidden(true)
            Text(firstName.isEmpty ? "Olá" : "Olá, \(firstName)")
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Avisos rápidos

@MainActor
final class Toaster: ObservableObject {
    @Published var message: String?
    private var task: Task<Void, Never>?

    func show(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { message = text }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut) { self?.message = nil }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject var toaster: Toaster
    var body: some View {
        VStack {
            Spacer()
            if let m = toaster.message {
                Text(m)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.82), in: Capsule())
                    .padding(.bottom, 24)
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { toaster.message = nil }
            }
        }
        .allowsHitTesting(toaster.message != nil)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message { Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}
