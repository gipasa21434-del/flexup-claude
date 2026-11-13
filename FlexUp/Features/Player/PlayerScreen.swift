import SwiftUI
import FlexCore

/// Full-screen vertical player for a fixed list (profile grid, hashtag, search, leaderboard).
struct PlayerScreen: View {
    let token: PlayerListToken
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router
    @StateObject private var vm: FeedViewModel
    @StateObject private var sheets = FeedSheets()
    @Environment(\.dismiss) private var dismiss

    init(token: PlayerListToken) {
        self.token = token
        _vm = StateObject(wrappedValue: FeedViewModel(source: .fixed, items: token.items, startAt: token.startAt))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            FeedPagerView(vm: vm, router: router, sheets: sheets, bottomInset: 24)
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.bold)).foregroundColor(.white)
                    .frame(width: Theme.minTap, height: Theme.minTap)
                    .background(Color.black.opacity(0.35), in: Circle())
            }
            .padding(.leading, 12).padding(.top, 4)
            .accessibilityLabel("Назад")
            .accessibilityIdentifier("player.back")
        }
        .toolbar(.hidden, for: .navigationBar)
        .feedSheets(sheets: sheets, vm: vm)
        .onAppear {
            vm.app = app
            vm.activate()
        }
        .onDisappear {
            for case let .video(id) in vm.pages where id != app.players.activeID { app.players.release(id) }
            if let id = vm.activeItem?.id { app.players.deactivate(id: id) }
        }
    }
}

/// 3-column grid of video covers. Tapping opens `PlayerScreen` starting at that video.
struct VideoGrid: View {
    let items: [FeedItem]
    var showViews = true
    var rankBadges: [UUID: Int] = [:]
    @EnvironmentObject private var router: Router

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(items) { item in
                Button {
                    router.go(.player(PlayerListToken(items: items, startAt: item.id)))
                } label: {
                    VideoCover(item: item, showViews: showViews, rank: rankBadges[item.id])
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ролик @\(item.author.username): \(item.video.caption). \(CountFormatter.short(item.video.viewsCount)) просмотров")
                .accessibilityIdentifier("grid.video")
            }
        }
    }
}

struct VideoCover: View {
    let item: FeedItem
    var showViews = true
    var rank: Int? = nil
    @State private var image: UIImage?

    var body: some View {
        Color(hex: 0x1A1B22)
            .aspectRatio(9 / 16, contentMode: .fit)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Rectangle().fill(Theme.elevated).shimmer() }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                if showViews {
                    Label(CountFormatter.short(item.video.viewsCount), systemImage: "play.fill")
                        .font(.caption2.weight(.bold)).foregroundColor(.white).shadow(radius: 2).padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if let rank {
                        Text("#\(rank)").font(.caption.weight(.heavy)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(rank <= 3 ? AnyShapeStyle(Theme.brandGradientH) : AnyShapeStyle(Color.black.opacity(0.5)), in: Capsule())
                    }
                    if item.video.visibility != .everyone {
                        Image(systemName: "lock.fill").font(.caption2).foregroundColor(.white).padding(4)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    if item.video.replyToVideoID != nil {
                        Image(systemName: "person.2.wave.2.fill").font(.caption2).foregroundColor(.white).padding(4)
                            .background(Theme.violet.opacity(0.8), in: Circle())
                    }
                }
                .padding(6)
            }
            .task(id: item.id) {
                let src = item.video.thumbnail ?? item.video.source
                if let url = MediaStore.thumbnailURL(for: src) { image = await ImageLoader.shared.image(for: url) }
            }
    }
}

/// DUO REACT hub for a video: the original + all reactions to it.
struct ReactionsView: View {
    let videoID: UUID
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router
    @State private var original: FeedItem?
    @State private var reactions: [FeedItem] = []
    @State private var state: LoadState = .idle
    @State private var duoTarget: FeedItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let original {
                    HStack(spacing: 12) {
                        VideoCover(item: original, showViews: false).frame(width: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .onTapGesture { router.go(.player(PlayerListToken(items: [original], startAt: original.id))) }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Оригинал").font(.caption.weight(.bold)).foregroundColor(Theme.textSecondary)
                            Text("@\(original.author.username)").font(.headline)
                            Text(original.video.caption).font(.subheadline).foregroundColor(Theme.textSecondary).lineLimit(3)
                            Button { app.requireAccount { duoTarget = original } } label: {
                                Label("Записать DUO REACT", systemImage: "person.2.wave.2.fill")
                            }
                            .buttonStyle(.borderedProminent).tint(Theme.violet)
                        }
                    }
                    .card()
                }
                SectionHeader(title: "Реакции · \(reactions.count)")
                switch state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity).padding(40)
                case let .failed(m):
                    ErrorStateView(error: SimpleError(message: m)) { Task { await load() } }
                case .loaded:
                    if reactions.isEmpty {
                        EmptyStateView(symbol: "person.2.wave.2", title: "Реакций пока нет",
                                       message: "Стань первым — запиши свою реакцию на этот ролик.")
                    } else {
                        VideoGrid(items: reactions)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("DUO REACT")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $duoTarget) { DuoReactIntroSheet(item: $0).environmentObject(app).presentationDetents([.medium, .large]) }
    }

    private func load() async {
        state = .loading
        do {
            async let o = app.backend.feedItem(videoID: videoID)
            async let r = app.backend.reactions(to: videoID)
            original = try await o
            reactions = try await r
            state = .loaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
