import SwiftUI
import FlexCore

// MARK: - FLEX CHALLENGE

struct ChallengesView: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var router: Router
    @State private var challenges: [Challenge] = []
    @State private var selected: Challenge?
    @State private var leaderboard: [LeaderboardEntry] = []
    @State private var state: LoadState = .idle
    @State private var boardState: LoadState = .idle
    private let engine = ChallengeEngine()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch state {
                case .idle, .loading:
                    SkeletonBlock(height: 200, corner: Theme.corner).padding(.horizontal, 16)
                case let .failed(m):
                    ErrorStateView(error: SimpleError(message: m)) { Task { await load() } }
                case .loaded:
                    if let ch = selected {
                        hero(ch)
                        board(ch)
                    } else {
                        EmptyStateView(symbol: "trophy", title: "Сегодня челленджа нет", message: "Загляни завтра — темы обновляются каждый день.")
                    }
                    others
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("FLEX CHALLENGE")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onChange(of: app.contentVersion) { _ in Task { await loadBoard() } }
    }

    private func hero(_ ch: Challenge) -> some View {
        let active = ch.isActive(at: Date())
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ch.emoji).font(.system(size: 52))
                Spacer()
                if active {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = Int(engine.timeRemaining(ch, now: ctx.date))
                        Label(String(format: "%02d:%02d:%02d", left / 3600, (left % 3600) / 60, left % 60), systemImage: "timer")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.25), in: Capsule())
                    }
                    .accessibilityLabel("До конца челленджа")
                } else {
                    Text(ch.startsAt > Date() ? "Скоро" : "Завершён").font(.subheadline.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6).background(Color.black.opacity(0.25), in: Capsule())
                }
            }
            Text(ch.title).font(.largeTitle.bold())
            Text("#\(ch.tag)").font(.title3.weight(.semibold)).foregroundColor(Theme.teal)
            Text(ch.details).font(.body).opacity(0.9)
            if active {
                Button { app.compose(ComposeContext(challenge: ch)) } label: {
                    Label("Участвовать", systemImage: "video.badge.plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("challenge.join")
            }
        }
        .foregroundColor(.white)
        .padding(20)
        .background(
            ZStack {
                LinearGradient(colors: [Theme.violet, Color(hex: 0x2A0B5C)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Theme.teal.opacity(0.45), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 260)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        )
        .glow(Theme.violet, radius: 14)
        .padding(.horizontal, 16)
    }

    @ViewBuilder private func board(_ ch: Challenge) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Рейтинг участников")
            Text("Очки = лайки + 2×комментарии + 3×репосты + сохранения. Учитываются публичные ролики, снятые во время челленджа.")
                .font(.caption).foregroundColor(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        switch boardState {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity).padding(30)
        case let .failed(m):
            ErrorStateView(error: SimpleError(message: m)) { Task { await loadBoard() } }
        case .loaded:
            if leaderboard.isEmpty {
                EmptyStateView(symbol: "flag.checkered", title: "Пока никто не участвовал",
                               message: "Сними ролик с #\(ch.tag) — и ты сразу первый.")
            } else {
                VStack(spacing: 8) {
                    ForEach(leaderboard.prefix(3)) { e in
                        Button { router.go(.player(PlayerListToken(items: leaderboard.map(\.item), startAt: e.id))) } label: {
                            HStack(spacing: 12) {
                                Text(e.rank == 1 ? "🥇" : e.rank == 2 ? "🥈" : "🥉").font(.title)
                                AvatarView(user: e.item.author, size: 40)
                                VStack(alignment: .leading) {
                                    Text("@\(e.item.author.username)").font(.headline).foregroundColor(Theme.textPrimary)
                                    Text(e.item.video.caption).font(.caption).foregroundColor(Theme.textSecondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(CountFormatter.short(e.score))").font(.headline.monospacedDigit()).foregroundColor(Theme.accentText)
                            }
                            .padding(12)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Место \(e.rank): @\(e.item.author.username), \(e.score) очков")
                    }
                }
                .padding(.horizontal, 16)
                VideoGrid(items: leaderboard.map(\.item), rankBadges: Dictionary(uniqueKeysWithValues: leaderboard.map { ($0.id, $0.rank) }))
            }
        }
    }

    @ViewBuilder private var others: some View {
        let upcoming = engine.upcoming(from: challenges)
        let past = engine.past(from: challenges)
        if !upcoming.isEmpty || !past.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Другие дни")
                ForEach(upcoming + past) { c in
                    Button { selected = c; Task { await loadBoard() } } label: {
                        HStack(spacing: 12) {
                            Text(c.emoji).font(.title2)
                            VStack(alignment: .leading) {
                                Text(c.title).font(.headline).foregroundColor(Theme.textPrimary)
                                Text("#\(c.tag) · \(c.startsAt > Date() ? "скоро" : "завершён")").font(.caption).foregroundColor(Theme.textSecondary)
                            }
                            Spacer()
                            Text(c.startsAt.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundColor(Theme.textSecondary)
                        }
                        .padding(12)
                        .background(selected?.id == c.id ? Theme.elevated : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func load() async {
        if challenges.isEmpty { state = .loading }
        do {
            challenges = try await app.backend.challenges()
            if selected == nil { selected = engine.current(from: challenges) }
            state = .loaded
            await loadBoard()
        } catch { state = .failed(error.localizedDescription) }
    }

    private func loadBoard() async {
        guard let ch = selected else { return }
        boardState = .loading
        do {
            leaderboard = try await app.backend.leaderboard(for: ch)
            boardState = .loaded
        } catch { boardState = .failed(error.localizedDescription) }
    }
}

// MARK: - MOOD FEED

struct MoodPickerSheet: View {
    let selected: Mood?
    let onPick: (Mood?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("MOOD FEED").font(.caption.weight(.heavy)).foregroundColor(Theme.accentText)
                Text("Какое у тебя настроение?").font(.title2.bold())
                Text("Лента покажет ролики, которые автор отметил этим настроением или которые содержат связанные хештеги. Это простые правила, а не нейросеть.")
                    .font(.footnote).foregroundColor(Theme.textSecondary)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Mood.allCases) { m in
                    Button { onPick(m); Haptics.medium(); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(m.emoji).font(.system(size: 34))
                            Text(m.title).font(.headline).foregroundColor(selected == m ? .white : Theme.textPrimary)
                            Text(m.relatedTags.sorted().prefix(3).map { "#\($0)" }.joined(separator: " "))
                                .font(.caption2).foregroundColor(selected == m ? .white.opacity(0.8) : Theme.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(selected == m ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.surface),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected == m ? .isSelected : [])
                    .accessibilityIdentifier("mood.\(m.rawValue)")
                }
            }
            if selected != nil {
                Button("Показать всё без фильтра") { onPick(nil); dismiss() }.buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(20)
        .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - FLEX STREAK

struct StreakView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Toggle(isOn: $app.settings.streakEnabled) {
                    VStack(alignment: .leading) {
                        Text("FLEX STREAK").font(.headline)
                        Text("Необязательно. Без пуш-уведомлений и штрафов — просто для удовольствия.").font(.caption).foregroundColor(Theme.textSecondary)
                    }
                }
                .tint(Theme.violet)
                .card()
                .accessibilityIdentifier("streak.toggle")

                if app.settings.streakEnabled {
                    header
                    goals
                    calendar
                    achievements
                    Text("Один пропущенный день в неделю прощается автоматически. Данные хранятся только на этом устройстве.")
                        .font(.caption).foregroundColor(Theme.textSecondary)
                } else {
                    EmptyStateView(symbol: "flame", title: "Стрик выключен", message: "Включи, если хочешь отслеживать ежедневные цели.")
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("FLEX STREAK")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Theme.warning, Theme.like], startPoint: .top, endPoint: .bottom))
                    .frame(width: 88, height: 88).glow(Theme.like, radius: 14)
                Image(systemName: "flame.fill").font(.system(size: 42)).foregroundColor(.white)
            }
            VStack(alignment: .leading) {
                Text("\(app.currentStreak)").font(.system(size: 48, weight: .black, design: .rounded))
                Text(daysWord(app.currentStreak) + " подряд").font(.headline).foregroundColor(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Стрик: \(app.currentStreak) \(daysWord(app.currentStreak)) подряд")
    }

    private var goals: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Цели на сегодня (хватит одной)").font(.headline)
            ForEach(StreakState.Goal.allCases) { g in
                let p = app.streakTracker.progress(g, in: app.streak)
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Theme.elevated, lineWidth: 5)
                        Circle().trim(from: 0, to: CGFloat(p) / CGFloat(g.target))
                            .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: g.symbol).foregroundColor(p >= g.target ? Theme.teal : Theme.textSecondary)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading) {
                        Text(g.title).font(.subheadline.weight(.semibold))
                        Text("\(p) из \(g.target)").font(.caption).foregroundColor(Theme.textSecondary)
                    }
                    Spacer()
                    if p >= g.target { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.teal) }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }

    private var calendar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Последние 14 дней").font(.headline)
            let history = app.streakTracker.history(app.streak, days: 14)
            HStack(spacing: 6) {
                ForEach(history.indices, id: \.self) { i in
                    let d = history[i]
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(d.complete ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.elevated))
                            .frame(height: 28)
                        Text(d.date.formatted(.dateTime.day())).font(.system(size: 9)).foregroundColor(Theme.textSecondary)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("\(d.date.formatted(date: .abbreviated, time: .omitted)): \(d.complete ? "выполнено" : "нет")")
                }
            }
        }
        .card()
    }

    private var achievements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Достижения").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(StreakState.Achievement.allCases) { a in
                    let unlocked = app.streak.unlocked[a] != nil
                    VStack(spacing: 6) {
                        Image(systemName: a.symbol).font(.title)
                            .foregroundStyle(unlocked ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.textSecondary.opacity(0.5)))
                        Text(a.title).font(.subheadline.weight(.bold)).foregroundColor(unlocked ? Theme.textPrimary : Theme.textSecondary)
                        Text(a.details).font(.caption2).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110)
                    .padding(8)
                    .background(Theme.elevated.opacity(unlocked ? 1 : 0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(unlocked ? "получено" : "не получено")
                }
            }
        }
        .card()
    }

    private func daysWord(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "день" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "дня" }
        return "дней"
    }
}

