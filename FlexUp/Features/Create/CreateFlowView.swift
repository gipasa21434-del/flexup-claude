import SwiftUI
import AVFoundation
import AVKit
import PhotosUI
import FlexCore

struct CreateFlowView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm: CreateViewModel
    @State private var confirmDiscard = false

    init(context: ComposeContext) {
        _vm = StateObject(wrappedValue: CreateViewModel(context: context))
    }

    var body: some View {
        NavigationStack {
            Group {
                switch vm.step {
                case .source: SourcePickerView(vm: vm)
                case .edit: EditorView(vm: vm)
                case .details: PublishDetailsView(vm: vm) { dismiss() }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if vm.step == .source { dismiss() } else if vm.isBusy { vm.cancelPublish() } else { confirmDiscard = true }
                    } label: { Image(systemName: "xmark").font(.headline) }
                    .accessibilityLabel(vm.isBusy ? "Отменить публикацию" : "Закрыть")
                    .accessibilityIdentifier("create.close")
                }
                if vm.step == .details && !vm.isBusy {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Назад") { vm.step = .edit }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .confirmationDialog("Отменить создание ролика?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Удалить черновик", role: .destructive) { vm.cleanup(); dismiss() }
            Button("Продолжить редактирование", role: .cancel) {}
        }
        .interactiveDismissDisabled(vm.isBusy)
        .onDisappear { if vm.phase != .done { vm.cleanup() } }
    }
}

// MARK: - Step 1: source

private struct SourcePickerView: View {
    @ObservedObject var vm: CreateViewModel
    @EnvironmentObject private var app: AppModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showCameraExplainer = false
    @State private var permissionDenied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let ch = vm.context.challenge, ch.isActive(at: Date()) || ch.startsAt == .distantPast {
                    HStack(spacing: 12) {
                        Text(ch.emoji).font(.largeTitle)
                        VStack(alignment: .leading) {
                            Text("Ты участвуешь").font(.caption.weight(.bold)).foregroundColor(Theme.textSecondary)
                            Text(ch.title).font(.headline)
                            Text("#\(ch.tag)").font(.subheadline).foregroundColor(Theme.accentText)
                        }
                        Spacer()
                    }
                    .card()
                }
                if let r = vm.context.replyTo {
                    DuoTargetCard(item: r)
                }

                VStack(spacing: 8) {
                    FlexLogo(size: 64)
                    Text("Новый ролик").font(.title.bold())
                    Text("До 60 секунд. Вертикальное видео 9:16 смотрится лучше всего.")
                        .font(.subheadline).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(.vertical, 8)

                PhotosPicker(selection: $pickerItem, matching: .videos, preferredItemEncoding: .compatible) {
                    sourceTile("photo.on.rectangle.angled", "Выбрать из медиатеки", "Системный выбор: приложение получает только выбранное видео")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("create.library")

                Button { showCameraExplainer = true } label: {
                    sourceTile("video.fill", "Снять на камеру", UIImagePickerController.isSourceTypeAvailable(.camera)
                               ? "Попросим доступ к камере и микрофону" : "Камера недоступна на этом устройстве")
                }
                .buttonStyle(.plain)
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                .accessibilityIdentifier("create.camera")

                if app.isDemo {
                    Button { Task { await vm.useDemoClip() } } label: {
                        sourceTile("sparkles.rectangle.stack", "Демо-клип FLEX UP", "Для проверки без своих видео (например, в симуляторе)")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("create.demoClip")
                }

                if vm.importing { ProgressView("Импортируем видео…").padding() }
                if let e = vm.importError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundColor(Theme.like)
                }
                if permissionDenied {
                    VStack(spacing: 8) {
                        Text("Доступ к камере выключен. Его можно включить в Настройках iOS → FLEX UP.")
                            .font(.footnote).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
                        Button("Открыть настройки") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Theme.background.ignoresSafeArea())
        .onChange(of: pickerItem) { item in Task { await vm.importPicked(item) } }
        .sheet(isPresented: $showCameraExplainer) {
            PermissionExplainer(
                symbol: "video.badge.waveform",
                title: "Камера и микрофон",
                text: "Нужны только для записи ролика прямо сейчас. Мы ничего не записываем в фоне и не используем микрофон без записи.",
                primary: "Продолжить"
            ) {
                showCameraExplainer = false
                Task {
                    let ok = await Permissions.requestCameraAndMic()
                    if ok { showCamera = true } else { permissionDenied = true }
                }
            }
            .presentationDetents([.medium])
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraRecorder { url in
                showCamera = false
                if let url { Task { await vm.use(url: url) } }
            }
            .ignoresSafeArea()
        }
    }

    private func sourceTile(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Theme.brandGradient).frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundColor(Theme.textPrimary)
                Text(subtitle).font(.caption).foregroundColor(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundColor(Theme.textSecondary)
        }
        .card()
    }
}

struct DuoTargetCard: View {
    let item: FeedItem
    var body: some View {
        HStack(spacing: 12) {
            VideoCover(item: item, showViews: false).frame(width: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Label("DUO REACT", systemImage: "person.2.wave.2.fill").font(.caption.weight(.heavy)).foregroundColor(Theme.accentText)
                Text("Реакция на @\(item.author.username)").font(.headline)
                Text(item.video.caption).font(.caption).foregroundColor(Theme.textSecondary).lineLimit(2)
            }
            Spacer()
        }
        .card()
    }
}

enum Permissions {
    static func requestCameraAndMic() async -> Bool {
        let video = await request(.video)
        guard video else { return false }
        _ = await request(.audio) // video without sound is still allowed
        return true
    }

