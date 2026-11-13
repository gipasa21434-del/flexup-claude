import SwiftUI
import FlexCore

// MARK: - Onboarding

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel
    @State private var page = 0

    private let pages: [(symbol: String, title: String, text: String)] = [
        ("play.rectangle.on.rectangle.fill", "Лови момент", "Вертикальные ролики на весь экран. Свайп — и следующий уже готов."),
        ("face.smiling.inverse", "MOOD FEED", "Выбери настроение — смешно, спокойно, энергично — и лента подстроится."),
        ("trophy.fill", "FLEX CHALLENGE", "Каждый день новая тема. Участвуй, собирай лайки и поднимайся в рейтинге."),
        ("person.2.wave.2.fill", "DUO REACT", "Отвечай на ролики своей реакцией — сверху оригинал, снизу ты.")
    ]

    var body: some View {
        ZStack {
            Color(hex: 0x0E0F13).ignoresSafeArea()
            RadialGradient(colors: [Theme.violet.opacity(0.35), .clear], center: .topTrailing, startRadius: 20, endRadius: 420).ignoresSafeArea()
            RadialGradient(colors: [Theme.teal.opacity(0.22), .clear], center: .bottomLeading, startRadius: 20, endRadius: 380).ignoresSafeArea()
            VStack(spacing: 24) {
                HStack {
                    FlexLogo(size: 40)
                    Spacer()
                    Button("Пропустить") { app.finishOnboarding() }
                        .font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.7))
                        .accessibilityIdentifier("onboarding.skip")
                }
                .padding(.horizontal, 24)
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        VStack(spacing: 22) {
                            Spacer()
                            Image(systemName: pages[i].symbol)
                                .font(.system(size: 84, weight: .semibold))
                                .foregroundStyle(Theme.brandGradient)
                                .glow(Theme.violet, radius: 24)
                                .accessibilityHidden(true)
                            Text(pages[i].title).font(.system(.largeTitle, design: .rounded).weight(.heavy)).foregroundColor(.white)
                            Text(pages[i].text).font(.title3).foregroundColor(.white.opacity(0.75))
                                .multilineTextAlignment(.center).padding(.horizontal, 32)
                            Spacer()
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                Button(page == pages.count - 1 ? "Начать" : "Дальше") {
                    if page < pages.count - 1 { withAnimation { page += 1 } } else { app.finishOnboarding() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .accessibilityIdentifier("onboarding.next")
                Text("Лови момент. Задавай тренд.").font(.footnote).foregroundColor(.white.opacity(0.5)).padding(.bottom, 8)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Auth

@MainActor
final class AuthViewModel: ObservableObject {
    enum Mode: String, CaseIterable { case signIn, signUp, reset
        var title: String { switch self { case .signIn: return "Вход"; case .signUp: return "Регистрация"; case .reset: return "Сброс пароля" } }
    }

    @Published var mode: Mode = .signIn
    @Published var email = ""
    @Published var password = ""
    @Published var confirm = ""
    @Published var username = ""
    @Published var isLoading = false
    @Published var error: String?
    @Published var info: String?
    @Published var submitted = false

    var emailError: String? { submitted || !email.isEmpty ? Validator.email(email)?.errorDescription : nil }
    var passwordError: String? {
        guard mode == .signUp, submitted || !password.isEmpty else { return nil }
        return Validator.password(password)?.errorDescription
    }
    var confirmError: String? {
        guard mode == .signUp, submitted || !confirm.isEmpty else { return nil }
        return Validator.passwordConfirmation(password, confirm)?.errorDescription
    }
    var usernameError: String? {
        guard mode == .signUp, submitted || !username.isEmpty else { return nil }
        return Validator.username(username)?.errorDescription
    }

    var canSubmit: Bool {
        switch mode {
        case .signIn: return Validator.email(email) == nil && !password.isEmpty
        case .signUp: return Validator.email(email) == nil && Validator.password(password) == nil
            && Validator.passwordConfirmation(password, confirm) == nil && Validator.username(username) == nil
        case .reset: return Validator.email(email) == nil
        }
    }

    func submit(app: AppModel) async {
        submitted = true
        error = nil; info = nil
        guard canSubmit else { Haptics.error(); return }
        isLoading = true
        defer { isLoading = false }
        do {
            switch mode {
            case .signIn:
                let s = try await app.backend.signIn(email: email, password: password)
                await app.didAuthenticate(s)
            case .signUp:
                let s = try await app.backend.signUp(email: email, password: password, username: username)
                await app.didAuthenticate(s)
            case .reset:
                try await app.backend.sendPasswordReset(email: email)
                info = "Если такой аккаунт есть, мы отправили письмо со ссылкой для сброса."
            }
        } catch BackendError.emailConfirmationRequired {
            info = BackendError.emailConfirmationRequired.errorDescription
            mode = .signIn
        } catch let BackendError.notConfigured(message) {
            info = message
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    func guest(app: AppModel) async {
        isLoading = true
        defer { isLoading = false }
        if let s = try? await app.backend.signInAsGuest() { await app.didAuthenticate(s) }
    }

    func fillDemo(_ account: DemoContent.Account) {
        mode = .signIn
        email = account.email
        password = DemoContent.demoPassword
    }
}

struct AuthView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var vm = AuthViewModel()
    @FocusState private var focus: Field?
    enum Field { case email, password, confirm, username }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    FlexLogo(size: 76)
                    Wordmark()
                    Text("Лови момент. Задавай тренд.").font(.subheadline).foregroundColor(Theme.textSecondary)
                    if app.isDemo {
                        HStack(spacing: 6) {
                            DemoBadge()
                            Text("Сервер не подключён — всё работает локально").font(.caption).foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                .padding(.top, 28)

                Picker("Режим", selection: $vm.mode) {
                    Text("Вход").tag(AuthViewModel.Mode.signIn)
                    Text("Регистрация").tag(AuthViewModel.Mode.signUp)
                }
                .pickerStyle(.segmented)
                .opacity(vm.mode == .reset ? 0.4 : 1)

                VStack(spacing: 12) {
                    if vm.mode == .signUp {
                        field("Никнейм (латиница)", text: $vm.username, error: vm.usernameError, field: .username, content: .username)
                    }
                    field("Email", text: $vm.email, error: vm.emailError, field: .email, content: .emailAddress, keyboard: .emailAddress)
                    if vm.mode != .reset {
                        secure("Пароль", text: $vm.password, error: vm.passwordError, field: .password,
                               content: vm.mode == .signUp ? .newPassword : .password)
                    }
                    if vm.mode == .signUp {
                        secure("Повтори пароль", text: $vm.confirm, error: vm.confirmError, field: .confirm, content: .newPassword)
                    }
                }

                if let e = vm.error {
                    Label(e, systemImage: "exclamationmark.circle.fill").font(.footnote).foregroundColor(Theme.like)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("auth.error")
                }
                if let i = vm.info {
                    Label(i, systemImage: "info.circle.fill").font(.footnote).foregroundColor(Theme.accentText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    focus = nil
                    Task { await vm.submit(app: app) }
                } label: {
                    if vm.isLoading { ProgressView().tint(.white) } else {
                        Text(vm.mode == .signIn ? "Войти" : vm.mode == .signUp ? "Создать аккаунт" : "Отправить ссылку")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isEnabled: vm.canSubmit))
                .disabled(vm.isLoading)
                .accessibilityIdentifier("auth.submit")

                HStack {
                    if vm.mode == .reset {
                        Button("← Назад ко входу") { vm.mode = .signIn }
                    } else {
                        Button("Забыли пароль?") { vm.mode = .reset }
                    }
                    Spacer()
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(Theme.accentText)

                Button {
                    Task { await vm.guest(app: app) }
                } label: {
                    Label("Смотреть как гость", systemImage: "eye")
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("auth.guest")

                if app.isDemo { demoAccounts }

                Text("Продолжая, ты соглашаешься соблюдать правила сообщества: без травли, спама и чужого контента без прав.")
                    .font(.caption2).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: vm.mode)
        .onSubmit {
            switch focus {
            case .username: focus = .email
            case .email: focus = vm.mode == .reset ? nil : .password
            case .password: focus = vm.mode == .signUp ? .confirm : nil
            default: focus = nil
            }
            if focus == nil { Task { await vm.submit(app: app) } }
        }
    }

    private var demoAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Тестовые аккаунты (пароль \(DemoContent.demoPassword))").font(.footnote.weight(.semibold)).foregroundColor(Theme.textSecondary)
            ForEach(DemoContent.accounts, id: \.email) { acc in
                Button {
                    vm.fillDemo(acc)
                    Task { await vm.submit(app: app) }
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(Theme.brandGradient)
                        Text(acc.email).foregroundColor(Theme.textPrimary)
                        Spacer()
                        Image(systemName: "arrow.right.circle.fill").foregroundColor(Theme.accentText)
                    }
                    .font(.subheadline)
                    .frame(minHeight: Theme.minTap)
                }
                .accessibilityIdentifier("auth.demo.\(acc.email)")
            }
        }
        .card()
    }

    private func field(_ title: String, text: Binding<String>, error: String?, field: Field,
                       content: UITextContentType, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: text)
                .textContentType(content)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: field)
                .submitLabel(.next)
                .padding(.horizontal, 14).frame(minHeight: 50)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(error == nil ? Theme.stroke : Theme.like, lineWidth: 1))
                .accessibilityIdentifier("auth.\(field)")
            if let error { Text(error).font(.caption).foregroundColor(Theme.like) }
        }
    }

    private func secure(_ title: String, text: Binding<String>, error: String?, field: Field, content: UITextContentType) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(title, text: text)
                .textContentType(content)
                .focused($focus, equals: field)
                .submitLabel(.go)
                .padding(.horizontal, 14).frame(minHeight: 50)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(error == nil ? Theme.stroke : Theme.like, lineWidth: 1))
                .accessibilityIdentifier("auth.\(field)")
            if let error { Text(error).font(.caption).foregroundColor(Theme.like) }
        }
    }
}
