import SwiftUI
import AVFoundation
import FlexCore

/// Navigation destinations shared by all stacks.
enum Route: Hashable {
    case profile(UUID)
    case hashtag(String)
    case challenges
    case player(PlayerListToken)
    case streak
    case settings
    case reactions(UUID)
}

/// Wraps a list of items for navigation (Hashable by a token so big arrays don't get hashed).
struct PlayerListToken: Hashable {
    let id = UUID()
    let items: [FeedItem]
    let startAt: UUID
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

@MainActor
final class Router: ObservableObject {
    @Published var path = NavigationPath()
    func go(_ r: Route) { path.append(r) }
}

/// Sheets requested from inside pager cells (cells can't reliably present sheets themselves).
@MainActor
final class FeedSheets: ObservableObject {
    @Published var comments: FeedItem?
    @Published var report: FeedItem?
    @Published var duo: FeedItem?
}

struct FeedItemView: View {
    let id: UUID
    /// Space reserved at the bottom (tab bar + home indicator) — passed in because hosted cells
    /// don't inherit the SwiftUI environment/safe area of the surrounding screen.
    var bottomInset: CGFloat = 0
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var vm: FeedViewModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var sheets: FeedSheets
    @ObservedObject var players: PlayerPool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burstLocation: CGPoint?
    @State private var showDeleteConfirm = false

    var body: some View {
        if let item = vm.item(id) {
            content(item)
        } else {
            Color.black
        }
    }

    @ViewBuilder
    private func content(_ item: FeedItem) -> some View {
        let isActive = players.activeID == item.id
        let state = players.states[item.id]
        ZStack {
                Color.black
                if vm.url(for: item) != nil {
                    PlayerLayerView(player: players.existingPlayer(for: item.id))
                        .accessibilityHidden(true)
                        .opacity(state == .ready ? 1 : 0.001)
                } else {
                    unavailable(retry: nil)
                }
                if state == nil || state == .loading {
                    ThumbnailBackground(source: item.video.thumbnail ?? item.video.source)
                    ProgressView().tint(.white).scaleEffect(1.2).accessibilityLabel("Видео загружается")
                }
                if case .failed = state, let url = vm.url(for: item) {
                    unavailable { players.retry(id: item.id, url: url) }
                }

                // Gestures: single tap = pause/resume, double tap = like with a heart burst.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { v in
                            burstLocation = v.location
                            vm.toggleLike(item.id, forceOn: true)
                        }
                        .exclusively(before: TapGesture().onEnded { if isActive { players.togglePause() } })
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Видео от \(item.author.displayName). \(item.video.caption)")
                    .accessibilityHint("Нажми, чтобы поставить на паузу. Дважды — лайк.")
                    .accessibilityAddTraits(.startsMediaSession)
                    .accessibilityIdentifier("feed.video")

                if isActive && players.isUserPaused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 64)).foregroundColor(.white.opacity(0.85))
                        .shadow(radius: 8).allowsHitTesting(false)
                        .transition(.scale.combined(with: .opacity))
                }

                if let loc = burstLocation, vm.burstID == item.id, !reduceMotion, !app.settings.reduceEffects {
                    HeartBurst().position(loc).allowsHitTesting(false)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { burstLocation = nil; vm.burstID = nil }
                        }
                }

                VStack(spacing: 0) {
                    Spacer()
                    ZStack(alignment: .bottom) {
                        Theme.scrim.frame(height: 320).allowsHitTesting(false)
                        HStack(alignment: .bottom, spacing: 12) {
                            InfoPanel(item: item)
                            ActionRail(item: item, showDelete: $showDeleteConfirm)
                        }
                        .padding(.leading, 14).padding(.trailing, 8)
                        .padding(.bottom, bottomInset + 14)
                    }
                    if isActive {
                        ProgressStrip(progress: players.progress)
                            .padding(.bottom, bottomInset)
                    }
                }
        }
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.2), value: players.isUserPaused)
        .confirmationDialog("Удалить ролик?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить навсегда", role: .destructive) { vm.delete(item.id) }
        } message: {
            Text("Ролик, его лайки и комментарии будут удалены.")
        }
    }

    private func unavailable(retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.system(size: 40))
            Text("Видео недоступно").font(.headline)
            Text("Возможно, плохая сеть или файл удалён.").font(.footnote).opacity(0.7)
            if let retry {
                Button("Повторить", action: retry).buttonStyle(.borderedProminent).tint(Theme.violet)
            }
        }
        .foregroundColor(.white)
        .padding()
    }
}

struct ThumbnailBackground: View {
    let source: VideoSource
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color(hex: 0x111218)
            if let image { Image(uiImage: image).resizable().scaledToFill().blur(radius: 6).opacity(0.7) }
        }
        .clipped()
        .task(id: source) {
            if let url = MediaStore.thumbnailURL(for: source) { image = await ImageLoader.shared.image(for: url) }
        }
    }
}