    private static func request(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}

struct PermissionExplainer: View {
    let symbol: String
    let title: String
    let text: String
    let primary: String
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(Theme.brandGradient).padding(.top, 24)
            Text(title).font(.title2.bold())
            Text(text).font(.subheadline).foregroundColor(Theme.textSecondary).multilineTextAlignment(.center)
            Button(primary, action: action).buttonStyle(PrimaryButtonStyle())
            Button("Не сейчас") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(24)
    }
}

/// System camera UI in video mode (max 60 s). Returns the recorded file URL or nil on cancel.
struct CameraRecorder: UIViewControllerRepresentable {
    let completion: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.mediaTypes = [UTType.movie.identifier]
        p.cameraCaptureMode = .video
        p.videoMaximumDuration = VideoProcessing.maxDuration
        p.videoQuality = .typeHigh
        if UIImagePickerController.isCameraDeviceAvailable(.front) { p.cameraDevice = .front }
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (URL?) -> Void
        init(completion: @escaping (URL?) -> Void) { self.completion = completion }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let url = info[.mediaURL] as? URL else { completion(nil); return }
            let dest = MediaStore.exportsDirectory.appendingPathComponent("\(UUID().uuidString).mov")
            do { try FileManager.default.moveItem(at: url, to: dest); completion(dest) } catch { completion(url) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
    }
}

// MARK: - Step 2: trim + cover

private struct EditorView: View {
    @ObservedObject var vm: CreateViewModel
    @State private var player = AVPlayer()
    @State private var loopObserver: Any?

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black)
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .frame(maxHeight: 420)
            .accessibilityLabel("Предпросмотр ролика")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Фрагмент").font(.headline)
                    Spacer()
                    Text(String(format: "%.1f с из %.1f", vm.selectedDuration, vm.duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(vm.isTooLong ? Theme.like : Theme.textSecondary)
                }
                TrimSlider(start: $vm.trimStart, end: $vm.trimEnd, duration: vm.duration, frames: vm.filmstrip,
                           maxLength: VideoProcessing.maxDuration)
                    .frame(height: 56)
                if vm.isTooLong {
                    Text("Максимум \(Int(VideoProcessing.maxDuration)) секунд").font(.caption).foregroundColor(Theme.like)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Обложка").font(.headline)
                HStack(spacing: 12) {
                    Group {
                        if let img = vm.coverImage { Image(uiImage: img).resizable().scaledToFill() }
                        else { Rectangle().fill(Theme.elevated).shimmer() }
                    }
                    .frame(width: 54, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Slider(value: $vm.coverTime, in: vm.trimStart...max(vm.trimStart + 0.1, vm.trimEnd))
                        .tint(Theme.violet)
                        .accessibilityLabel("Кадр обложки")
                }
            }

            Spacer(minLength: 0)
            Button("Далее") {
                player.pause()
                vm.step = .details
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: !vm.isTooLong && vm.selectedDuration >= 1))
            .disabled(vm.isTooLong || vm.selectedDuration < 1)
            .accessibilityIdentifier("create.next")
        }
        .padding(16)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Редактор")
        .onAppear { setupPlayer() }
        .onDisappear {
            player.pause()
            if let o = loopObserver { player.removeTimeObserver(o); loopObserver = nil }
        }
        .onChange(of: vm.trimStart) { s in
            player.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            if vm.coverTime < s { vm.coverTime = s }
            vm.refreshCover()
        }
        .onChange(of: vm.trimEnd) { e in
            if vm.coverTime > e { vm.coverTime = e }
            vm.refreshCover()
        }
        .onChange(of: vm.coverTime) { _ in vm.refreshCover() }
    }

    private func setupPlayer() {
        guard let url = vm.sourceURL else { return }
        if (player.currentItem?.asset as? AVURLAsset)?.url != url {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
        }
        player.isMuted = false
        if loopObserver == nil {
            let p = player
            let model = vm
            loopObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak model, weak p] t in
                Task { @MainActor in
                    guard let model, let p else { return }
                    // Loop playback inside the selected fragment.
                    if t.seconds >= model.trimEnd || t.seconds < model.trimStart - 0.2 {
                        p.seek(to: CMTime(seconds: model.trimStart, preferredTimescale: 600))
                    }
                }
            }
        }
        player.seek(to: CMTime(seconds: vm.trimStart, preferredTimescale: 600))
        player.play()
    }
}

