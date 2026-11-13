import SwiftUI
import FlexCore

// MARK: - Activity (in-app notifications)

struct ActivityView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var router = Router()
    @State private var items: [ActivityNotification] = []
    @State private var actors: [UUID: UserProfile] = [:]
    @State private var state: LoadState = .idle
    @State private var filter: ActivityKind?

    private var visible: [ActivityNotification] {
        items.filter { n in
            (filter == nil || n.kind == filter) && (app.settings.inAppNotifications[n.kind.rawValue] ?? true)
        }
    }

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if app.isGuest {
                    EmptyStateView(symbol: "bell.slash", title: "Уведомления — после входа",
                                   message: "Тут появятся лайки, комментарии, подписки и реакции на твои ролики.",
                                   actionTitle: "Войти") { Task { await app.signOut() } }
                } else {
                    list
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Активность")
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .toolbar {
                if !items.isEmpty {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Прочитать все") { Task { await markRead() } }
                    }
                }
            }
        }
        .environmentObject(router)
        .task { await load() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Все", isSelected: filter == nil) { filter = nil }
                        Chip(title: "Лайки", symbol: "heart", isSelected: filter == .like) { filter = .like }
                        Chip(title: "Комментарии", symbol: "bubble.right", isSelected: filter == .comment) { filter = .comment }
                        Chip(title: "Подписки", symbol: "person.badge.plus", isSelected: filter == .follow) { filter = .follow }
                        Chip(title: "DUO", symbol: "person.2.wave.2", isSelected: filter == .react) { filter = .react }
                    }
                    .padding(.horizontal, 16)
                }
                switch state {
                case .idle, .loading:
                    ForEach(0..<5, id: \.self) { _ in SkeletonBlock(height: 58, corner: 12) }.padding(.horizontal, 16)
                case let .failed(m):
                    ErrorStateView(error: SimpleError(message: m)) { Task { await load() } }
                case .loaded:
                    if visible.isEmpty {
                        EmptyStateView(symbol: "bell", title: "Пока тихо", message: "Публикуй ролики и участвуй в челленджах — реакции появятся здесь.")
                    } else {
                        ForEach(visible) { n in row(n) }
                    }
                }
                Text("Push-уведомления не настроены: для них нужен APNs-ключ Apple Developer. Сейчас уведомления показываются только внутри приложения.")
                    .font(.caption2).foregroundColor(Theme.textSecondary).padding(16)
            }
            .padding(.vertical, 8)
        }
        .refreshable { await load() }
    }

    private func row(_ n: ActivityNotification) -> some View {
        Button {
            if n.kind == .challenge { router.go(.challenges) }
            else if n.kind == .react, let v = n.videoID { router.go(.reactions(v)) }
            else if let v = n.videoID { Task { await open(video: v) } }
            else if let a = n.actorID { router.go(.profile(a)) }
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    if let a = n.actorID, let u = actors[a] { AvatarView(user: u, size: 46) }
                    else { FlexLogo(size: 46) }
                    Image(systemName: icon(n.kind)).font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                        .frame(width: 20, height: 20).background(color(n.kind), in: Circle())
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                }
                VStack(alignment: .leading, spacing: 2) {
                    (Text(n.actorID.flatMap { actors[$0] }.map { "@\($0.username) " } ?? "").bold() + Text(n.text))
                        .font(.subheadline).foregroundColor(Theme.textPrimary).multilineTextAlignment(.leading)
                    Text(RelativeTime.short(from: n.createdAt)).font(.caption).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                if !n.isRead { Circle().fill(Theme.violet).frame(width: 8, height: 8).accessibilityLabel("Новое") }
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func icon(_ k: ActivityKind) -> String {
        switch k {
        case .like: return "heart.fill"; case .comment: return "bubble.right.fill"; case .follow: return "person.fill.badge.plus"
        case .mention: return "at"; case .challenge: return "trophy.fill"; case .react: return "person.2.wave.2.fill"; case .system: return "sparkles"
        }
    }

    private func color(_ k: ActivityKind) -> Color {
        switch k { case .like: return Theme.like; case .comment, .mention: return Theme.tealDeep; case .challenge: return Theme.warning; default: return Theme.violet }
    }

    private func load() async {
        guard !app.isGuest else { return }
        if items.isEmpty { state = .loading }
        do {
            items = try await app.backend.notifications()
            for id in Set(items.compactMap(\.actorID)) where actors[id] == nil {
                actors[id] = try? await app.backend.profile(id: id)
            }
            state = .loaded
        } catch { state = .failed(error.localizedDescription) }
    }

    private func markRead() async {
        try? await app.backend.markNotificationsRead()
        items = items.map { var n = $0; n.isRead = true; return n }
        await app.refreshUnread()
    }

    private func open(video id: UUID) async {
        do {
            let item = try await app.backend.feedItem(videoID: id)
            router.go(.player(PlayerListToken(items: [item], startAt: id)))
        } catch { app.show(error) }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @State private var cacheSize: Int64 = 0
    @State private var confirmDelete = false
    @State private var confirmSignOut = false
    @State private var newHiddenTag = ""

    var body: some View {
        Form {
            Section("Аккаунт") {
                if let u = app.currentUser {
                    LabeledContent("Никнейм", value: "@\(u.username)")
                }
                if let email = app.session?.email { LabeledContent("Email", value: email) }
                LabeledContent("Сервер", value: app.isDemo ? "Демо (локально)" : "Supabase")
                if let email = app.session?.email {
                    Button("Сбросить пароль") {
                        Task {
                            do { try await app.backend.sendPasswordReset(email: email); app.show("Письмо отправлено", style: .success) }
                            catch { app.show(error) }
                        }
                    }
                }
                Button("Выйти") { confirmSignOut = true }.accessibilityIdentifier("settings.signout")
                Button("Удалить аккаунт", role: .destructive) { confirmDelete = true }
            }

            Section {
                Toggle("Закрытый аккаунт", isOn: Binding(
                    get: { app.currentUser?.isPrivate ?? false },
                    set: { v in Task { await setPrivate(v) } }))
                Picker("Кто может комментировать", selection: $app.settings.whoCanComment) {
                    Text("Все").tag("everyone"); Text("Подписчики").tag("followers"); Text("Никто").tag("nobody")
                }
                NavigationLink("Заблокированные") { BlockedUsersView() }
            } header: { Text("Приватность и безопасность") } footer: {
                Text("Мы не собираем геолокацию, контакты и рекламные идентификаторы. История поиска хранится только на устройстве.")
            }

            Section {
                Toggle("Показывать чувствительный контент", isOn: $app.settings.showSensitive)
                ForEach(app.settings.hiddenTags, id: \.self) { t in
                    HStack { Text("#\(t)"); Spacer() }
                }
                .onDelete { app.settings.hiddenTags.remove(atOffsets: $0); app.contentVersion += 1 }
                HStack {
                    TextField("Скрыть хештег…", text: $newHiddenTag).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Добавить") {
                        let t = HashtagParser.normalize(newHiddenTag)
                        guard !t.isEmpty, !app.settings.hiddenTags.contains(t) else { return }
                        app.settings.hiddenTags.append(t)
                        newHiddenTag = ""
                        app.contentVersion += 1
                    }
                    .disabled(HashtagParser.normalize(newHiddenTag).isEmpty)
                }
            } header: { Text("Фильтры контента") } footer: {
                Text("Ролики со скрытыми хештегами не появятся в ленте. Смахни влево, чтобы удалить фильтр.")
            }

            Section("Воспроизведение") {
                Toggle("Автовоспроизведение", isOn: $app.settings.autoplay)
                Toggle("Начинать без звука", isOn: $app.settings.startMuted)
                Toggle("Повторять ролик", isOn: $app.settings.loopVideos)
                Toggle("Экономия трафика", isOn: $app.settings.dataSaver)
                Toggle("Меньше эффектов", isOn: $app.settings.reduceEffects)
            }

            Section {
                LabeledContent("Занято кэшем", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Button("Очистить кэш") {
                    MediaStore.clearCache()
                    cacheSize = MediaStore.cacheSize()
                    app.show("Кэш очищен", style: .success)
                }
            } header: { Text("Кэш") } footer: {
                Text("Кэш изображений и временных файлов ограничен 150 МБ и очищается системой при нехватке места.")
            }

            Section("Уведомления в приложении") {
                ForEach(ActivityKind.allCases, id: \.self) { k in
                    Toggle(title(k), isOn: Binding(
                        get: { app.settings.inAppNotifications[k.rawValue] ?? true },
                        set: { app.settings.inAppNotifications[k.rawValue] = $0 }))
                }
                LabeledContent("Push-уведомления", value: "не настроены (нужен APNs)")
            }

            Section("FLEX STREAK") {
                Toggle("Включить стрик", isOn: $app.settings.streakEnabled)
                Toggle("Показывать в ленте", isOn: $app.settings.showStreakInFeed).disabled(!app.settings.streakEnabled)
            }

            if app.isDemo {
                Section {
                    Picker("Сеть (симуляция)", selection: Binding(get: { app.demoCondition }, set: { c in Task { await app.setDemoCondition(c) } })) {
                        ForEach(DemoBackend.NetworkCondition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("settings.network")
                    Button("Сбросить демо-данные", role: .destructive) { Task { await app.resetDemo() } }
                } header: { Text("Демо-режим") } footer: {
                    Text("Сервер не подключён: аккаунты, лайки и публикации хранятся только на этом устройстве. Симуляция сети помогает показать обработку ошибок.")
                }
            }

            Section("О приложении") {
                LabeledContent("Версия", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                LabeledContent("Слоган", value: "Лови момент. Задавай тренд.")
                NavigationLink("Как работают рекомендации") { RecommendationInfoView() }
                NavigationLink("Демо-видео и лицензии") { LicensesView() }
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { cacheSize = MediaStore.cacheSize() }
        .onChange(of: app.settings.startMuted) { v in app.players.isMuted = v }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { Task { await app.signOut() } }
        }
        .alert("Удалить аккаунт навсегда?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { Task { await app.deleteAccount() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Профиль, все ролики, комментарии и лайки будут удалены без возможности восстановления.")
        }
    }

    private func title(_ k: ActivityKind) -> String {
        switch k {
        case .like: return "Лайки"; case .comment: return "Комментарии"; case .follow: return "Новые подписчики"
        case .mention: return "Упоминания"; case .challenge: return "Челленджи"; case .react: return "DUO REACT"; case .system: return "Системные"
        }
    }

    private func setPrivate(_ v: Bool) async {
        guard let u = app.currentUser else { return }
        do {
            app.currentUser = try await app.backend.updateProfile(ProfileUpdate(displayName: u.displayName, username: u.username,
                                                                                 bio: u.bio, isPrivate: v))
        } catch { app.show(error) }
    }
}

struct BlockedUsersView: View {
    @EnvironmentObject private var app: AppModel
    @State private var users: [UserProfile] = []
    @State private var state: LoadState = .idle

    var body: some View {
        List {
            if state == .loaded && users.isEmpty {
                Text("Никого нет. Заблокировать можно из меню ролика или профиля.").foregroundColor(Theme.textSecondary)
            }
            ForEach(users) { u in
                HStack {
                    AvatarView(user: u, size: 36)
                    Text("@\(u.username)")
                    Spacer()
                    Button("Разблокировать") {
                        Task {
                            do {
                                try await app.backend.setBlocked(false, userID: u.id)
                                users.removeAll { $0.id == u.id }
                                app.contentVersion += 1
                            } catch { app.show(error) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .navigationTitle("Заблокированные")
        .task {
            state = .loading
            users = (try? await app.backend.blockedUsers()) ?? []
            state = .loaded
        }
    }
}

struct RecommendationInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Лента «Для тебя» ранжируется понятными правилами, а не обученной нейросетью.").font(.headline)
                Group {
                    Text("• +2 — автор, на которого ты подписан")
                    Text("• + интерес к хештегам и автору: растёт от лайков, сохранений, комментариев, репостов и досмотров, падает от «Не интересно» и быстрых пролистываний")
                    Text("• +3 — совпадение с выбранным настроением (MOOD FEED)")
                    Text("• + свежесть: вклад уменьшается вдвое каждые 48 часов")
                    Text("• + вовлечённость: лайки, комментарии, сохранения и репосты относительно просмотров")
                    Text("• −4 — уже просмотренные ролики")
                    Text("• Разнообразие: один автор не появляется чаще раза в три ролика, если есть альтернативы")
                }
                .font(.subheadline)
                Text("Ограничения: нет коллаборативной фильтрации и анализа содержимого видео; «интересы» хранятся на устройстве; на сервере используется упрощённая версия формулы.")
                    .font(.footnote).foregroundColor(Theme.textSecondary)
            }
            .padding(20)
        }
        .navigationTitle("Рекомендации")
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Демо-ролики").font(.headline)
                Text("Все 10 демо-видео и их звук сгенерированы скриптом scripts/generate_demo_media.sh из синтетических источников FFmpeg (градиенты, фракталы, клеточные автоматы, синтезированные тона). Сторонние записи и музыка не используются.")
                Text("Названия «музыкальных треков» в демо — вымышленные подписи к синтезированному звуку.")
                Text("Шрифты и иконки — системные (SF Symbols) в рамках лицензии Apple.")
            }
            .font(.subheadline)
            .padding(20)
        }
        .navigationTitle("Лицензии")
    }
}
