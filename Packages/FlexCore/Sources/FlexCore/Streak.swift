import Foundation

/// FLEX STREAK — opt-in daily goals and achievements.
/// No push notifications, no penalties, no "you'll lose everything" pressure: a missed day only resets the counter,
/// and one "freeze" per week protects the streak automatically.
public struct StreakState: Codable, Hashable, Sendable {
    public struct DayProgress: Codable, Hashable, Sendable {
        public var watched = 0
        public var interactions = 0
        public var published = 0
        public init(watched: Int = 0, interactions: Int = 0, published: Int = 0) {
            self.watched = watched; self.interactions = interactions; self.published = published
        }
    }

    public enum Goal: String, CaseIterable, Codable, Sendable, Identifiable {
        case watch, interact, publish
        public var id: String { rawValue }
        public var target: Int {
            switch self { case .watch: return 5; case .interact: return 3; case .publish: return 1 }
        }
        public var title: String {
            switch self {
            case .watch: return "Посмотри 5 роликов"
            case .interact: return "3 лайка, коммента или сохранения"
            case .publish: return "Опубликуй ролик"
            }
        }
        public var symbol: String {
            switch self { case .watch: return "play.circle.fill"; case .interact: return "heart.circle.fill"; case .publish: return "plus.circle.fill" }
        }
    }

    public enum Achievement: String, CaseIterable, Codable, Sendable, Identifiable {
        case firstVideo, firstChallenge, streak3, streak7, streak30, likes50, explorer
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .firstVideo: return "Первый флекс"
            case .firstChallenge: return "В челлендже"
            case .streak3: return "3 дня подряд"
            case .streak7: return "Неделя огня"
            case .streak30: return "Месяц в ритме"
            case .likes50: return "Щедрое сердце"
            case .explorer: return "Исследователь"
            }
        }
        public var details: String {
            switch self {
            case .firstVideo: return "Опубликуй первый ролик"
            case .firstChallenge: return "Поучаствуй в FLEX CHALLENGE"
            case .streak3: return "Стрик 3 дня"
            case .streak7: return "Стрик 7 дней"
            case .streak30: return "Стрик 30 дней"
            case .likes50: return "Поставь 50 лайков"
            case .explorer: return "Посмотри ролики всех 5 настроений"
            }
        }
        public var symbol: String {
            switch self {
            case .firstVideo: return "sparkles"
            case .firstChallenge: return "trophy.fill"
            case .streak3: return "flame"
            case .streak7: return "flame.fill"
            case .streak30: return "crown.fill"
            case .likes50: return "heart.fill"
            case .explorer: return "safari.fill"
            }
        }
    }

    public var isEnabled: Bool
    /// Keyed by "yyyy-MM-dd" in the user's calendar.
    public var days: [String: DayProgress]
    public var totalLikesGiven: Int
    public var moodsWatched: Set<Mood>
    public var unlocked: [Achievement: Date]
    public var freezesUsed: [String]

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled; days = [:]; totalLikesGiven = 0; moodsWatched = []
        unlocked = [:]; freezesUsed = []
    }
}

public struct StreakTracker: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = .current) { self.calendar = calendar }

    public func key(for date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public enum Event: Sendable { case watched(Mood?), liked, interacted, published(challenge: Bool) }

    /// Applies an event and returns achievements unlocked by it.
    @discardableResult
    public func record(_ event: Event, in state: inout StreakState, at date: Date = Date()) -> [StreakState.Achievement] {
        guard state.isEnabled else { return [] }
        let k = key(for: date)
        var day = state.days[k] ?? .init()
        var newly: [StreakState.Achievement] = []
        switch event {
        case let .watched(mood):
            day.watched += 1
            if let mood { state.moodsWatched.insert(mood) }
        case .liked:
            day.interactions += 1
            state.totalLikesGiven += 1
        case .interacted:
            day.interactions += 1
        case let .published(challenge):
            day.published += 1
            newly += unlock(.firstVideo, in: &state, date: date)
            if challenge { newly += unlock(.firstChallenge, in: &state, date: date) }
        }
        state.days[k] = day
        if state.totalLikesGiven >= 50 { newly += unlock(.likes50, in: &state, date: date) }
        if state.moodsWatched.count == Mood.allCases.count { newly += unlock(.explorer, in: &state, date: date) }
        let streak = currentStreak(state, now: date)
        if streak >= 3 { newly += unlock(.streak3, in: &state, date: date) }
        if streak >= 7 { newly += unlock(.streak7, in: &state, date: date) }
        if streak >= 30 { newly += unlock(.streak30, in: &state, date: date) }
        return newly
    }

    private func unlock(_ a: StreakState.Achievement, in state: inout StreakState, date: Date) -> [StreakState.Achievement] {
        guard state.unlocked[a] == nil else { return [] }
        state.unlocked[a] = date
        return [a]
    }

    public func progress(_ goal: StreakState.Goal, in state: StreakState, on date: Date = Date()) -> Int {
        let day = state.days[key(for: date)] ?? .init()
        switch goal {
        case .watch: return min(day.watched, goal.target)
        case .interact: return min(day.interactions, goal.target)
        case .publish: return min(day.published, goal.target)
        }
    }

    /// A day counts when at least one goal is fully completed.
    public func isDayComplete(_ state: StreakState, on date: Date) -> Bool {
        StreakState.Goal.allCases.contains { progress($0, in: state, on: date) >= $0.target }
    }

    /// Consecutive complete days ending today (or yesterday if today is not complete yet).
    /// One missed day per ISO week is forgiven ("freeze") if the days around it are complete.
    public func currentStreak(_ state: StreakState, now: Date = Date()) -> Int {
        var date = calendar.startOfDay(for: now)
        if !isDayComplete(state, on: date) {
            guard let y = calendar.date(byAdding: .day, value: -1, to: date) else { return 0 }
            date = y
        }
        var count = 0
        var freezeWeeks = Set<Int>()
        for _ in 0..<400 {
            if isDayComplete(state, on: date) {
                count += 1
            } else {
                let week = calendar.component(.weekOfYear, from: date)
                guard let prev = calendar.date(byAdding: .day, value: -1, to: date),
                      count > 0, !freezeWeeks.contains(week), isDayComplete(state, on: prev) else { break }
                freezeWeeks.insert(week)
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        }
        return count
    }

    /// Completion flags for the last `count` days, oldest first (for the calendar strip).
    public func history(_ state: StreakState, days count: Int, now: Date = Date()) -> [(date: Date, complete: Bool)] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let d = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (d, isDayComplete(state, on: d))
        }
    }
}