/// Two-handle range slider over a filmstrip.
struct TrimSlider: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let frames: [UIImage]
    let maxLength: Double
    private let handle: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - handle * 2
            let sx = duration > 0 ? CGFloat(start / duration) * w : 0
            let ex = duration > 0 ? CGFloat(end / duration) * w : w
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(uiImage: frames[i]).resizable().scaledToFill()
                            .frame(width: w / CGFloat(max(frames.count, 1)), height: geo.size.height).clipped()
                    }
                }
                .frame(width: w, height: geo.size.height)
                .background(Theme.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .offset(x: handle)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, sx)).offset(x: handle)
                }
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Color.black.opacity(0.55)).frame(width: max(0, w - ex)).offset(x: -handle)
                }
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.brandGradientH, lineWidth: 3)
                    .frame(width: max(handle, ex - sx + handle * 2), height: geo.size.height)
                    .offset(x: sx)
                    .allowsHitTesting(false)
                handleView.offset(x: sx)
                    .gesture(DragGesture().onChanged { v in
                        let t = Double((v.location.x - handle / 2) / w) * duration
                        start = min(max(0, t), end - 1)
                        if end - start > maxLength { end = start + maxLength }
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Начало фрагмента")
                    .accessibilityValue(String(format: "%.1f секунды", start))
                    .accessibilityAdjustableAction { dir in
                        start = dir == .increment ? min(end - 1, start + 0.5) : max(0, start - 0.5)
                    }
                handleView.offset(x: ex + handle)
                    .gesture(DragGesture().onChanged { v in
                        let t = Double((v.location.x - handle * 1.5) / w) * duration
                        end = max(min(duration, t), start + 1)
                        if end - start > maxLength { start = end - maxLength }
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Конец фрагмента")
                    .accessibilityValue(String(format: "%.1f секунды", end))
                    .accessibilityAdjustableAction { dir in
                        end = dir == .increment ? min(duration, end + 0.5) : max(start + 1, end - 0.5)
                    }
            }
        }
    }

    private var handleView: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.white)
            .frame(width: handle, height: 56)
            .overlay(Capsule().fill(Theme.violet).frame(width: 3, height: 22))
            .shadow(radius: 2)
            .contentShape(Rectangle().inset(by: -14))
    }
}

// MARK: - Step 3: details + publish

