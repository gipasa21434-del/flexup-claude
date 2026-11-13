import SwiftUI
import FlexCore

@main
struct FlexUpApp: App {
    @StateObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let args = ProcessInfo.processInfo.arguments
        let isUITest = args.contains("-uitest")
        let defaults: UserDefaults
        if isUITest, let d = UserDefaults(suiteName: "flexup.uitest") {
            d.removePersistentDomain(forName: "flexup.uitest")
            defaults = d
        } else {
            defaults = .standard
        }
        URLCache.shared = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 150 * 1024 * 1024)
        _app = StateObject(wrappedValue: AppModel(backend: BackendFactory.make(arguments: args), defaults: defaults, isUITesting: isUITest))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .tint(Theme.violet)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active: app.players.resume()
            case .background, .inactive: app.players.suspend()
            @unknown default: break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            switch app.phase {
            case .launching:
                SplashView()
                    .task {
                        if !reduceMotion && !app.isUITesting { try? await Task.sleep(nanoseconds: 900_000_000) }
                        await app.bootstrap()
                    }
            case .onboarding:
                WelcomeView().transition(.opacity)
            case .auth:
                AuthView().transition(.opacity)
            case .main:
                MainTabView().transition(.opacity)
            }

            if !app.isOnline {
                OfflineBanner().transition(.move(edge: .top).combined(with: .opacity))
            }
            if let toast = app.toast {
                ToastView(toast: toast)
                    .padding(.top, app.isOnline ? 8 : 52)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation { app.toast = nil } }
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.isOnline)
        .sheet(isPresented: $app.showAuthPrompt) {
            AuthPromptSheet().presentationDetents([.medium])
        }
    }
}

struct SplashView: View {
    @State private var appear = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Color(hex: 0x0E0F13).ignoresSafeArea()
            RadialGradient(colors: [Theme.violet.opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 260)
                .ignoresSafeArea()
                .opacity(appear ? 1 : 0)
            VStack(spacing: 18) {
                FlexLogo(size: 108)
                    .scaleEffect(appear || reduceMotion ? 1 : 0.8)
                Text("Лови момент. Задавай тренд.")
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.8))
                    .opacity(appear ? 1 : 0)
            }
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { appear = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("FLEX UP загружается")
    }
}

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
            Text("Нет подключения — показываем то, что уже загружено")
                .font(.footnote.weight(.semibold))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.warning, in: Capsule())
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

struct AuthPromptSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            FlexLogo(size: 56).padding(.top, 24)
            Text("Нужен аккаунт").font(.title2.bold())
            Text("Лайки, комментарии, подписки и публикации доступны после входа. Смотреть ленту можно и гостем.")
                .font(.subheadline).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
            Button("Войти или зарегистрироваться") {
                dismiss()
                Task { await app.signOut() }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Позже") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(24)
    }
}