// MARK: - DUO REACT intro

struct DuoReactIntroSheet: View {
    let item: FeedItem
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "person.2.wave.2.fill").font(.title).foregroundStyle(Theme.brandGradient)
                    Text("DUO REACT").font(.title.bold())
                }
                DuoTargetCard(item: item)
                VStack(alignment: .leading, spacing: 8) {
                    bullet("1", "Сними или выбери видео со своей реакцией")
                    bullet("2", "Обрежь до нужного момента и выбери обложку")
                    bullet("3", "Мы склеим ролик: сверху оригинал, снизу ты — прямо на телефоне")
                }
                Text("Склейка выполняется на устройстве (AVFoundation). Длина ролика — по более короткому из двух видео. Можно отключить склейку и опубликовать обычный ответ со ссылкой на оригинал.")
                    .font(.caption).foregroundColor(Theme.textSecondary)
                Button {
                    dismiss()
                    // Let the sheet finish dismissing before presenting the full-screen creator.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { app.compose(ComposeContext(replyTo: item)) }
                } label: { Label("Записать реакцию", systemImage: "video.fill") }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("duo.start")
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func bullet(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(n).font(.subheadline.weight(.black)).foregroundColor(.white)
                .frame(width: 26, height: 26).background(Theme.brandGradient, in: Circle())
            Text(text).font(.subheadline)
        }
    }
}