private struct PublishDetailsView: View {
    @ObservedObject var vm: CreateViewModel
    let onDone: () -> Void
    @EnvironmentObject private var app: AppModel
    @State private var trending: [String] = []
    @FocusState private var captionFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if let img = vm.coverImage { Image(uiImage: img).resizable().scaledToFill() } else { Theme.elevated }
                    }
                    .frame(width: 90, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Подпись, #хештеги…", text: $vm.caption, axis: .vertical)
                            .lineLimit(4...8)
                            .focused($captionFocused)
                            .accessibilityIdentifier("create.caption")
                        Text("\(vm.caption.count)/\(Validator.captionLimit)").font(.caption2)
                            .foregroundColor(vm.captionError == nil ? Theme.textSecondary : Theme.like)
                    }
                }
                .card()

                if !vm.tagSuggestions.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(vm.tagSuggestions, id: \.self) { t in Chip(title: "#\(t)") { vm.applySuggestion(t) } } }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Настроение (для MOOD FEED)").font(.headline)
                    FlowLayout(spacing: 8) {
                        ForEach(Mood.allCases) { m in
                            Chip(title: "\(m.emoji) \(m.title)", isSelected: vm.mood == m) { vm.mood = vm.mood == m ? nil : m }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Кто может смотреть").font(.headline)
                    Picker("Видимость", selection: $vm.visibility) {
                        ForEach(VideoVisibility.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                if let ch = vm.context.challenge {
                    Toggle(isOn: $vm.joinChallenge) {
                        VStack(alignment: .leading) {
                            Text("Участвовать в \(ch.title)").font(.headline)
                            Text("Добавим #\(ch.tag) и ролик попадёт в рейтинг").font(.caption).foregroundColor(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.violet)
                    .card()
                }

                if let r = vm.context.replyTo {
                    VStack(alignment: .leading, spacing: 8) {
                        DuoTargetCard(item: r)
                        Toggle(isOn: $vm.composeDuo) {
                            VStack(alignment: .leading) {
                                Text("Склеить с оригиналом").font(.headline)
                                Text("Сверху ролик @\(r.author.username), снизу твоя реакция. Иначе — ответ-ссылка на оригинал.")
                                    .font(.caption).foregroundColor(Theme.textSecondary)
                            }
                        }
                        .tint(Theme.violet)
                        .card()
                    }
                }

                publishSection
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Публикация")
        .onChange(of: vm.caption) { _ in vm.updateTagSuggestions(trending: trending) }
        .task {
            trending = ((try? await app.backend.trendingHashtags()) ?? []).map(\.tag)
            if vm.context.challenge == nil, let current = ChallengeEngine().current(from: (try? await app.backend.challenges()) ?? []) {
                // Offer today's challenge as a hashtag suggestion.
                trending.insert(current.tag, at: 0)
            }
        }
    }

    @ViewBuilder private var publishSection: some View {
        switch vm.phase {
        case .idle, .done:
            Button { captionFocused = false; vm.publish(app: app, onDone: onDone) } label: {
                Label("Опубликовать", systemImage: "paperplane.fill")
            }
            .buttonStyle(PrimaryButtonStyle(isEnabled: vm.canPublish))
            .disabled(!vm.canPublish)
            .accessibilityIdentifier("create.publish")
            if app.isDemo {
                Text("Демо-режим: ролик сохранится только на этом устройстве и будет виден в твоём профиле и ленте.")
                    .font(.caption).foregroundColor(Theme.textSecondary)
            }
        case let .processing(p):
            progressCard(title: vm.shouldComposeDuo ? "Склеиваем DUO REACT…" : "Готовим видео…", value: p)
        case let .uploading(p):
            progressCard(title: app.isDemo ? "Сохраняем (демо-загрузка)…" : "Загружаем на сервер…", value: p)
        case let .failed(message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundColor(Theme.like).font(.subheadline)
                Button("Попробовать снова") { vm.publish(app: app, onDone: onDone) }.buttonStyle(PrimaryButtonStyle())
            }
            .card()
            .accessibilityIdentifier("create.error")
        }
    }

    private func progressCard(title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(value * 100))%").font(.headline.monospacedDigit()).foregroundColor(Theme.accentText)
            }
            ProgressView(value: value).tint(Theme.violet)
            Button("Отменить", role: .cancel) { vm.cancelPublish() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("create.cancel")
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("create.progress")
    }
}
