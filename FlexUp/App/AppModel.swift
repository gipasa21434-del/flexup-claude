import SwiftUI
import Network
import Security
import FlexCore

/// Per-device preferences (UserDefaults). Nothing here is personal data.
struct AppSettings: Codable, Equatable {
    var autoplay = true
    var startMuted = true
    var loopVideos = true
    var dataSaver = false
    var hiddenTags: [String] = []
    var showSensitive = false
    var streakEnabled = true
    var showStreakInFeed = true
    var reduceEffects = false
    var inAppNotifications: [String: Bool] = Dictionary(uniqueKeysWithValues: ActivityKind.allCases.map { ($0.rawValue, true) })
    var whoCanComment = "everyone"
    var searchHistory: [String] = []
    var hasSeenOnboarding = false
}

/// Root state container. Lives for the whole app session and is injected as an EnvironmentObject.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case launching, onboarding, auth, main }

    @Published var phase: Phase = .launching
    @Published private(set) var session: AuthSession?
    @Published var currentUser: UserProfile?
    @Published var settings: AppSettings { didSet { persist(settings, key: Keys.settings); applySettings() } }
    @Published var streak: StreakState { didSet { persist(streak, key: Keys.streak) } }
    @Published var interests: InterestProfile { didSet { persist(interests, key: Keys.interests) } }
    @Published var toast: ToastMessage?
    @Published var isOnline = true
    @Published var showAuthPrompt = false
    @Published var unreadCount = 0
    @Published var newlyUnlocked: StreakState.Achievement?
    /// Bumped after publishing/deleting so lists refresh.
    @Published var contentVersion = 0
    @Published var selectedTab: MainTab = .feed
    @Published var composeContext: ComposeContext?
    @Published var demoCondition: DemoBackend.NetworkCondition = .normal

    let backend: FlexBackend
    let players: PlayerPool
    let streakTracker = StreakTracker()
    let isUITesting: Bool
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()
    private var toastTask: Task<Void, Never>?

    enum Keys {
        static let settings = "flexup.settings.v1"
        static let streak = "flexup.streak.v1"
        static let interests = "flexup.interests.v1"
    }

    var isGuest: Bool { session?.isGuest ?? true }
    var isDemo: Bool { backend.mode == .demo }

    init(backend: FlexBackend, defaults: UserDefaults = .standard, isUITesting: Bool = false) {
        self.backend = backend
        self.defaults = defaults
        self.isUITesting = isUITesting
        let s: AppSettings = Self.load(AppSettings.self, key: Keys.settings, from: defaults) ?? AppSettings()
        settings = s
        streak = Self.load(StreakState.self, key: Keys.streak, from: defaults) ?? StreakState()
        interests = Self.load(InterestProfile.self, key: Keys.interests, from: defaults) ?? InterestProfile()
        players = PlayerPool(startMuted: s.startMuted)
        applySettings()
        startNetworkMonitor()
    }

    // MARK: Persistence helpers

    private static func load<T: Decodable>(_ type: T.Type, key: String, from d: UserDefaults) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder.flex.decode(T.self, from: data)
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder.flex.encode(value) { defaults.set(data, forKey: key) }
    }

    private func applySettings() {
        players.loops = settings.loopVideos
        players.preferredBuffer = settings.dataSaver ? 2 : 6
        players.capacity = settings.dataSaver ? 2 : 3
        if streak.isEnabled != settings.streakEnabled { streak.isEnabled = settings.streakEnabled }
    }

    private func startNetworkMonitor() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "flexup.network"))
    }

    // MARK: Lifecycle

    func bootstrap() async {
        if let s = await backend.restoreSession() {
            session = s
            await refreshCurrentUser()
            phase = .main
        } else {
            phase = settings.hasSeenOnboarding ? .auth : .onboarding
        }
        await refreshUnread()
    }

    func finishOnboarding() {
        settings.hasSeenOnboarding = true
        withAnimation(.easeInOut) { phase = .auth }
    }

    func didAuthenticate(_ s: AuthSession) async {
        session = s
        await refreshCurrentUser()
        withAnimation(.easeInOut) { phase = .main }
        await refreshUnread()
        if !s.isGuest { show(isDemo ? "Ты вошёл в демо-аккаунт" : "Добро пожаловать!", style: .success) }
    }

    func refreshCurrentUser() async {
        guard let s = session, !s.isGuest else { currentUser = nil; return }
        currentUser = try? await backend.profile(id: s.userID)
    }

    func signOut() async {
        players.releaseAll()
        await backend.signOut()
        session = nil
        currentUser = nil
        unreadCount = 0
        selectedTab = .feed
        withAnimation { phase = .auth }
    }

    func deleteAccount() async {
        do {
            try await backend.deleteAccount()
            players.releaseAll()
            session = nil
            currentUser = nil
            withAnimation { phase = .auth }
            show("Аккаунт и все твои ролики удалены", style: .success)
        } catch {
            show(error)
        }
    }

    func refreshUnread() async {
        guard !isGuest else { unreadCount = 0; return }
        let list = (try? await backend.notifications()) ?? []
        unreadCount = list.filter { !$0.isRead && (settings.inAppNotifications[$0.kind.rawValue] ?? true) }.count
    }

    // MARK: Guards & feedback

    /// Runs `action` only for signed-in users; guests get a friendly sign-in prompt.
    func requireAccount(_ action: () -> Void) {
        if isGuest { showAuthPrompt = true; Haptics.tap() } else { action() }
    }

    func show(_ text: String, style: ToastMessage.Style = .info) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = ToastMessage(text: text, style: style) }
        if style == .error { Haptics.error() }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { withAnimation { self?.toast = nil } }
        }
    }

    func show(_ error: Error) {
        if case BackendError.accountRequired = error { showAuthPrompt = true; return }
        if error is CancellationError { return }
        if case BackendError.unauthorized = error {
            show("Сессия истекла — войди снова", style: .error)
            Task { await signOut() }
            return
        }
        show(error.localizedDescription, style: .error)
    }

    // MARK: Streak + interests

    func record(_ event: StreakTracker.Event) {
        var s = streak
        let unlocked = streakTracker.record(event, in: &s)
        streak = s
        if let first = unlocked.first, settings.streakEnabled {
            newlyUnlocked = first
            show("Достижение: \(first.title)", style: .success)
        }
    }

    func recordInterest(_ signal: InterestProfile.Signal, video: Video) {
        var p = interests
        p.record(signal, video: video)
        interests = p
    }

    var currentStreak: Int { streakTracker.currentStreak(streak) }

    // MARK: Search history (local only)

    func remember(query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var h = settings.searchHistory.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        h.insert(q, at: 0)
        settings.searchHistory = Array(h.prefix(10))
    }

    // MARK: Demo controls

    func setDemoCondition(_ c: DemoBackend.NetworkCondition) async {
        demoCondition = c
        await (backend as? DemoBackend)?.setCondition(c)
    }

    func resetDemo() async {
        await (backend as? DemoBackend)?.resetAllData()
        streak = StreakState(isEnabled: settings.streakEnabled)
        interests = InterestProfile()
        contentVersion += 1
        await refreshCurrentUser()
        show("Демо-данные сброшены", style: .success)
    }

    func compose(_ context: ComposeContext = ComposeContext()) {
        requireAccount {
            players.suspend()
            composeContext = context
        }
    }
}

