import SwiftUI
import FlexCore

// MARK: - Logo

struct FlexLogo: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(hex: 0x15161D))
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Theme.brandGradient, lineWidth: size * 0.04)
            FlexMark()
                .fill(Theme.brandGradient)
                .frame(width: size * 0.56, height: size * 0.56)
                .glow(Theme.violet, radius: size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Логотип FLEX UP")
    }
}

/// Brand mark: a stylised "F" whose middle bar is an upward arrow ("flex up").
struct FlexMark: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        // Stem
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.18, width: w * 0.2, height: h * 0.8),
                         cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
        // Top bar
        p.addRoundedRect(in: CGRect(x: r.minX + w * 0.08, y: r.minY + h * 0.18, width: w * 0.62, height: h * 0.18),
                         cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
        // Arrow (middle bar rising to the top-right)
        p.move(to: CGPoint(x: r.minX + w * 0.28, y: r.minY + h * 0.66))
        p.addLine(to: CGPoint(x: r.minX + w * 0.70, y: r.minY + h * 0.46))
        p.addLine(to: CGPoint(x: r.minX + w * 0.64, y: r.minY + h * 0.38))
        p.addLine(to: CGPoint(x: r.minX + w * 0.95, y: r.minY + h * 0.02))
        p.addLine(to: CGPoint(x: r.minX + w * 0.92, y: r.minY + h * 0.50))
        p.addLine(to: CGPoint(x: r.minX + w * 0.84, y: r.minY + h * 0.44))
        p.addLine(to: CGPoint(x: r.minX + w * 0.28, y: r.minY + h * 0.84))
        p.closeSubpath()
        return p
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("FLEX").foregroundColor(Theme.textPrimary)
            Text("UP").foregroundStyle(Theme.brandGradientH)
        }
        .font(.system(.largeTitle, design: .rounded).weight(.black))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FLEX UP")
    }
}

// MARK: - Avatar

struct AvatarView: View {
    let user: UserProfile
    var size: CGFloat = 44
    var ring = false

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: user.avatarColors.map { Color(hexString: $0) },
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(user.initials)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .minimumScaleFactor(0.5)
            if let url = user.avatarURL {
                AvatarImage(url: url)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(ring ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.clear), lineWidth: ring ? 2 : 0))
        .accessibilityLabel("Аватар \(user.displayName)")
    }
}

private struct AvatarImage: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Color.clear }
        }
        .task(id: url) { image = await ImageLoader.shared.image(for: url) }
    }
}

struct VerifiedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .foregroundStyle(Theme.teal)
            .imageScale(.small)
            .accessibilityLabel("Подтверждённый автор")
    }
}

// MARK: - Skeleton

struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, .white.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .clipped()
                .allowsHitTesting(false)
            )
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var corner: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Theme.elevated)
            .frame(width: width, height: height)
            .shimmer()
            .accessibilityHidden(true)
    }
}

struct FeedSkeleton: View {
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(hex: 0x111218)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle().fill(Color.white.opacity(0.1)).frame(width: 40, height: 40)
                    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)).frame(width: 120, height: 14)
                }
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)).frame(width: 240, height: 12)
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)).frame(width: 180, height: 12)
            }
            .padding(.horizontal, 16).padding(.bottom, 110)
            .shimmer()
        }
        .ignoresSafeArea()
        .accessibilityLabel("Загрузка ленты")
    }
}

// MARK: - Empty / error states

struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.violet.opacity(0.2), Theme.teal.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 96, height: 96)
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.brandGradient)
            }
            Text(title).font(.title3.bold()).multilineTextAlignment(.center).foregroundColor(Theme.textPrimary)
            if let message {
                Text(message).font(.subheadline).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 260).padding(.top, 6)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct ErrorStateView: View {
    let error: Error
    var retry: (() -> Void)?
    var body: some View {
        EmptyStateView(symbol: (error as? BackendError) == .offline ? "wifi.slash" : "exclamationmark.triangle",
                       title: (error as? BackendError) == .offline ? "Нет сети" : "Что-то пошло не так",
                       message: error.localizedDescription,
                       actionTitle: retry == nil ? nil : "Повторить", action: retry)
    }
}

// MARK: - Chips

struct Chip: View {
    let title: String
    var symbol: String? = nil
    var isSelected = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .foregroundColor(isSelected ? .white : Theme.textPrimary)
            .background(
                Capsule().fill(isSelected ? AnyShapeStyle(Theme.brandGradientH) : AnyShapeStyle(Theme.elevated))
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Toasts

struct ToastMessage: Identifiable, Equatable {
    enum Style { case info, success, error }
    let id = UUID()
    let text: String
    var style: Style = .info
}

struct ToastView: View {
    let toast: ToastMessage
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            Text(toast.text).font(.subheadline.weight(.medium)).foregroundColor(.white).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .background(Color.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
    private var icon: String {
        switch toast.style { case .info: return "info.circle.fill"; case .success: return "checkmark.circle.fill"; case .error: return "exclamationmark.circle.fill" }
    }
    private var color: Color {
        switch toast.style { case .info: return Theme.teal; case .success: return Theme.teal; case .error: return Theme.like }
    }
}

// MARK: - Misc

struct DemoBadge: View {
    var body: some View {
        Text("ДЕМО")
            .font(.caption2.weight(.heavy))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.warning, in: Capsule())
            .foregroundColor(.black)
            .accessibilityLabel("Демо-режим: данные хранятся только на устройстве")
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack {
            Text(title).font(.title3.bold()).foregroundColor(Theme.textPrimary)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action).font(.subheadline.weight(.semibold)).foregroundColor(Theme.accentText)
            }
        }
    }
}

/// Wrapping layout for tags/chips (iOS 16 Layout protocol).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
