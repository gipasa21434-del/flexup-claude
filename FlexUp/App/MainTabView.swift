import SwiftUI
import FlexCore

struct MainTabView: View {
    @EnvironmentObject private var app: AppModel
    static let barHeight: CGFloat = 56

    var body: some View {
        GeometryReader { geo in
            let bottomSafe = geo.safeAreaInsets.bottom
            ZStack(alignment: .bottom) {
                // Tabs stay alive (state preserved) but only the visible one is interactive.
                ZStack {
                    FeedView(bottomInset: Self.barHeight + bottomSafe)
                        .opacity(app.selectedTab == .feed ? 1 : 0)
                        .allowsHitTesting(app.selectedTab == .feed)
                        .accessibilityHidden(app.selectedTab != .feed)
                    if app.selectedTab == .discover {
                        DiscoverView().padding(.bottom, Self.barHeight)
                    }
                    if app.selectedTab == .activity {
                        ActivityView().padding(.bottom, Self.barHeight)
                    }
                    if app.selectedTab == .profile {
                        MyProfileTab().padding(.bottom, Self.barHeight)
                    }
                }
                TabBar(bottomSafe: bottomSafe)
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .fullScreenCover(item: $app.composeContext, onDismiss: { app.players.resume() }) { ctx in
            CreateFlowView(context: ctx).environmentObject(app)
        }
        .task { await app.refreshUnread() }
    }
}

private struct TabBar: View {
    @EnvironmentObject private var app: AppModel
    let bottomSafe: CGFloat

    var body: some View {
        let dark = app.selectedTab == .feed
        HStack(spacing: 0) {
            item(.feed, "Лента", "play.house", "play.house.fill")
            item(.discover, "Поиск", "magnifyingglass", "magnifyingglass")
            Button { app.compose() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.brandGradientH).frame(width: 52, height: 36)
                    Image(systemName: "plus").font(.system(size: 20, weight: .heavy)).foregroundColor(.white)
                }
                .glow(Theme.violet, radius: 8)
                .frame(maxWidth: .infinity, minHeight: MainTabView.barHeight)
            }
            .accessibilityLabel("Создать ролик")
            .accessibilityIdentifier("tab.create")
            item(.activity, "Активность", "bell", "bell.fill", badge: app.unreadCount)
            item(.profile, "Профиль", "person", "person.fill")
        }
        .padding(.bottom, bottomSafe)
        .background(
            (dark ? Color.black : Theme.surface)
                .overlay(Rectangle().fill(dark ? Color.white.opacity(0.08) : Theme.stroke).frame(height: 0.5), alignment: .top)
                .ignoresSafeArea()
        )
        .forceDark(dark)
    }

    private func item(_ tab: MainTab, _ title: String, _ icon: String, _ selectedIcon: String, badge: Int = 0) -> some View {
        let selected = app.selectedTab == tab
        let dark = app.selectedTab == .feed
        return Button {
            if app.selectedTab == tab { Haptics.tap() }
            app.selectedTab = tab
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: selected ? selectedIcon : icon).font(.system(size: 20, weight: .semibold))
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)").font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(Theme.like, in: Capsule()).offset(x: 10, y: -6)
                    }
                }
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundColor(selected ? (dark ? .white : Theme.accentText) : (dark ? .white.opacity(0.6) : Theme.textSecondary))
            .frame(maxWidth: .infinity, minHeight: MainTabView.barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "\(title), непрочитанных: \(badge)" : title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab.\(tab)")
    }
}

extension View {
    /// Forces dark appearance only when `on` (the feed is always dark; other tabs follow the system).
    @ViewBuilder func forceDark(_ on: Bool) -> some View {
        if on { environment(\.colorScheme, .dark) } else { self }
    }
}

struct MyProfileTab: View {
    @EnvironmentObject private var app: AppModel
    @StateObject private var router = Router()

    var body: some View {
        NavigationStack(path: $router.path) {
            Group {
                if let me = app.currentUser {
                    ProfileView(userID: me.id)
                } else {
                    EmptyStateView(symbol: "person.crop.circle.badge.questionmark", title: "Ты смотришь как гость",
                                   message: "Создай аккаунт, чтобы публиковать ролики, ставить лайки и собирать стрик.",
                                   actionTitle: "Войти или зарегистрироваться") { Task { await app.signOut() } }
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                                    .accessibilityLabel("Настройки")
                            }
                        }
                }
            }
            .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .environmentObject(router)
    }
}

/// Resolves navigation routes to screens (used by every NavigationStack).
struct RouteView: View {
    let route: Route
    var body: some View {
        switch route {
        case let .profile(id): ProfileView(userID: id)
        case let .hashtag(tag): HashtagView(tag: tag)
        case .challenges: ChallengesView()
        case let .player(token): PlayerScreen(token: token)
        case .streak: StreakView()
        case .settings: SettingsView()
        case let .reactions(id): ReactionsView(videoID: id)
        }
    }
}