// MARK: - Info panel

private struct InfoPanel: View {
    let item: FeedItem
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var vm: FeedViewModel
    @EnvironmentObject private var router: Router
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.video.replyToVideoID != nil {
                Label("DUO REACT", systemImage: "person.2.wave.2.fill")
                    .font(.caption.weight(.heavy))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Theme.brandGradientH, in: Capsule())
                    .foregroundColor(.white)
                    .onTapGesture { if let o = item.video.replyToVideoID { router.go(.reactions(o)) } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Открыть оригинал и другие реакции")
            }
            Button { router.go(.profile(item.author.id)) } label: {
                HStack(spacing: 6) {
                    Text("@\(item.author.username)").font(.headline)
                    if item.author.isVerified { VerifiedBadge() }
                    Text("· \(RelativeTime.short(from: item.video.createdAt))").font(.subheadline).opacity(0.8)
                    if item.video.isDemo == false && app.isDemo { DemoBadge() }
                }
            }
            .buttonStyle(.plain)
            .overlayText()
            .accessibilityIdentifier("feed.author")

            CaptionText(caption: item.video.caption, expanded: expanded) { tag in router.go(.hashtag(tag)) }
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }

            if let tag = item.video.challengeTag ?? item.video.hashtags.first(where: { $0 == "flexchallenge" }) {
                Button { router.go(.challenges) } label: {
                    Label("Челлендж #\(tag)", systemImage: "trophy.fill").font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .overlay(Capsule().stroke(Theme.teal.opacity(0.7), lineWidth: 1))
                }
                .buttonStyle(.plain).foregroundColor(.white)
            }

            HStack(spacing: 6) {
                Image(systemName: "music.note")
                MarqueeText(text: item.video.musicTitle)
            }
            .font(.footnote.weight(.medium))
            .overlayText()
            .frame(maxWidth: 220, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Музыка: \(item.video.musicTitle)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Caption with tappable #hashtags (built with AttributedString links handled by OpenURLAction).
struct CaptionText: View {
    let caption: String
    var expanded: Bool
    let onTag: (String) -> Void

    var body: some View {
        Text(attributed)
            .font(.subheadline)
            .lineLimit(expanded ? 8 : 2)
            .overlayText()
            .tint(.white)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "flexup", url.host == "tag" {
                    onTag(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
                    return .handled
                }
                return .systemAction
            })
    }

    private var attributed: AttributedString {
        var out = AttributedString()
        let words = caption.split(separator: " ", omittingEmptySubsequences: false)
        for (i, w) in words.enumerated() {
            var piece = AttributedString(String(w))
            let tags = HashtagParser.extract(from: String(w))
            if let tag = tags.first, w.hasPrefix("#"),
               let url = URL(string: "flexup://tag/\(tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag)") {
                piece.link = url
                piece.font = .subheadline.bold()
            }
            out += piece
            if i < words.count - 1 { out += AttributedString(" ") }
        }
        return out
    }
}

struct MarqueeText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        GeometryReader { geo in
            Text(text + "     " + text)
                .lineLimit(1)
                .fixedSize()
                .offset(x: animate && !reduceMotion ? -textWidth : 0)
                .animation(reduceMotion ? nil : .linear(duration: Double(max(6, text.count / 3))).repeatForever(autoreverses: false), value: animate)
                .onAppear { animate = true }
                .frame(width: geo.size.width, alignment: .leading)
                .clipped()
        }
        .frame(height: 18)
    }
    private var textWidth: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .footnote)
        return ((text + "     ") as NSString).size(withAttributes: [.font: font]).width
    }
}

// MARK: - Action rail

