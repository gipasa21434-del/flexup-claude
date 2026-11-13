import SwiftUI
import FlexCore

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var scope: SearchScope = .all
    @Published var sort: SearchSort = .relevance
    @Published var mood: Mood?
    @Published var results = SearchResults()
    @Published var suggestions: [String] = []
    @Published var state: LoadState = .idle
    @Published var trending: [HashtagSummary] = []
    @Published var challenge: Challenge?
    @Published var trendState: LoadState = .idle
    /// Video results joined with authors, for the grid.
    @Published var videoItems: [FeedItem] = []
    private var searchTask: Task<Void, Never>?

    func loadTrends(app: AppModel) async {
        if trending.isEmpty { trendState = .loading }
        do {
            async let t = app.backend.trendingHashtags()
            async let c = app.backend.challenges()
            trending = try await t
            challenge = ChallengeEngine().current(from: try await c)
            trendState = .loaded
        } catch {
            trendState = .failed(error.localizedDescription)
        }
    }

    /// Debounced live search (300 ms) with cancellation of stale requests.
    func queryChanged(app: AppModel) {
        searchTask?.cancel()
        let q = query
        searchTask = Task {
            suggestions = await app.backend.suggestions(prefix: q, history: app.settings.searchHistory)
            guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { results = SearchResults(); state = .idle; return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await run(app: app)
        }
    }

    func run(app: AppModel) async {
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state = .loading
        do {
            let r = try await app.backend.search(q, scope: scope, sort: sort, mood: mood)
            guard q == query else { return }
            results = r
            videoItems = Array(r.videoItems.prefix(60))
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var vm = SearchViewModel()
    @StateObject private var router = Router()
    @State private var isSearching = false

    var body: some View {
        NavigationStack(path: $router.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        discover
                    } else {
                        filters
                        searchResults
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Поиск")
            .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Люди, ролики, #хештеги")
            .searchSuggestions {
                ForEach(vm.suggestions, id: \.self) { s in
                    Label(s, systemImage: s.hasPrefix("#") ? "number" : s.hasPrefix("@") ? "person" : "clock.arrow.circlepath")
                        .searchCompletion(s)
                }
            }
            .onSubmit(of: .search) {
                app.remember(query: vm.query)
                Task { await vm.run(app: app) }
            }
            .onChange(of: vm.query) { _ in vm.queryChanged(app: app) }
            .onChange(of: vm.scope) { _ in Task { await vm.run(app: app) } }
            .onChange(of: vm.sort) { _ in Task { await vm.run(app: app) } }
            .onChange(of: vm.mood) { _ in Task { await vm.run(app: app) } }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .task {
                if vm.trendState == .idle { await vm.loadTrends(app: app) }
                vm.queryChanged(app: app)
            }
            .refreshable { await vm.loadTrends(app: app) }
        }
        .environmentObject(router)
    }

    // MARK: Discover (empty query)

    @ViewBuilder private var discover: some View {
        if let ch = vm.challenge {
            Button { router.go(.challenges) } label: { ChallengeBanner(challenge: ch) }
                .buttonStyle(.plain).padding(.horizontal, 16)
                .accessibilityIdentifier("discover.challenge")
        }
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Настроение")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Mood.allCases) { m in
                        Chip(title: "\(m.emoji) \(m.title)") {
                            vm.mood = m
                            vm.query = "#" + (m.relatedTags.sorted().first ?? m.rawValue)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)

        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "В тренде")
            switch vm.trendState {
            case .idle, .loading:
                ForEach(0..<5, id: \.self) { _ in SkeletonBlock(height: 52, corner: 12) }
            case let .failed(m):
                ErrorStateView(error: SimpleError(message: m)) { Task { await vm.loadTrends(app: app) } }
            case .loaded:
                if vm.trending.isEmpty {
                    EmptyStateView(symbol: "chart.line.uptrend.xyaxis", title: "Трендов пока нет", message: "Опубликуй ролик с хештегом — и он может стать первым.")
                }
                ForEach(Array(vm.trending.enumerated()), id: \.element.tag) { i, t in
                    Button { router.go(.hashtag(t.tag)) } label: { TrendRow(rank: i + 1, tag: t) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discover.trend.\(t.tag)")
                }
            }
        }
        .padding(.horizontal, 16)

        if !app.settings.searchHistory.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Ты искал", trailing: "Очистить") { app.settings.searchHistory = [] }
                FlowLayout(spacing: 8) {
                    ForEach(app.settings.searchHistory, id: \.self) { h in Chip(title: h, symbol: "clock") { vm.query = h } }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: Results

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Что искать", selection: $vm.scope) {
                ForEach(SearchScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        Picker("Сортировка", selection: $vm.sort) { ForEach(SearchSort.allCases) { Text($0.title).tag($0) } }
                    } label: {
                        Label(vm.sort.title, systemImage: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 36)
                            .background(Theme.elevated, in: Capsule()).foregroundColor(Theme.textPrimary)
                    }
                    .accessibilityIdentifier("search.sort")
                    Chip(title: "Любое настроение", isSelected: vm.mood == nil) { vm.mood = nil }
                    ForEach(Mood.allCases) { m in
                        Chip(title: "\(m.emoji) \(m.title)", isSelected: vm.mood == m) { vm.mood = vm.mood == m ? nil : m }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var searchResults: some View {
        switch vm.state {
        case .idle, .loading:
            VStack(spacing: 10) { ForEach(0..<4, id: \.self) { _ in SkeletonBlock(height: 56, corner: 12) } }.padding(.horizontal, 16)
        case let .failed(m):
            ErrorStateView(error: SimpleError(message: m)) { Task { await vm.run(app: app) } }
        case .loaded:
            if vm.results.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: "Ничего не нашлось",
                               message: "Проверь написание или попробуй хештег — например, #flexchallenge.")
                    .accessibilityIdentifier("search.empty")
            } else {
                if !vm.results.users.isEmpty && vm.scope != .videos && vm.scope != .hashtags {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionHeader(title: "Люди").padding(.horizontal, 16)
                        ForEach(vm.results.users.prefix(vm.scope == .users ? 50 : 3)) { u in
                            Button { app.remember(query: vm.query); router.go(.profile(u.id)) } label: { UserRow(user: u) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("search.user.\(u.username)")
                        }
                    }
                }
                if !vm.results.hashtags.isEmpty && vm.scope != .videos && vm.scope != .users {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Хештеги")
                        FlowLayout(spacing: 8) {
                            ForEach(vm.results.hashtags.prefix(vm.scope == .hashtags ? 50 : 8)) { h in
                                Chip(title: "#\(h.tag) · \(h.videoCount)") { app.remember(query: vm.query); router.go(.hashtag(h.tag)) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if !vm.videoItems.isEmpty && vm.scope != .users && vm.scope != .hashtags {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Ролики").padding(.horizontal, 16)
                        VideoGrid(items: vm.videoItems)
                    }
                }
            }
        }
    }
}

struct UserRow: View {
    let user: UserProfile
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(user: user, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(user.displayName).font(.headline).foregroundColor(Theme.textPrimary)
                    if user.isVerified { VerifiedBadge() }
                }
                Text("@\(user.username) · \(CountFormatter.short(user.followersCount)) подписчиков")
                    .font(.subheadline).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct TrendRow: View {
    let rank: Int
    let tag: HashtagSummary
    var body: some View {
        HStack(spacing: 12) {
            Text("\(rank)").font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(rank <= 3 ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.textSecondary))
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("#\(tag.tag)").font(.headline).foregroundColor(Theme.textPrimary)
                Text("\(tag.videoCount) роликов · \(CountFormatter.short(tag.totalViews)) просмотров")
                    .font(.caption).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.textSecondary)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ChallengeBanner: View {
    let challenge: Challenge
    var body: some View {
        HStack(spacing: 14) {
            Text(challenge.emoji).font(.system(size: 40))
            VStack(alignment: .leading, spacing: 4) {
                Text("FLEX CHALLENGE ДНЯ").font(.caption.weight(.heavy)).foregroundColor(.white.opacity(0.85))
                Text(challenge.title).font(.title3.bold()).foregroundColor(.white)
                Text("#\(challenge.tag)").font(.subheadline.weight(.semibold)).foregroundColor(Theme.teal)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(.white)
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Theme.violet, Color(hex: 0x3B0F80)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        )
        .glow(Theme.violet, radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Открыть челлендж")
    }
}

// MARK: - Hashtag screen

struct HashtagView: View {
    let tag: String
    @EnvironmentObject private var app: AppModel
    @State private var items: [FeedItem] = []
    @State private var sort: SearchSort = .popular
    @State private var state: LoadState = .idle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.brandGradient).frame(width: 72, height: 72)
                        Image(systemName: "number").font(.system(size: 34, weight: .black)).foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("#\(tag)").font(.title2.bold()).foregroundColor(Theme.textPrimary)
                        Text("\(items.count) роликов · \(CountFormatter.short(items.reduce(0) { $0 + $1.video.viewsCount })) просмотров")
                            .font(.subheadline).foregroundColor(Theme.textSecondary)
                    }
                }
                .padding(.horizontal, 16)
                HStack {
                    Picker("Сортировка", selection: $sort) {
                        Text("Популярные").tag(SearchSort.popular)
                        Text("Новые").tag(SearchSort.newest)
                    }
                    .pickerStyle(.segmented)
                    Button { app.compose(ComposeContext(challenge: Challenge(tag: tag, title: "#\(tag)", details: "", emoji: "#",
                                                                               startsAt: .distantPast, endsAt: .distantFuture))) } label: {
                        Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Theme.brandGradient)
                    }
                    .accessibilityLabel("Снять ролик с #\(tag)")
                }
                .padding(.horizontal, 16)
                switch state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                case let .failed(m):
                    ErrorStateView(error: SimpleError(message: m)) { Task { await load() } }
                case .loaded:
                    if items.isEmpty {
                        EmptyStateView(symbol: "number", title: "По #\(tag) пока ничего", message: "Стань первым, кто снимет ролик с этим тегом.")
                    } else {
                        VideoGrid(items: items)
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("#\(tag)")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sort) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await app.backend.videos(withTag: tag, sort: sort)
            state = .loaded
        } catch { state = .failed(error.localizedDescription) }
    }
}