enum MainTab: Hashable { case feed, discover, create, activity, profile }

/// Pre-filled state for the creation flow (challenge tag, DUO REACT target…).
struct ComposeContext: Identifiable {
    let id = UUID()
    var challenge: Challenge?
    var replyTo: FeedItem?
}

// MARK: - Backend factory & Keychain

enum BackendFactory {
    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> FlexBackend {
        let isUITest = arguments.contains("-uitest")
        let store: SessionStore = isUITest ? InMemorySessionStore() : KeychainSessionStore()
        let info = Bundle.main.infoDictionary ?? [:]
        let forcedDemo = (info["FLEXUP_BACKEND_MODE"] as? String) == "demo" || isUITest || arguments.contains("-demo")
        if !forcedDemo, let config = SupabaseConfig.from(values: info) {
            return SupabaseBackend(config: config, sessionStore: store)
        }
        let media = MediaStore.mediaDirectory
        let storage: URL? = isUITest ? nil : media.appendingPathComponent("demo-state.json")
        return DemoBackend(storageURL: storage, mediaDirectory: media, sessionStore: store,
                           latency: isUITest ? 0.05 : 0.35, uploadChunkDelay: isUITest ? 0.02 : 0.12,
                           extraVideos: isUITest ? [] : MediaStore.localTestVideos())
    }
}

/// Stores the auth session in the iOS Keychain (this device only, after first unlock).
final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    private let service = "app.flexup.session"
    private let account = "current"

    func load() -> AuthSession? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder.flex.decode(AuthSession.self, from: data)
    }

    func save(_ session: AuthSession?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let session, let data = try? JSONEncoder.flex.encode(session) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
