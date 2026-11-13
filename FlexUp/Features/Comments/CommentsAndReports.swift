import SwiftUI
import FlexCore

struct CommentsSheet: View {
    let item: FeedItem
    let onCountChange: (Int) -> Void
    @EnvironmentObject private var app: AppModel
    @State private var comments: [CommentItem] = []
    @State private var state: LoadState = .idle
    @State private var text = ""
    @State private var sending = false
    @State private var reportTarget: CommentItem?
    @FocusState private var focused: Bool

    private var isMyVideo: Bool { app.session?.userID == item.author.id && !app.isGuest }

    var body: some View {
        VStack(spacing: 0) {
            Text(comments.isEmpty && state == .loaded ? "Комментарии" : "Комментарии · \(CountFormatter.short(max(comments.count, 0)))")
                .font(.headline).padding(.top, 16).padding(.bottom, 8)
            Divider()
            Group {
                switch state {
                case .idle, .loading:
                    VStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            HStack(spacing: 10) {
                                Circle().fill(Theme.elevated).frame(width: 36, height: 36)
                                VStack(alignment: .leading, spacing: 6) { SkeletonBlock(width: 100, height: 10); SkeletonBlock(height: 12) }
                            }
                        }
                    }
                    .padding(16)
                    Spacer()
                case let .failed(m):
                    ErrorStateView(error: SimpleError(message: m)) { Task { await load() } }
                case .loaded:
                    if comments.isEmpty {
                        EmptyStateView(symbol: "bubble.left.and.bubble.right", title: "Пока тихо", message: "Напиши первый комментарий.")
                        Spacer()
                    } else {
                        List {
                            ForEach(comments) { c in
                                CommentRow(item: c)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        if c.isMine || isMyVideo {
                                            Button(role: .destructive) { Task { await delete(c) } } label: { Label("Удалить", systemImage: "trash") }
                                        }
                                        if !c.isMine {
                                            Button { app.requireAccount { reportTarget = c } } label: { Label("Жалоба", systemImage: "flag") }.tint(.orange)
                                        }
                                    }
                                    .contextMenu {
                                        Button { UIPasteboard.general.string = c.comment.text } label: { Label("Копировать", systemImage: "doc.on.doc") }
                                        if c.isMine || isMyVideo {
                                            Button(role: .destructive) { Task { await delete(c) } } label: { Label("Удалить", systemImage: "trash") }
                                        }
                                        if !c.isMine {
                                            Button { app.requireAccount { reportTarget = c } } label: { Label("Пожаловаться", systemImage: "flag") }
                                        }
                                    }
                            }
                        }
                        .listStyle(.plain)
                        .accessibilityIdentifier("comments.list")
                    }
                }
            }
            .frame(maxHeight: .infinity)
            composer
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await load() }
        .sheet(item: $reportTarget) { c in
            ReportSheet(target: .comment(c.id), title: "Пожаловаться на комментарий") {
                comments.removeAll { $0.id == c.id }
            }
            .environmentObject(app)
        }
    }

    private var composer: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 10) {
                if let me = app.currentUser { AvatarView(user: me, size: 32) }
                TextField(app.isGuest ? "Войди, чтобы комментировать" : "Добавь комментарий…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($focused)
                    .disabled(app.isGuest)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("comments.field")
                    .onTapGesture { if app.isGuest { app.showAuthPrompt = true } }
                Button { Task { await send() } } label: {
                    if sending { ProgressView() } else {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                            .foregroundStyle(canSend ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.gray.opacity(0.4)))
                    }
                }
                .disabled(!canSend || sending)
                .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
                .accessibilityLabel("Отправить комментарий")
                .accessibilityIdentifier("comments.send")
            }
            .padding(.horizontal, 12)
            if text.count > Validator.commentLimit - 50 {
                Text("\(text.count)/\(Validator.commentLimit)").font(.caption2)
                    .foregroundColor(text.count > Validator.commentLimit ? Theme.like : Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 8)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
    }

    private var canSend: Bool { Validator.text(text, limit: Validator.commentLimit) == nil }

    private func load() async {
        if comments.isEmpty { state = .loading }
        do {
            comments = try await app.backend.comments(videoID: item.id)
            state = .loaded
        } catch { state = .failed(error.localizedDescription) }
    }

    private func send() async {
        guard canSend else { return }
        sending = true
        defer { sending = false }
        do {
            let c = try await app.backend.addComment(videoID: item.id, text: text)
            withAnimation { comments.insert(c, at: 0) }
            text = ""
            focused = false
            onCountChange(1)
            Haptics.success()
        } catch {
            app.show(error)
        }
    }

    private func delete(_ c: CommentItem) async {
        let backup = comments
        withAnimation { comments.removeAll { $0.id == c.id } }
        do {
            try await app.backend.deleteComment(id: c.id)
            onCountChange(-1)
        } catch {
            comments = backup
            app.show(error)
        }
    }
}

