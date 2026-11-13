import XCTest
@testable import FlexCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DemoBackendTests: XCTestCase {
    func makeBackend(storage: URL? = nil, media: URL? = nil) -> DemoBackend {
        DemoBackend(storageURL: storage, mediaDirectory: media, latency: 0, uploadChunkDelay: 0)
    }

    func signedIn() async throws -> DemoBackend {
        let b = makeBackend()
        _ = try await b.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword)
        return b
    }

    func testSignInWithDemoAccountAndWrongPassword() async throws {
        let b = makeBackend()
        do { _ = try await b.signIn(email: "demo@flexup.app", password: "wrong1234"); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .invalidCredentials) }
        let s = try await b.signIn(email: "DEMO@flexup.app ", password: DemoContent.demoPassword)
        XCTAssertEqual(s.userID, DemoContent.accounts[0].userID)
        let restored = await b.restoreSession()
        XCTAssertEqual(restored?.userID, s.userID)
    }

    func testSignUpValidatesAndRejectsDuplicates() async throws {
        let b = makeBackend()
        do { _ = try await b.signUp(email: "bad", password: "x", username: "ok_name"); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .validation(.invalidEmail)) }
        let s = try await b.signUp(email: "new@user.dev", password: "secret123", username: "new_user")
        let p = try await b.profile(id: s.userID)
        XCTAssertEqual(p.username, "new_user")
        do { _ = try await b.signUp(email: "new@user.dev", password: "secret123", username: "other"); XCTFail() }
        catch { if case .conflict = error as? BackendError {} else { XCTFail("\(error)") } }
    }

    func testGuestCanBrowseButNotInteract() async throws {
        let b = makeBackend()
        _ = try await b.signInAsGuest()
        let feed = try await b.feed(FeedQuery())
        XCTAssertFalse(feed.isEmpty)
        do { _ = try await b.setLike(true, videoID: feed[0].id); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .accountRequired) }
        do { _ = try await b.feed(FeedQuery(kind: .following)); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .accountRequired) }
    }

    func testLikeIsIdempotentAndReflectedInFeed() async throws {
        let b = try await signedIn()
        let item = try await b.feed(FeedQuery())[0]
        let liked = try await b.setLike(true, videoID: item.id)
        XCTAssertEqual(liked.likesCount, item.video.likesCount + 1)
        let again = try await b.setLike(true, videoID: item.id)
        XCTAssertEqual(again.likesCount, liked.likesCount)
        let fresh = try await b.feedItem(videoID: item.id)
        XCTAssertTrue(fresh.isLiked)
        let unliked = try await b.setLike(false, videoID: item.id)
        XCTAssertEqual(unliked.likesCount, item.video.likesCount)
        let likedList = try await b.likedVideos()
        XCTAssertTrue(likedList.isEmpty)
    }

    func testCommentsAddDeleteOwnOnlyAndRateLimit() async throws {
        let b = try await signedIn()
        let videoID = DemoContent.vid(4) // someone else's video
        let before = try await b.comments(videoID: videoID)
        let mine = try await b.addComment(videoID: videoID, text: "  Огонь!  ")
        XCTAssertEqual(mine.comment.text, "Огонь!")
        XCTAssertTrue(mine.isMine)
        let after = try await b.comments(videoID: videoID)
        XCTAssertEqual(after.count, before.count + 1)
        let foreign = before.first { !$0.isMine }!
        do { try await b.deleteComment(id: foreign.id); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .forbidden) }
        try await b.deleteComment(id: mine.id)
        let final = try await b.comments(videoID: videoID)
        XCTAssertEqual(final.count, before.count)
        do { _ = try await b.addComment(videoID: videoID, text: "   "); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .validation(.emptyText)) }
        var limited = false
        for i in 0..<15 {
            do { _ = try await b.addComment(videoID: videoID, text: "spam \(i)") }
            catch BackendError.rateLimited { limited = true; break }
        }
        XCTAssertTrue(limited, "comment spam must be rate limited")
    }

    func testFollowAffectsFollowingFeedAndCounts() async throws {
        let b = try await signedIn()
        let lola = DemoContent.uid(4)
        let before = try await b.profile(id: lola)
        let after = try await b.setFollow(true, userID: lola)
        XCTAssertEqual(after.followersCount, before.followersCount + 1)
        let isFollowing = try await b.isFollowing(userID: lola)
        XCTAssertTrue(isFollowing)
        let following = try await b.feed(FeedQuery(kind: .following))
        XCTAssertTrue(following.contains { $0.author.id == lola })
        let me = try await b.profile(id: DemoContent.accounts[0].userID)
        XCTAssertEqual(me.followingCount, 4)
    }

    func testBlockHidesContentEverywhere() async throws {
        let b = try await signedIn()
        let kot = DemoContent.uid(5)
        try await b.setBlocked(true, userID: kot)
        let feed = try await b.feed(FeedQuery())
        XCTAssertFalse(feed.contains { $0.author.id == kot })
        let search = try await b.search("кот", scope: .all, sort: .relevance, mood: nil)
        XCTAssertTrue(search.users.isEmpty)
        let blocked = try await b.blockedUsers()
        XCTAssertEqual(blocked.map(\.id), [kot])
        let stillFollowing = try await b.isFollowing(userID: kot)
        XCTAssertFalse(stillFollowing)
        try await b.setBlocked(false, userID: kot)
        let restored = try await b.feed(FeedQuery())
        XCTAssertTrue(restored.contains { $0.author.id == kot })
    }

    func testMoodFeedOnlyReturnsMatchingVideos() async throws {
        let b = try await signedIn()
        let calm = try await b.feed(FeedQuery(mood: .calm))
        XCTAssertFalse(calm.isEmpty)
        XCTAssertTrue(calm.allSatisfy { $0.video.matches(mood: .calm) })
    }

    func testPublishWithProgressDuoReactAndDelete() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("in.mp4")
        try Data(repeating: 7, count: 1024).write(to: src)
        let media = dir.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let b = makeBackend(media: media)
        _ = try await b.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword)
        let progress = ProgressBox()
        let original = DemoContent.vid(2)
        let v = try await b.publish(PublishRequest(fileURL: src, coverJPEG: Data([1, 2]), caption: "Реакция! #duo",
                                                   mood: .funny, visibility: .everyone, challengeTag: "FlexChallenge",
                                                   replyToVideoID: original, duration: 5)) { progress.append($0) }
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(progress.values, progress.values.sorted())
        XCTAssertEqual(v.hashtags, ["duo", "flexchallenge"])
        guard case let .local(name) = v.source else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(name).path))
        let reactions = try await b.reactions(to: original)
        XCTAssertEqual(reactions.map(\.id), [v.id])
        let challenges = try await b.challenges()
        let today = ChallengeEngine().current(from: challenges)!
        XCTAssertEqual(today.tag, "flexchallenge")
        let board = try await b.leaderboard(for: today)
        XCTAssertTrue(board.contains { $0.id == v.id })
        do { try await b.deleteVideo(id: DemoContent.vid(1)); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .forbidden) }
        try await b.deleteVideo(id: v.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent(name).path))
    }

    func testPublishCanBeCancelled() async throws {
        let dir = FileManager.default.temporaryDirectory
        let src = dir.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data([0]).write(to: src)
        let b = DemoBackend(latency: 0, uploadChunkDelay: 0.05)
        _ = try await b.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword)
        let task = Task {
            try await b.publish(PublishRequest(fileURL: src, coverJPEG: nil, caption: "x", mood: nil, visibility: .everyone,
                                               challengeTag: nil, replyToVideoID: nil, duration: 1)) { _ in }
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        task.cancel()
        let result = await task.result
        switch result {
        case .success: XCTFail("must be cancelled")
        case let .failure(e): XCTAssertTrue(e is CancellationError, "\(e)")
        }
        let mine = try await b.videos(by: DemoContent.accounts[0].userID)
        XCTAssertEqual(mine.count, 1, "only the seeded video, nothing half-published")
    }

    func testExtraLocalVideosAppearInFeedOnce() async throws {
        let extra = Video(id: UUID(), authorID: DemoContent.demoUserID(3), caption: "Локальный тест #localtest",
                          source: .bundled("local-test/test_1"), createdAt: Date(), isDemo: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let b1 = DemoBackend(storageURL: file, latency: 0, uploadChunkDelay: 0, extraVideos: [extra])
        _ = try await b1.signInAsGuest()
        let feed = try await b1.feed(FeedQuery(limit: 100))
        XCTAssertTrue(feed.contains { $0.id == extra.id })
        _ = try await b1.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword) // forces a persist
        _ = try await b1.setLike(true, videoID: extra.id)
        let b2 = DemoBackend(storageURL: file, latency: 0, uploadChunkDelay: 0, extraVideos: [extra])
        _ = try await b2.signInAsGuest()
        let again = try await b2.feed(FeedQuery(limit: 100))
        XCTAssertEqual(again.filter { $0.id == extra.id }.count, 1, "not duplicated after relaunch")
    }

    func testOfflineSimulationFailsGracefully() async throws {
        let b = try await signedIn()
        await b.setCondition(.offline)
        do { _ = try await b.feed(FeedQuery()); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .offline) }
        await b.setCondition(.normal)
        let feed = try await b.feed(FeedQuery())
        XCTAssertFalse(feed.isEmpty)
    }

    func testPersistenceRoundTripAndAccountDeletion() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let b1 = makeBackend(storage: file)
        let s = try await b1.signUp(email: "persist@test.dev", password: "secret123", username: "persist_me")
        _ = try await b1.setLike(true, videoID: DemoContent.vid(3))
        let b2 = makeBackend(storage: file)
        _ = try await b2.signIn(email: "persist@test.dev", password: "secret123")
        let liked = try await b2.likedVideos()
        XCTAssertEqual(liked.map(\.id), [DemoContent.vid(3)])
        try await b2.deleteAccount()
        let gone = await b2.restoreSession()
        XCTAssertNil(gone)
        do { _ = try await b2.profile(id: s.userID); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .notFound) }
    }

    func testNotificationsForLikesOnMyVideoAndMarkRead() async throws {
        let b = makeBackend()
        _ = try await b.signIn(email: "dasha@flexup.app", password: DemoContent.demoPassword)
        _ = try await b.setLike(true, videoID: DemoContent.vid(11)) // flexer's video
        await b.signOut()
        _ = try await b.signIn(email: "demo@flexup.app", password: DemoContent.demoPassword)
        let list = try await b.notifications()
        XCTAssertEqual(list.first?.kind, .like)
        XCTAssertEqual(list.first?.actorID, DemoContent.uid(2))
        try await b.markNotificationsRead()
        let read = try await b.notifications()
        XCTAssertTrue(read.allSatisfy(\.isRead))
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
    func append(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
}

// MARK: - Supabase client (HTTP layer is mocked, no network)

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open(); var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close(); req.httpBody = data
        }
        Self.lastRequests.append(req)
        let (status, data) = Self.handler?(req) ?? (500, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SupabaseBackendTests: XCTestCase {
    func makeBackend(store: SessionStore = InMemorySessionStore()) -> SupabaseBackend {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.lastRequests = []
        return SupabaseBackend(config: SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key"),
                               sessionStore: store, urlSession: URLSession(configuration: cfg))
    }

    func testConfigParsingRejectsPlaceholders() {
        XCTAssertNil(SupabaseConfig.from(values: [:]))
        XCTAssertNil(SupabaseConfig.from(values: ["SUPABASE_URL": "$(SUPABASE_URL)", "SUPABASE_ANON_KEY": "x"]))
        XCTAssertNil(SupabaseConfig.from(values: ["SUPABASE_URL": "http://insecure.dev", "SUPABASE_ANON_KEY": "x"]))
        XCTAssertNil(SupabaseConfig.from(values: ["SUPABASE_URL": "https://", "SUPABASE_ANON_KEY": "x"]), "empty host from xcconfig")
        XCTAssertNotNil(SupabaseConfig.from(values: ["SUPABASE_URL": "https://abc.supabase.co", "SUPABASE_ANON_KEY": "k"]))
    }

    func testSignInBuildsGoTrueRequestAndStoresSession() async throws {
        let uid = UUID()
        MockURLProtocol.handler = { _ in
            (200, #"{"access_token":"tok","refresh_token":"ref","expires_in":3600,"user":{"id":"\#(uid.uuidString)","email":"a@b.co"}}"#.data(using: .utf8)!)
        }
        let store = InMemorySessionStore()
        let b = makeBackend(store: store)
        let s = try await b.signIn(email: "a@b.co", password: "secret123")
        XCTAssertEqual(s.userID, uid)
        XCTAssertEqual(store.load()?.accessToken, "tok")
        let req = try XCTUnwrap(MockURLProtocol.lastRequests.last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/auth/v1/token")
        XCTAssertEqual(req.url?.query, "grant_type=password")
        XCTAssertEqual(req.value(forHTTPHeaderField: "apikey"), "anon-key")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: String]
        XCTAssertEqual(body?["email"], "a@b.co")
    }

    func testErrorMapping() {
        XCTAssertThrowsError(try SupabaseBackend.check(status: 400, data: #"{"error_description":"Invalid login credentials"}"#.data(using: .utf8)!)) {
            XCTAssertEqual($0 as? BackendError, .invalidCredentials)
        }
        XCTAssertThrowsError(try SupabaseBackend.check(status: 400, data: #"{"msg":"Email not confirmed"}"#.data(using: .utf8)!)) {
            XCTAssertEqual($0 as? BackendError, .emailConfirmationRequired)
        }
        XCTAssertThrowsError(try SupabaseBackend.check(status: 400, data: #"{"message":"rate_limited: comment"}"#.data(using: .utf8)!)) {
            XCTAssertEqual($0 as? BackendError, .rateLimited(retryAfter: 60))
        }
        XCTAssertThrowsError(try SupabaseBackend.check(status: 403, data: Data())) { XCTAssertEqual($0 as? BackendError, .forbidden) }
        XCTAssertNoThrow(try SupabaseBackend.check(status: 204, data: Data()))
    }

    func testSignUpWithoutSessionMeansConfirmationRequired() async {
        MockURLProtocol.handler = { _ in (200, #"{"id":"\#(UUID().uuidString)","email":"a@b.co"}"#.data(using: .utf8)!) }
        let b = makeBackend()
        do { _ = try await b.signUp(email: "a@b.co", password: "secret123", username: "abc_d"); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .emailConfirmationRequired) }
    }

    func testFeedRowDecodingFromPostgrestJSON() async throws {
        let vid = UUID(), aid = UUID()
        let json = """
        [{"id":"\(vid)","author_id":"\(aid)","caption":"Привет #тест","hashtags":["тест"],"music_title":null,
          "mood":"calm","duration":7.5,"video_url":"https://cdn/x.mp4","hls_url":"https://cdn/x.m3u8","thumbnail_url":null,
          "likes_count":3,"comments_count":1,"saves_count":0,"shares_count":0,"views_count":10,
          "created_at":"2026-11-13T10:00:00.123+00:00","visibility":"only_me","challenge_tag":null,"reply_to":null,
          "author":{"id":"\(aid)","username":"u","display_name":"U","bio":null,"avatar_url":null,"avatar_colors":null,
                    "followers_count":1,"following_count":2,"likes_count":3,"posts_count":4,"is_private":false,
                    "is_verified":true,"created_at":"2026-01-01 00:00:00+00"},
          "is_liked":true,"is_saved":false,"is_following":true}]
        """
        MockURLProtocol.handler = { _ in (200, json.data(using: .utf8)!) }
        let b = makeBackend()
        let items = try await b.feed(FeedQuery(mood: .calm))
        XCTAssertEqual(items.count, 1)
        let it = items[0]
        XCTAssertEqual(it.video.mood, .calm)
        XCTAssertEqual(it.video.visibility, .onlyMe)
        XCTAssertTrue(it.video.source.isHLS, "HLS URL is preferred when present")
        XCTAssertTrue(it.isLiked && it.isFollowingAuthor && it.author.isVerified)
        let req = try XCTUnwrap(MockURLProtocol.lastRequests.last)
        XCTAssertEqual(req.url?.path, "/rest/v1/rpc/feed_for_you")
        let body = try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["p_mood"] as? String, "calm")
    }

    func testGuestIsBlockedLocallyFromWrites() async throws {
        let b = makeBackend()
        _ = try await b.signInAsGuest()
        do { _ = try await b.addComment(videoID: UUID(), text: "hi"); XCTFail() }
        catch { XCTAssertEqual(error as? BackendError, .accountRequired) }
    }
}
