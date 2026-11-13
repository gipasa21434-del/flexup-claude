import SwiftUI
import PhotosUI
import FlexCore

@MainActor
final class ProfileViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case videos, saved, liked
        var id: String { rawValue }
        var symbol: String { switch self { case .videos: return "square.grid.3x3.fill"; case .saved: return "bookmark.fill"; case .liked: return "heart.fill" } }
        var title: String { switch self { case .videos: return "Ролики"; case .saved: return "Сохранённое"; case .liked: return "Лайкнутые" } }
    }

    let userID: UUID
    @Published var user: UserProfile?
    @Published var isFollowing = false
    @Published var tab: Tab = .videos
    @Published var lists: [Tab: [FeedItem]] = [:]
    @Published var state: LoadState = .idle
    @Published var listState: LoadState = .idle

    init(userID: UUID) { self.userID = userID }

    func load(app: AppModel) async {
        if user == nil { state = .loading }
        do {
            async let u = app.backend.profile(id: userID)
            async let f = app.backend.isFollowing(userID: userID)
            user = try await u
            isFollowing = (try? await f) ?? false
            state = .loaded
            await loadList(app: app)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func loadList(app: AppModel) async {
        if lists[tab] == nil { listState = .loading }
        do {
            let items: [FeedItem]
            switch tab {
            case .videos: items = try await app.backend.videos(by: userID)
            case .saved: items = try await app.backend.savedVideos()
            case .liked: items = try await app.backend.likedVideos()
            }
            lists[tab] = items
            listState = .loaded
        } catch {
            listState = .failed(error.localizedDescription)
        }
    }

    func toggleFollow(app: AppModel) {
        app.requireAccount {
            guard let u = user else { return }
            let target = !isFollowing
            isFollowing = target
            user?.followersCount += target ? 1 : -1
            Haptics.medium()
            Task {
                do {
                    user = try await app.backend.setFollow(target, userID: u.id)
                    if target { app.record(.interacted) }
                } catch {
                    isFollowing = !target
                    user = u
                    app.show(error)
                }
            }
        }
    }
}

struct ProfileView: View {
    let userID: UUID
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router
    @StateObject private var vm: ProfileViewModel
    @State private var showEdit = false
    @State private var showReport = false
    @State private var confirmBlock = false

    init(userID: UUID) {
        self.userID = userID
        _vm = StateObject(wrappedValue: ProfileViewModel(userID: userID))
    }

    private var isMe: Bool { app.session?.userID == userID && !app.isGuest }

    var body: some View {
        ScrollView {
            switch vm.state {
            case .idle, .loading:
                ProfileSkeleton()
            case let .failed(m):
                ErrorStateView(error: SimpleError(message: m)) { Task { await vm.load(app: app) } }
            case .loaded:
                if let user = vm.user { content(user) }
            }
        }
        .refreshable { await vm.load(app: app); if isMe { await app.refreshCurrentUser() } }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(vm.user.map { "@\($0.username)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .task { await vm.load(app: app) }
        .onChange(of: vm.tab) { _ in Task { await vm.loadList(app: app) } }
        .onChange(of: app.contentVersion) { _ in Task { await vm.load(app: app) } }
        .sheet(isPresented: $showEdit) {
            if let u = vm.user {
                EditProfileView(user: u) { updated in vm.user = updated; app.currentUser = updated }
                    .environmentObject(app)
            }
        }
        .sheet(isPresented: $showReport) {
            ReportSheet(target: .user(userID), title: "Пожаловаться на аккаунт").environmentObject(app)
        }
        .confirmationDialog("Заблокировать пользователя?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Заблокировать", role: .destructive) {
                Task {
                    do {
                        try await app.backend.setBlocked(true, userID: userID)
                        app.show("Пользователь заблокирован", style: .success)
                        app.contentVersion += 1
                        if !router.path.isEmpty { router.path.removeLast() }
                    } catch { app.show(error) }
                }
            }
        } message: {
            Text("Его ролики и комментарии исчезнут из твоей ленты, а он не сможет комментировать твои ролики.")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if isMe {
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("Настройки")
                    .accessibilityIdentifier("profile.settings")
            } else {
                Menu {
                    if let u = vm.user {
                        ShareLink(item: "Смотри @\(u.username) во FLEX UP") { Label("Поделиться профилем", systemImage: "square.and.arrow.up") }
                    }
                    Button { app.requireAccount { showReport = true } } label: { Label("Пожаловаться", systemImage: "flag") }
                    Button(role: .destructive) { app.requireAccount { confirmBlock = true } } label: { Label("Заблокировать", systemImage: "nosign") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Действия с профилем")
            }
        }
    }

    @ViewBuilder
    private func content(_ user: UserProfile) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                AvatarView(user: user, size: 96, ring: true).glow(Theme.violet, radius: 14)
                HStack(spacing: 6) {
                    Text(user.displayName).font(.title2.bold()).foregroundColor(Theme.textPrimary)
                    if user.isVerified { VerifiedBadge() }
                    if user.isPrivate { Image(systemName: "lock.fill").foregroundColor(Theme.textSecondary).accessibilityLabel("Закрытый аккаунт") }
                }
                if !user.bio.isEmpty {
                    Text(user.bio).font(.subheadline).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            }
            .padding(.top, 12)

            HStack(spacing: 0) {
                stat(user.postsCount, "публикаций")
                stat(user.followersCount, "подписчиков")
                stat(user.followingCount, "подписок")
                stat(user.likesCount, "лайков")
            }
            .padding(.horizontal, 12)

            if isMe {
                HStack(spacing: 10) {
                    Button("Редактировать") { showEdit = true }.buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("profile.edit")
                    Button { router.go(.streak) } label: {
                        Label("\(app.currentStreak)", systemImage: "flame.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle()).frame(width: 96)
                    .accessibilityLabel("FLEX STREAK: \(app.currentStreak) дней")
                }
                .padding(.horizontal, 16)
            } else {
                HStack(spacing: 10) {
                    Button(vm.isFollowing ? "Вы подписаны" : "Подписаться") { vm.toggleFollow(app: app) }
                        .buttonStyle(vm.isFollowing ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
                        .accessibilityIdentifier("profile.follow")
                    Button { router.go(.reactions(vm.lists[.videos]?.first?.id ?? UUID())) } label: {
                        Image(systemName: "person.2.wave.2.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle()).frame(width: 64)
                    .disabled(vm.lists[.videos]?.isEmpty ?? true)
                    .accessibilityLabel("DUO REACT на последний ролик")
                }
                .padding(.horizontal, 16)
            }

            if isMe {
                Picker("Раздел", selection: $vm.tab) {
                    ForEach(ProfileViewModel.Tab.allCases) { t in Label(t.title, systemImage: t.symbol).tag(t) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }

            listContent(user)
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func listContent(_ user: UserProfile) -> some View {
        let items = vm.lists[vm.tab] ?? []
        if user.isPrivate && !isMe && !vm.isFollowing {
            EmptyStateView(symbol: "lock.fill", title: "Закрытый аккаунт", message: "Подпишись, чтобы видеть ролики.")
        } else if vm.listState == .loading && items.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(0..<6, id: \.self) { _ in Rectangle().fill(Theme.elevated).aspectRatio(9 / 16, contentMode: .fit).shimmer() }
            }
        } else if case let .failed(m) = vm.listState, items.isEmpty {
            ErrorStateView(error: SimpleError(message: m)) { Task { await vm.loadList(app: app) } }
        } else if items.isEmpty {
            switch vm.tab {
            case .videos:
                EmptyStateView(symbol: "video.badge.plus", title: isMe ? "Твой первый флекс ждёт" : "Пока нет роликов",
                               message: isMe ? "Сними или выбери видео — это займёт минуту." : nil,
                               actionTitle: isMe ? "Создать ролик" : nil, action: isMe ? { app.compose() } : nil)
            case .saved:
                EmptyStateView(symbol: "bookmark", title: "Нет сохранённого", message: "Нажми закладку на ролике, чтобы вернуться к нему позже.")
            case .liked:
                EmptyStateView(symbol: "heart", title: "Нет лайков", message: "Ролики, которые тебе понравились, будут здесь.")
            }
        } else {
            VideoGrid(items: items)
        }
    }

    private func stat(_ value: Int, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(CountFormatter.short(value)).font(.headline).foregroundColor(Theme.textPrimary).contentTransition(.numericText())
            Text(title).font(.caption).foregroundColor(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

struct ProfileSkeleton: View {
    var body: some View {
        VStack(spacing: 14) {
            Circle().fill(Theme.elevated).frame(width: 96, height: 96).shimmer()
            SkeletonBlock(width: 160, height: 20)
            SkeletonBlock(width: 220, height: 14)
            HStack(spacing: 24) { ForEach(0..<4, id: \.self) { _ in SkeletonBlock(width: 52, height: 32) } }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(0..<6, id: \.self) { _ in Rectangle().fill(Theme.elevated).aspectRatio(9 / 16, contentMode: .fit).shimmer() }
            }
        }
        .padding(.top, 24)
    }
}

// MARK: - Edit profile

struct EditProfileView: View {
    let user: UserProfile
    let onSaved: (UserProfile) -> Void
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayName = ""
    @State private var username = ""
    @State private var bio = ""
    @State private var isPrivate = false
    @State private var photoItem: PhotosPickerItem?
    @State private var avatarData: Data?
    @State private var avatarPreview: UIImage?
    @State private var saving = false
    @State private var usernameTaken = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                if let avatarPreview {
                                    Image(uiImage: avatarPreview).resizable().scaledToFill().frame(width: 96, height: 96).clipShape(Circle())
                                } else {
                                    AvatarView(user: user, size: 96)
                                }
                                Image(systemName: "camera.fill").foregroundColor(.white).padding(8).background(Theme.violet, in: Circle())
                            }
                        }
                        .accessibilityLabel("Сменить аватар")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section("Профиль") {
                    TextField("Имя", text: $displayName)
                    if let e = Validator.displayName(displayName) { Text(e.localizedDescription).font(.caption).foregroundColor(Theme.like) }
                    TextField("Никнейм", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: username) { _ in usernameTaken = false }
                    if let e = Validator.username(username) { Text(e.localizedDescription).font(.caption).foregroundColor(Theme.like) }
                    else if usernameTaken { Text("Никнейм уже занят").font(.caption).foregroundColor(Theme.like) }
                    VStack(alignment: .trailing) {
                        TextField("О себе", text: $bio, axis: .vertical).lineLimit(3...5)
                        Text("\(bio.count)/\(Validator.bioLimit)").font(.caption2)
                            .foregroundColor(bio.count > Validator.bioLimit ? Theme.like : Theme.textSecondary)
                    }
                }
                Section {
                    Toggle("Закрытый аккаунт", isOn: $isPrivate)
                } footer: {
                    Text("Ролики закрытого аккаунта видят только подписчики.")
                }
            }
            .navigationTitle("Редактировать")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Готово") { Task { await save() } }.disabled(!isValid).fontWeight(.bold)
                    }
                }
            }
        }
        .onAppear {
            displayName = user.displayName; username = user.username; bio = user.bio; isPrivate = user.isPrivate
        }
        .onChange(of: photoItem) { item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                let resized = img.resized(maxSide: 512)
                avatarPreview = resized
                avatarData = resized.jpegData(compressionQuality: 0.82)
            }
        }
    }

    private var isValid: Bool {
        Validator.displayName(displayName) == nil && Validator.username(username) == nil
            && Validator.text(bio, limit: Validator.bioLimit, allowEmpty: true) == nil
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let updated = try await app.backend.updateProfile(ProfileUpdate(displayName: displayName, username: username, bio: bio,
                                                                              isPrivate: isPrivate, avatarJPEG: avatarData))
            if updated.avatarURL != nil { ImageLoader.shared.purge() }
            onSaved(updated)
            app.show("Профиль обновлён", style: .success)
            dismiss()
        } catch BackendError.conflict {
            usernameTaken = true
        } catch {
            app.show(error)
        }
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return self }
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}