private struct CommentRow: View {
    let item: CommentItem
    @State private var liked = false
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(user: item.author, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.author.displayName).font(.subheadline.weight(.semibold)).foregroundColor(Theme.textSecondary)
                    if item.author.isVerified { VerifiedBadge() }
                    if item.isMine { Text("· ты").font(.caption).foregroundColor(Theme.accentText) }
                    Text("· \(RelativeTime.short(from: item.comment.createdAt))").font(.caption).foregroundColor(Theme.textSecondary)
                }
                Text(item.comment.text).font(.body).foregroundColor(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { liked.toggle(); Haptics.tap() } label: {
                VStack(spacing: 2) {
                    Image(systemName: liked ? "heart.fill" : "heart").foregroundColor(liked ? Theme.like : Theme.textSecondary)
                    Text(CountFormatter.short(item.comment.likesCount + (liked ? 1 : 0))).font(.caption2).foregroundColor(Theme.textSecondary)
                }
                .frame(minWidth: Theme.minTap, minHeight: Theme.minTap)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liked ? "Убрать отметку" : "Отметить комментарий")
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reports

struct ReportSheet: View {
    let target: ReportTarget
    let title: String
    var onSent: () -> Void = {}
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var sending = false
    @State private var alsoBlock = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(ReportReason.allCases) { r in
                        Button { reason = r } label: {
                            HStack {
                                Text(r.title).foregroundColor(Theme.textPrimary)
                                Spacer()
                                if reason == r { Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.violet) }
                            }
                        }
                        .accessibilityAddTraits(reason == r ? .isSelected : [])
                    }
                } header: { Text("Причина") } footer: {
                    Text("Жалобы анонимны для автора. Модераторы проверяют их вручную; ролик скрывается из твоей ленты сразу.")
                }
                Section("Подробности (необязательно)") {
                    TextField("Что не так?", text: $details, axis: .vertical).lineLimit(2...5)
                }
                if canBlockAuthor {
                    Section { Toggle("Также заблокировать автора", isOn: $alsoBlock) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Отправить") { Task { await send() } }.disabled(reason == nil).fontWeight(.bold)
                            .accessibilityIdentifier("report.send")
                    }
                }
            }
        }
    }

    private var canBlockAuthor: Bool {
        if case .video = target { return true }
        return false
    }

    private func send() async {
        guard let reason else { return }
        sending = true
        defer { sending = false }
        do {
            try await app.backend.report(Report(target: target, reason: reason, details: details))
            if alsoBlock, case let .video(id) = target, let it = try? await app.backend.feedItem(videoID: id) {
                try? await app.backend.setBlocked(true, userID: it.author.id)
                app.contentVersion += 1
            }
            app.show("Спасибо! Жалоба отправлена\(app.isDemo ? " (демо: сохранена локально)" : "")", style: .success)
            onSent()
            dismiss()
        } catch { app.show(error) }
    }
}
