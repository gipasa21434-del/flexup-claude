import SwiftUI
import FlexCore

/// Main feed tab: «Для тебя» / «Подписки», MOOD FEED filter, streak chip and volume control.
struct FeedView: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var vm = FeedViewModel(source: .main)
    @StateObject private var router = Router()
    @StateObject private var sheets = FeedSheets()
    @State private var showMood = false
    let bottomInset: CGFloat

    var body: some View {
        NavigationStack(path: $router.path) {
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                switch vm.state {
                case .idle, .loading:
                    FeedSkeleton()
                case let .failed(message):
                    ErrorStateView(error: SimpleError(message: message)) { vm.reload() }
                        .environment(\.colorScheme, .dark)
                case .loaded:
                    if vm.pages.isEmpty {
                        emptyFeed
                    } else {
                        FeedPagerView(vm: vm, router: router, sheets: sheets, bottomInset: bottomInset)
                    }
                }
                topBar
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
            .feedSheets(sheets: sheets, vm: vm)
            .sheet(isPresented: $showMood) {
                MoodPickerSheet(selected: vm.mood) { vm.setMood($0) }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: router.path.count) { count in
                // Pause the feed while another screen is pushed on top; resume when back.
                // Only pause the feed's own video: a pushed PlayerScreen may already own the active player.
                if count == 0 { vm.activate() } else if let id = vm.activeItem?.id { app.players.deactivate(id: id) }
            }
        }
        .environmentObject(router)
        .task {
            vm.app = app
            if vm.state == .idle { await vm.load() }
        }
        .onChange(of: app.contentVersion) { _ in vm.reload() }
        .onChange(of: app.selectedTab) { tab in
            if tab == .feed { if router.path.isEmpty { vm.activate() } }
            else if let id = vm.activeItem?.id { app.players.deactivate(id: id) }
        }
    }

    private var emptyFeed: some View {
        Group {
            if vm.kind == .following {
                EmptyStateView(symbol: "person.2", title: "Пока пусто",
                               message: "Подпишись на авторов — их новые ролики появятся здесь.",
                               actionTitle: "Найти авторов") { app.selectedTab = .discover }
            } else if let mood = vm.mood {
                EmptyStateView(symbol: "face.dashed", title: "Нет роликов с настроением «\(mood.title)»",
                               message: "Попробуй другое настроение или сбрось фильтр.",
                               actionTitle: "Сбросить настроение") { vm.setMood(nil) }
            } else {
                EmptyStateView(symbol: "sparkles.tv", title: "Лента пуста",
                               message: "Проверь фильтры контента в настройках или потяни вниз, чтобы обновить.",
                               actionTitle: "Обновить") { vm.reload() }
            }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            if app.settings.streakEnabled && app.settings.showStreakInFeed {
                Button { router.go(.streak) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: app.currentStreak > 0 ? "flame.fill" : "flame")
                            .foregroundStyle(LinearGradient(colors: [Theme.warning, Theme.like], startPoint: .top, endPoint: .bottom))
                        Text("\(app.currentStreak)").font(.subheadline.weight(.heavy)).foregroundColor(.white)
                    }
                    .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
                }
                .accessibilityLabel("FLEX STREAK: \(app.currentStreak) дней подряд")
                .accessibilityIdentifier("feed.streak")
            } else {
                Spacer().frame(width: Theme.minTap)
            }
            Spacer()
            HStack(spacing: 18) {
                ForEach(FeedKind.allCases.reversed(), id: \.self) { k in
                    Button { vm.setKind(k) } label: {
                        VStack(spacing: 4) {
                            Text(k.title)
                                .font(.headline.weight(vm.kind == k ? .heavy : .semibold))
                                .foregroundColor(vm.kind == k ? .white : .white.opacity(0.65))
                            Capsule().fill(vm.kind == k ? AnyShapeStyle(Theme.brandGradientH) : AnyShapeStyle(Color.clear))
                                .frame(width: 26, height: 3)
                        }
                        .frame(minHeight: Theme.minTap)
                    }
                    .accessibilityAddTraits(vm.kind == k ? .isSelected : [])
                    .accessibilityIdentifier("feed.tab.\(k.rawValue)")
                }
            }
            .shadow(color: .black.opacity(0.4), radius: 3)
            Spacer()
            Button { showMood = true } label: {
                Group {
                    if let mood = vm.mood { Text(mood.emoji).font(.title2) }
                    else { Image(systemName: "face.smiling").font(.title3.weight(.semibold)).foregroundColor(.white) }
                }
                .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
                .background(vm.mood != nil ? Circle().fill(Theme.violet.opacity(0.35)) : nil)
            }
            .accessibilityLabel(vm.mood.map { "MOOD FEED: \($0.title). Изменить" } ?? "MOOD FEED: выбрать настроение")
            .accessibilityIdentifier("feed.mood")
            Button { app.players.isMuted.toggle(); Haptics.tap() } label: {
                Image(systemName: app.players.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.title3).foregroundColor(.white)
                    .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
            }
            .accessibilityLabel(app.players.isMuted ? "Включить звук" : "Выключить звук")
            .accessibilityIdentifier("feed.mute")
        }
        .padding(.horizontal, 8)
        .background(Theme.topScrim.ignoresSafeArea(edges: .top).allowsHitTesting(false))
        .overlay(alignment: .bottom) {
            if let mood = vm.mood {
                Button { vm.setMood(nil) } label: {
                    Label("Настроение: \(mood.title)", systemImage: "xmark.circle.fill")
                        .font(.caption.weight(.bold)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.brandGradientH, in: Capsule())
                }
                .offset(y: 30)
                .accessibilityLabel("Сбросить настроение \(mood.title)")
            }
        }
    }
}