private struct ActionRail: View {
    let item: FeedItem
    @Binding var showDelete: Bool
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var vm: FeedViewModel
    @EnvironmentObject private var router: Router
    @EnvironmentObject private var sheets: FeedSheets

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottom) {
                Button { router.go(.profile(item.author.id)) } label: { AvatarView(user: item.author, size: 48, ring: true) }
                    .buttonStyle(PressableStyle())
                if !item.isFollowingAuthor && !vm.isMine(item) {
                    Button { vm.toggleFollow(item.id) } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .heavy)).foregroundColor(.white)
                            .frame(width: 22, height: 22).background(Theme.violet, in: Circle())
                    }
                    .offset(y: 10)
                    .accessibilityLabel("Подписаться на \(item.author.displayName)")
                    .accessibilityIdentifier("feed.follow")
                }
            }
            .padding(.bottom, 6)

            RailButton(symbol: item.isLiked ? "heart.fill" : "heart", count: item.video.likesCount,
                       tint: item.isLiked ? Theme.like : .white, label: item.isLiked ? "Убрать лайк" : "Лайк",
                       id: "feed.like", bounce: item.isLiked) { vm.toggleLike(item.id) }
            RailButton(symbol: "bubble.right.fill", count: item.video.commentsCount, label: "Комментарии", id: "feed.comments") {
                sheets.comments = item
            }
            RailButton(symbol: item.isSaved ? "bookmark.fill" : "bookmark", count: item.video.savesCount,
                       tint: item.isSaved ? Theme.teal : .white, label: item.isSaved ? "Убрать из сохранённого" : "Сохранить",
                       id: "feed.save", bounce: item.isSaved) { vm.toggleSave(item.id) }
            ShareButton(item: item)
            RailButton(symbol: "person.2.wave.2.fill", count: nil, label: "DUO REACT — ответить реакцией", id: "feed.duo", caption: "Duo") {
                app.requireAccount { sheets.duo = item }
            }
            Menu {
                if vm.isMine(item) {
                    Button(role: .destructive) { showDelete = true } label: { Label("Удалить ролик", systemImage: "trash") }
                } else {
                    Button { app.requireAccount { sheets.report = item } } label: { Label("Пожаловаться", systemImage: "flag") }
                    Button { vm.notInterested(item.id) } label: { Label("Не интересно", systemImage: "hand.thumbsdown") }
                    Button(role: .destructive) { vm.block(authorOf: item.id) } label: {
                        Label("Заблокировать @\(item.author.username)", systemImage: "nosign")
                    }
                }
                Button { router.go(.reactions(item.id)) } label: { Label("Реакции на ролик", systemImage: "person.2") }
                Button { app.players.isMuted.toggle() } label: {
                    Label(app.players.isMuted ? "Включить звук" : "Выключить звук",
                          systemImage: app.players.isMuted ? "speaker.wave.2" : "speaker.slash")
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                    .frame(width: Theme.minTap, height: Theme.minTap).shadow(radius: 3)
            }
            .accessibilityLabel("Ещё")
            .accessibilityIdentifier("feed.more")
        }
        .frame(width: 60)
    }
}

private struct RailButton: View {
    let symbol: String
    let count: Int?
    var tint: Color = .white
    let label: String
    let id: String
    var bounce = false
    var caption: String? = nil
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(tint)
                    .scaleEffect(bounce && !reduceMotion ? 1.12 : 1)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.45), value: bounce)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                if let count {
                    Text(CountFormatter.short(count)).font(.caption.weight(.bold)).foregroundColor(.white)
                        .contentTransition(.numericText())
                        .shadow(radius: 2)
                } else if let caption {
                    Text(caption).font(.caption.weight(.bold)).foregroundColor(.white).shadow(radius: 2)
                }
            }
            .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityValue(count.map { CountFormatter.short($0) } ?? "")
        .accessibilityIdentifier(id)
    }
}

private struct ShareButton: View {
    let item: FeedItem
    @EnvironmentObject private var vm: FeedViewModel
    var body: some View {
        let text = "Смотри во FLEX UP: @\(item.author.username) — \(item.video.caption)"
        Group {
            if let url = shareURL {
                ShareLink(item: url, subject: Text("FLEX UP"), message: Text(text)) { label }
            } else {
                ShareLink(item: text) { label }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { vm.didShare(item.id) })
        .accessibilityLabel("Поделиться")
        .accessibilityIdentifier("feed.share")
    }
    private var shareURL: URL? {
        switch item.video.source {
        case .remote(let u): return u
        default: return MediaStore.url(for: item.video.source)
        }
    }
    private var label: some View {
        VStack(spacing: 4) {
            Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 28, weight: .semibold)).foregroundColor(.white).shadow(radius: 3)
            Text(CountFormatter.short(item.video.sharesCount)).font(.caption.weight(.bold)).foregroundColor(.white).shadow(radius: 2)
        }
        .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
    }
}

struct ProgressStrip: View {
    @ObservedObject var progress: PlaybackProgress
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.2))
                Rectangle().fill(Theme.brandGradientH).frame(width: geo.size.width * progress.value)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

struct HeartBurst: View {
    @State private var phase = false
    var body: some View {
        ZStack {
            ForEach(0..<6) { i in
                Image(systemName: "heart.fill")
                    .font(.system(size: 18))
                    .foregroundColor(i.isMultiple(of: 2) ? Theme.like : Theme.violetSoft)
                    .offset(x: phase ? cos(Double(i) / 6 * 2 * .pi) * 70 : 0, y: phase ? sin(Double(i) / 6 * 2 * .pi) * 70 : 0)
                    .opacity(phase ? 0 : 1)
            }
            Image(systemName: "heart.fill")
                .font(.system(size: 96))
                .foregroundStyle(LinearGradient(colors: [Theme.like, Theme.violet], startPoint: .top, endPoint: .bottom))
                .glow(Theme.like, radius: 16)
                .scaleEffect(phase ? 1.1 : 0.3)
                .opacity(phase ? 0 : 1)
                .rotationEffect(.degrees(phase ? -8 : 8))
        }
        .onAppear { withAnimation(.easeOut(duration: 0.75)) { phase = true } }
    }
}
