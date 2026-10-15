import Testing
@testable import NineBarCore

@Suite("NotificationPolicyTests")
struct NotificationPolicyTests {
    private let policy = NotificationPolicy()

    @Test("level eight is emitted only when a sequence crosses into eight or higher")
    func emitsLevelEightOnlyForSameSequenceCrossing() {
        #expect(policy.events(previous: top(7), current: top(8, phase: .candidate)).map(\.level) == [.level8])
        #expect(policy.events(previous: top(8, phase: .candidate), current: top(8, phase: .candidate)).isEmpty)
        #expect(policy.events(previous: top(8, phase: .candidate), current: top(9, phase: .candidate)).isEmpty)
    }

    @Test("level eight is emitted again when a new sequence reaches eight")
    func emitsLevelEightForNewSequence() {
        let previous = top(8, phase: .candidate)
        let current = top(8, phase: .candidate, sequenceStart: "2026-09-01T10:00:00+08:00")

        #expect(policy.events(previous: previous, current: current).map(\.level) == [.level8])
    }

    @Test("level nine is emitted only when count nine is confirmed")
    func emitsLevelNineOnlyAfterConfirmation() {
        #expect(policy.events(previous: top(8, phase: .candidate), current: top(9, phase: .candidate)).isEmpty)
        #expect(policy.events(previous: top(8, phase: .candidate), current: top(9, phase: .confirmed)).map(\.level) == [.level9])
        #expect(policy.events(previous: top(9, phase: .confirmed), current: top(9, phase: .confirmed)).isEmpty)
    }

    @Test("a skipped poll from seven to confirmed nine emits eight then nine")
    func emitsBothLevelsForSkippedPoll() {
        #expect(policy.events(previous: top(7), current: top(9, phase: .confirmed)).map(\.level) == [.level8, .level9])
    }

    @Test("event keys are stable sequence identities plus their level")
    func eventKeysUseSequenceIdentityAndLevel() {
        let event = NotificationEvent(level: .level8, sequence: top(8, phase: .candidate))

        #expect(event.key == "sh.600519|1|top|1788226200|8")
    }
}

@Suite("SystemNotificationServiceTests")
struct SystemNotificationServiceTests {
    @Test("denied authorization is cached and denied sends add no request")
    func cachesDeniedAuthorizationAndSkipsDelivery() async throws {
        let center = RecordingNotificationCenter(authorizationGranted: false)
        let service = SystemNotificationService(notificationCenter: center)

        #expect(try await service.requestAuthorization() == false)
        #expect(try await service.requestAuthorization() == false)
        try await service.send(NotificationEvent(level: .level8, sequence: top(8, phase: .candidate)), instrumentName: "样例股票")

        #expect(await center.authorizationRequestCount() == 1)
        #expect(await center.deliveredRequests().isEmpty)
    }

    @Test("granted level eight delivery has stable request content and no sound")
    func deliversLevelEightRequest() async throws {
        let center = RecordingNotificationCenter(authorizationGranted: true)
        let service = SystemNotificationService(notificationCenter: center)
        let event = NotificationEvent(level: .level8, sequence: top(8, phase: .candidate))

        try await service.send(event, instrumentName: "样例股票")

        let requests = await center.deliveredRequests()
        #expect(requests.count == 1)
        guard let request = requests.first else { return }
        #expect(request.identifier == event.key)
        #expect(request.title == "接近九转完成")
        #expect(request.body == "样例股票 · 1分钟 · 顶部序列 · 区间高点 10.40")
        #expect(request.sound == nil)
    }

    @Test("granted confirmed level nine delivery uses bottom low wording and default sound")
    func deliversConfirmedLevelNineRequest() async throws {
        let center = RecordingNotificationCenter(authorizationGranted: true)
        let service = SystemNotificationService(notificationCenter: center)
        let event = NotificationEvent(level: .level9, sequence: bottom(9, phase: .confirmed))

        try await service.send(event, instrumentName: "样例股票")

        let requests = await center.deliveredRequests()
        #expect(requests.count == 1)
        guard let request = requests.first else { return }
        #expect(request.identifier == event.key)
        #expect(request.title == "九转已确认")
        #expect(request.body == "样例股票 · 5分钟 · 底部序列 · 区间低点 8.12")
        #expect(request.sound == .default)
    }

    @Test("English notifications describe the same event")
    func deliversEnglishRequest() async throws {
        let center = RecordingNotificationCenter(authorizationGranted: true)
        let service = SystemNotificationService(notificationCenter: center)
        let event = NotificationEvent(level: .level9, sequence: bottom(9, phase: .confirmed))

        try await L10n.$scopedEnglish.withValue(true) {
            try await service.send(event, instrumentName: "Sample")
        }

        let request = try #require(await center.deliveredRequests().first)
        #expect(request.title == "Nine-count confirmed")
        #expect(request.body == "Sample · 5 min · bottom sequence · range low 8.12")
    }

    @Test("a level nine event can explicitly disable sound")
    func deliversSilentLevelNineRequest() async throws {
        let center = RecordingNotificationCenter(authorizationGranted: true)
        let service = SystemNotificationService(notificationCenter: center)
        let event = NotificationEvent(
            level: .level9,
            sequence: bottom(9, phase: .confirmed),
            playsSound: false
        )

        try await service.send(event, instrumentName: "样例股票")

        #expect(await center.deliveredRequests().first?.sound == nil)
    }
}

private func top(
    _ count: Int,
    phase: SequencePhase = .counting,
    sequenceStart: String = "2026-09-01T09:30:00+08:00"
) -> SequenceSnapshot {
    SequenceSnapshot(
        instrumentID: "sh.600519",
        timeframe: .oneMinute,
        direction: .top,
        count: count,
        phase: phase,
        sequenceStart: isoDate(sequenceStart),
        lastBarEnd: isoDate("2026-09-01T09:38:00+08:00"),
        extremePrice: 10.4,
        lastClose: 10.2
    )
}

private func bottom(_ count: Int, phase: SequencePhase) -> SequenceSnapshot {
    SequenceSnapshot(
        instrumentID: "sz.000001",
        timeframe: .fiveMinutes,
        direction: .bottom,
        count: count,
        phase: phase,
        sequenceStart: isoDate("2026-09-01T09:30:00+08:00"),
        lastBarEnd: isoDate("2026-09-01T10:10:00+08:00"),
        extremePrice: 8.12,
        lastClose: 8.3
    )
}

private actor RecordingNotificationCenter: NotificationCenterAdapting {
    private let authorizationGranted: Bool
    private var authorizationRequests = 0
    private var requests: [SystemNotificationRequest] = []

    init(authorizationGranted: Bool) {
        self.authorizationGranted = authorizationGranted
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        return authorizationGranted
    }

    func add(_ request: SystemNotificationRequest) async throws {
        requests.append(request)
    }

    func authorizationRequestCount() -> Int {
        authorizationRequests
    }

    func deliveredRequests() -> [SystemNotificationRequest] {
        requests
    }
}