struct SimpleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The pager + "end of feed" card. Shared by the main feed and the fixed player screen.
struct FeedPagerView: View {
    @ObservedObject var vm: FeedViewModel
    let router: Router
    let sheets: FeedSheets
    let bottomInset: CGFloat
    @EnvironmentObject private var app: AppModel

    var body: some View {
        VerticalPager(ids: vm.pages, index: $vm.activeIndex,
                      onRefresh: vm.source == .main ? { await vm.load(force: true) } : nil) { page in
            Group {
                switch page {
                case let .video(id):
                    FeedItemView(id: id, bottomInset: bottomInset, players: app.players)
                case .end:
                    EndOfFeedCard { vm.reload() }
                }
            }
            .environmentObject(app)
            .environmentObject(vm)
            .environmentObject(router)
            .environmentObject(sheets)
            .environment(\.colorScheme, .dark)
        }
        .ignoresSafeArea()
    }
}

struct EndOfFeedCard: View {
    let restart: () -> Void
    @EnvironmentObject private var app: AppModel
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x1A1033), Color(hex: 0x0E0F13)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 56)).foregroundStyle(Theme.brandGradient)
                Text("Ты всё посмотрел").font(.title.bold()).foregroundColor(.white)
                Text("Новые ролики появятся позже. А пока — поучаствуй в челлендже дня или смени настроение ленты.")
                    .font(.subheadline).foregroundColor(.white.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 32)
                Button("Смотреть заново", action: restart).buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 260)
                Button("Снять свой ролик") { app.compose() }.buttonStyle(SecondaryButtonStyle()).frame(maxWidth: 260)
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Comments / report / DUO REACT sheets driven by `FeedSheets`.
    func feedSheets(sheets: FeedSheets, vm: FeedViewModel) -> some View {
        modifier(FeedSheetsModifier(sheets: sheets, vm: vm))
    }
}

private struct FeedSheetsModifier: ViewModifier {
    @ObservedObject var sheets: FeedSheets
    @ObservedObject var vm: FeedViewModel
    @EnvironmentObject private var app: AppModel

    func body(content: Content) -> some View {
        content
            .sheet(item: $sheets.comments) { item in
                CommentsSheet(item: item) { delta in vm.commentsChanged(item.id, delta: delta) }
                    .environmentObject(app)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $sheets.report) { item in
                ReportSheet(target: .video(item.id), title: "Пожаловаться на ролик") {
                    vm.remove { $0.id == item.id }
                }
                .environmentObject(app)
                .presentationDetents([.large])
            }
            .sheet(item: $sheets.duo) { item in
                DuoReactIntroSheet(item: item)
                    .environmentObject(app)
                    .presentationDetents([.medium, .large])
            }
    }
}
