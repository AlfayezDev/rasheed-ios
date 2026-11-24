import Combine
import Foundation
import Network
import RasheedCore
import UIKit

@MainActor
public final class RasheedClient: ObservableObject {
    /// An outage's status line, worded as on the web.
    enum ConnectionNotice: Equatable {
        case connecting, reconnecting, unavailable

        func text(arabic: Bool) -> String {
            switch self {
            case .connecting: arabic ? "جارٍ الاتصال بالدعم…" : "Connecting to support…"
            case .reconnecting: arabic ? "جارٍ إعادة الاتصال…" : "Reconnecting…"
            case .unavailable: arabic ? "الدعم غير متاح الآن." : "Support is unavailable right now."
            }
        }
    }

    /// Host token acquisition must be canceled when SDK commands retire consent.
    public static let pushTokenAcquisitionInvalidated = Notification.Name("ai.rasheed.support.push-token-acquisition-invalidated")
    public let workspaceId: String
    public let platformURL: URL
    @Published public private(set) var snapshot: RasheedSnapshot
    @Published public private(set) var credentialGeneration: UInt64
    @Published public private(set) var inbox: InboxSnapshot
    @Published public private(set) var push: PushSnapshot
    @Published public private(set) var localFileError: RasheedClientError?
    /// The host's mute for every sound the SDK plays: the reply chime and the in-app notification sound. The
    /// customer's own Sound setting is kept apart, per workspace on this device.
    @Published public var replySound = true
    /// The Sound setting in support settings, on by default.
    @Published var soundOn: Bool {
        didSet { UserDefaults.standard.set(!soundOn, forKey: Self.soundOffKey(workspaceId)) }
    }
    /// Open support screens. While one is, replies sound through its chime rather than the notification's sound.
    var supportScreens = 0
    var playsSound: Bool { replySound && soundOn }
    /// The connection is being opened, or restored after it dropped.
    @Published private(set) var connectionDown = false
    /// As on the web, an outage shows nothing for 3 s, then one quiet status; from 30 s support reads as unavailable.
    @Published private(set) var connectionNotice: ConnectionNotice?
    public var currentCredentialGeneration: UInt64 { core.snapshot().credentialGeneration }

    var failedAction: RasheedCore.FailedAction? { snapshot.failedAction }
    var uncertainIdentity: RasheedClientError? { snapshot.uncertainIdentity }

    private let core: RasheedCore.Client
    private var listenerID: UInt64?
    private var inboxListenerID: UInt64?
    private var pushListenerID: UInt64?
    var notificationDedupe = RasheedNotificationDedupe()
    var foregroundNotifications: [String: PushScope] = [:]
    var conversationPresentations: [ObjectIdentifier: ConversationPresentation] = [:]
    private var fileCleanupListener: AnyCancellable?
    private var appListeners: Set<AnyCancellable> = []
    private var outageClock: Task<Void, Never>?
    private var reconnection: Task<Void, Never>?
    private var reconnectAttempts = 0
    private var attemptStarted = ContinuousClock.now
    private var connectedOnce = false
    private let pathMonitor = NWPathMonitor()
    private var heardPath: (satisfied: Bool, interface: String?)?
    private var fileScope: InboxFilePool.Scope {
        InboxFilePool.Scope(platform: platformURL.absoluteString, workspace: workspaceId)
    }
    var composerDrafts: [String: RasheedComposerDraft] = [:]
    var composerDraftTarget: InboxTarget?
    let assigneeAvatars = AssigneeAvatarCache()

    public init(workspaceId: String, platformURL: URL) throws {
        let normalized = try Self.normalizedPlatformURL(platformURL)
        let core = try RasheedCore.Client(platformUrl: normalized.absoluteString, workspaceId: workspaceId,
                                          store: CustomerStorage(platformURL: normalized, workspaceId: workspaceId))
        self.workspaceId = workspaceId
        self.platformURL = normalized
        self.core = core
        let initial = core.snapshot()
        snapshot = initial
        credentialGeneration = initial.credentialGeneration
        inbox = core.inboxSnapshot()
        push = core.pushSnapshot()
        localFileError = InboxFilePool.shared.cleanupError
        soundOn = !UserDefaults.standard.bool(forKey: Self.soundOffKey(workspaceId))
        fileCleanupListener = NotificationCenter.default.publisher(for: InboxFilePool.cleanupChanged).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.localFileError = InboxFilePool.shared.cleanupError }
        }
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.outageClock?.cancel() }
        }.store(in: &appListeners)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification).sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeOutage() }
        }.store(in: &appListeners)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let current = (satisfied: path.status == .satisfied, interface: path.availableInterfaces.first?.name)
            Task { @MainActor [weak self] in self?.pathChanged(current) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "ai.rasheed.support.path"))

        let listener = ClientSnapshotListener { [weak self] snapshot in self?.apply(snapshot) }
        listenerID = core.subscribe(listener: listener)
        inboxListenerID = core.subscribeInbox(listener: CoreInboxListener { [weak self] snapshot in
            self?.applyInbox(snapshot)
        })
        pushListenerID = core.subscribePush(listener: CorePushListener { [weak self] snapshot in
            self?.applyPush(snapshot)
        })
        apply(core.snapshot())
        applyInbox(core.inboxSnapshot())
        applyPush(core.pushSnapshot())
    }

    private static func soundOffKey(_ workspaceId: String) -> String { "ai.rasheed.support.sound-off.\(workspaceId)" }

    deinit {
        pathMonitor.cancel()
        let avatars = assigneeAvatars
        Task { @MainActor in avatars.retireAll() }
        if let listenerID { core.unsubscribe(id: listenerID) }
        if let inboxListenerID { core.unsubscribeInbox(id: inboxListenerID) }
        if let pushListenerID { core.unsubscribePush(id: pushListenerID) }
        core.dispose()
    }

    public func connect() async throws {
        try await perform { try await core.connect() }
    }

    public func join(language: Language) async throws {
        try await perform { try await core.join(language: language) }
    }

    public func identify(_ identity: SignedIdentity) async throws {
        try await perform { try await core.identify(identity: identity.coreValue) }
    }

    /// Retires local credentials before returning the independently retained remote-result task.
    public func beginLeave() -> Task<Void, Error> {
        invalidatePushTokenAcquisition()
        do {
            let retirement = try core.beginLeave()
            apply(core.snapshot())
            applyInbox(core.inboxSnapshot())
            applyPush(core.pushSnapshot())
            return Task { @MainActor [core, weak self] in
                defer {
                    self?.apply(core.snapshot())
                    self?.applyInbox(core.inboxSnapshot())
                    self?.applyPush(core.pushSnapshot())
                }
                do { try await retirement.finish() }
                catch { throw RasheedClientError.wrapping(error) }
            }
        } catch {
            apply(core.snapshot())
            applyInbox(core.inboxSnapshot())
            applyPush(core.pushSnapshot())
            let failure = RasheedClientError.wrapping(error)
            return Task { throw failure }
        }
    }

    public func leave() async throws {
        try await beginLeave().value
    }

    public func forgetDeviceSession() async throws {
        invalidatePushTokenAcquisition()
        try await perform { try await core.forgetDeviceSession() }
    }

    public func retry(refreshIdentity: (@MainActor () async throws -> SignedIdentity?)? = nil) async throws {
        let refresher = refreshIdentity.map { ClientIdentityRefresher(refresh: $0) }
        try await perform { try await core.retry(refresher: refresher) }
    }

    public func invalidateIdentityRefresh() {
        core.invalidateIdentityRefresh()
        applyPush(core.pushSnapshot())
    }

    /// Disconnects a reusable client without canceling retirement or forgetting credentials.
    public func dispose() {
        invalidatePushTokenAcquisition()
        assigneeAvatars.retireAll()
        core.dispose()
        apply(core.snapshot())
        applyInbox(core.inboxSnapshot())
        applyPush(core.pushSnapshot())
    }

    /// For direct APNs, pass raw hex. The SDK adds the host app's bundle identifier.
    public func registerPushToken(platform: PushPlatform, token: String?) async throws {
        if token == nil { invalidatePushTokenAcquisition() }
        let address: String?
        if let token, platform == .apnsSandbox || platform == .apnsProduction {
            guard token.utf8.count <= 512 else {
                throw RasheedClientError.Rejected(code: "INVALID_PUSH_TOKEN", status: nil)
            }
            guard let topic = Bundle.main.bundleIdentifier else {
                throw RasheedClientError.Failed(reason: "Missing host app bundle identifier.")
            }
            address = "\(topic)/\(token.lowercased())"
        } else {
            address = token
        }
        try await perform { try await core.registerPushToken(platform: platform, token: address) }
    }

    /// Pass the device token from the AppDelegate, or nil to disable registration.
    /// Supply the environment only if it cannot be inferred from the app's signing.
    public func registerAPNsDeviceToken(_ token: Data?, environment: RasheedAPNsEnvironment? = nil) async throws {
        let hex = try token.map { bytes in
            guard !bytes.isEmpty, bytes.count <= 256 else {
                throw RasheedClientError.Rejected(code: "INVALID_PUSH_TOKEN", status: nil)
            }
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        try await registerAPNsDeviceToken(hexToken: hex, environment: environment)
    }

    /// Registers a raw hexadecimal APNs token forwarded by a native bridge.
    public func registerAPNsDeviceToken(hexToken token: String?, environment: RasheedAPNsEnvironment? = nil) async throws {
        let platform: PushPlatform = switch environment ?? Self.signedAPNsEnvironment {
        case .some(.sandbox): .apnsSandbox
        case .some(.production): .apnsProduction
        // A disable clears the device's registration even if signing cannot be resolved.
        case nil where token == nil: push.platform == .apnsSandbox ? .apnsSandbox : .apnsProduction
        case nil:
            throw RasheedClientError.Rejected(code: "APNS_ENVIRONMENT_UNKNOWN", status: nil)
        }
        try await registerPushToken(platform: platform, token: token)
    }

    private static let signedAPNsEnvironment: RasheedAPNsEnvironment? = {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        let url = Bundle.main.bundleURL.appendingPathComponent("embedded.mobileprovision")
        let profile: Data
        do {
            profile = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // App Store and TestFlight re-sign the app for production without an embedded profile.
            return .production
        } catch {
            return nil
        }
        // The profile's XML is a signing hint, not a public runtime entitlement API.
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.upperBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile[start.lowerBound..<end.upperBound], options: [], format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        switch entitlements["aps-environment"] as? String {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
        #else
        return nil
        #endif
    }()

    private func invalidatePushTokenAcquisition() {
        NotificationCenter.default.post(name: Self.pushTokenAcquisitionInvalidated, object: self)
    }

    public func retryPushRegistration() async throws {
        try await perform { try await core.retryPushRegistration() }
    }

    @discardableResult
    public func setPushToken(_ token: String) async throws -> Bool {
        try await registerPushToken(platform: .ios, token: token)
        return push.status == .registered
    }

    public func unregisterPush() async throws {
        try await registerPushToken(platform: .ios, token: nil)
    }

    public func currentPushScope(for userInfo: [AnyHashable: Any]) -> PushScope? {
        guard let payload = RasheedNotificationData(userInfo: userInfo),
              let scope = core.pushSnapshot().scope,
              payload.matches(scope), isPushScopeCurrent(scope) else { return nil }
        return scope
    }

    public func isPushScopeCurrent(_ scope: PushScope) -> Bool {
        scope.workspaceId == workspaceId && core.isPushScopeCurrent(scope: scope)
    }

    func refreshSnapshots() {
        apply(core.snapshot())
        applyInbox(core.inboxSnapshot())
        applyPush(core.pushSnapshot())
    }

    public func setInboxActive(_ active: Bool) async throws {
        try await perform { try await core.setInboxActive(active: active) }
    }

    public func setActiveConversation(_ conversationId: String?) async throws {
        try await perform { try await core.setActiveConversation(conversationId: conversationId) }
    }

    public func startConversation() async throws -> InboxTarget {
        try await perform { try await core.startConversation() }
    }

    public func loadConversations(cursor: String? = nil) async throws {
        try await perform { try await core.loadConversations(cursor: cursor) }
    }

    public func loadOlderMessages(target: InboxTarget) async throws {
        try await perform { try await core.loadOlderMessages(target: target) }
    }

    public func jumpToLatest(target: InboxTarget) async throws {
        try await perform { try await core.jumpToLatest(target: target) }
    }

    public func revealMessage(target: InboxTarget, messageId: String) async throws {
        try await perform { try await core.revealMessage(target: target, messageId: messageId) }
    }

    /// Clears the selected thread's unread replies. Calls run one at a time; a failure is never retried.
    public func markRead(target: InboxTarget) async throws {
        try await perform { try await core.markRead(target: target) }
    }

    public func selectFiles(target: InboxTarget, files: [InboxLocalFile]) async throws -> [String] {
        try await perform { try await core.selectFiles(target: target, files: files) }
    }

    func selectPrivateFiles(target: InboxTarget, files: [RasheedAttachmentFile]) async throws {
        let selection = InboxFilePool.shared.beginSelection(files: files, scope: fileScope,
            generation: target.credentialGeneration)
        defer {
            withExtendedLifetime(files) {
                InboxFilePool.shared.endSelection(selection, scope: fileScope)
                retryLocalFileCleanup()
            }
        }
        _ = try await selectFiles(target: target, files: files.map {
            InboxLocalFile(path: $0.url.path, name: $0.fileName, mimeType: $0.mimeType)
        })
    }

    public func retryLocalFileCleanup() {
        let referenced = Set((inbox.attachments.map(\.localPath)
            + (inbox.pendingSend?.files.map(\.localPath) ?? [])).filter { !$0.isEmpty })
        let confirmed = inbox.readState == .confirmed && snapshot.profileState == .confirmed
            && snapshot.status == .ready && inbox.credentialGeneration == credentialGeneration
            && snapshot.profile != nil && snapshot.uncertainIdentity == nil
        assigneeAvatars.releaseUnused()
        InboxFilePool.shared.reconcileCore(scope: fileScope,
            generation: max(credentialGeneration, inbox.credentialGeneration), references: referenced, confirmed: confirmed)
        localFileError = InboxFilePool.shared.retryCleanup()
    }

    public func removeFile(fileId: String) async throws {
        try await perform { try await core.removeFile(fileId: fileId) }
    }

    public func sendMessage(target: InboxTarget, body: String, quoteId: String? = nil) async throws -> String {
        try await perform { try await core.sendMessage(target: target, body: body, quoteId: quoteId) }
    }

    public func retrySend(messageId: String) async throws {
        try await perform { try await core.retrySend(messageId: messageId) }
    }

    public func cancelSend(messageId: String) {
        core.cancelSend(messageId: messageId)
        applyInbox(core.inboxSnapshot())
    }

    public func discardFailed(messageId: String) async throws {
        try await perform { try await core.discardFailed(messageId: messageId) }
    }

    public func downloadAttachment(target: InboxTarget, attachmentId: String, destinationPath: String) async throws {
        try await perform {
            try await core.downloadAttachment(target: target, attachmentId: attachmentId, destinationPath: destinationPath)
        }
    }

    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        defer {
            apply(core.snapshot())
            applyInbox(core.inboxSnapshot())
            applyPush(core.pushSnapshot())
        }
        do { return try await operation() }
        catch { throw RasheedClientError.wrapping(error) }
    }

    private func apply(_ snapshot: RasheedSnapshot) {
        guard snapshot.revision >= self.snapshot.revision else { return }
        if credentialGeneration != snapshot.credentialGeneration {
            composerDrafts.removeAll()
            composerDraftTarget = nil
            connectedOnce = false
            credentialGeneration = snapshot.credentialGeneration
            applyInbox(core.inboxSnapshot())
        }
        trackConnection(snapshot)
        if self.snapshot != snapshot { self.snapshot = snapshot }
        applyPush(core.pushSnapshot())
        assigneeAvatars.reconcile(client: self)
    }

    /// A dropped connection comes back by itself, as the web client's does: soon at first, then every 3 s, so support is
    /// live again within moments of the server returning. Each wait counts from the previous attempt's start, so an
    /// attempt the core abandoned at its deadline is followed at once. Refusals, failed actions and an unconfirmed
    /// identity wait for Try again.
    private func trackConnection(_ snapshot: RasheedSnapshot) {
        if snapshot.status == .ready {
            connectedOnce = true
            reconnectAttempts = 0
        }
        let dropped = snapshot.status == .error && snapshot.error == .Disconnected
            && snapshot.failedAction == nil && snapshot.uncertainIdentity == nil
        if dropped {
            if reconnection == nil {
                let wait = Duration.milliseconds(min(3_000, 500 << min(reconnectAttempts, 3)))
                reconnect(at: (reconnectAttempts == 0 ? .now : attemptStarted) + wait)
            }
        } else if snapshot.status != .connecting {
            reconnection?.cancel()
            reconnection = nil
        }
        let down = dropped || snapshot.status == .connecting
        guard down != connectionDown else { return }
        connectionDown = down
        connectionNotice = nil
        outageClock?.cancel()
        if down, UIApplication.shared.applicationState != .background { startOutageClock() }
    }

    private func reconnect(at deadline: ContinuousClock.Instant = .now) {
        reconnectAttempts += 1
        reconnection = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            reconnection = nil
            attemptStarted = .now
            try? await connect()
        }
    }

    /// The status clock runs only in the foreground, where the outage is seen, so a return to the app never flashes a
    /// status that the prompt reconnect then clears.
    private func startOutageClock() {
        outageClock?.cancel()
        let shown = connectionNotice != nil
        outageClock = Task { [weak self] in
            if !shown {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                self?.connectionNotice = self?.connectedOnce == true ? .reconnecting : .connecting
            }
            try? await Task.sleep(for: .seconds(27))
            if Task.isCancelled { return }
            self?.connectionNotice = .unavailable
        }
    }

    /// A new network path (another interface, or the network back) ends a session on the old one and starts another at
    /// once, and a drop waiting for its retry tries now. The monitor's first update only describes the current path.
    private func pathChanged(_ current: (satisfied: Bool, interface: String?)) {
        defer { heardPath = current }
        guard let heard = heardPath, current.satisfied,
              !heard.satisfied || heard.interface != current.interface else { return }
        core.networkChanged()
        if let waiting = reconnection {
            waiting.cancel()
            reconnectAttempts = 0
            reconnect()
        }
    }

    /// Now on the server's clock: relative times count from it, so a device clock that is off doesn't age them.
    var serverNow: Date { Date().addingTimeInterval(Double(core.serverTimeOffsetMs()) / 1_000) }

    private func resumeOutage() {
        guard connectionDown else { return }
        startOutageClock()
        if let waiting = reconnection {
            waiting.cancel()
            reconnectAttempts = 0
            reconnect()
        }
    }

    private func applyPush(_ snapshot: PushSnapshot) {
        guard snapshot.credentialGeneration >= credentialGeneration,
              snapshot.credentialGeneration >= push.credentialGeneration,
              snapshot.credentialGeneration > push.credentialGeneration || snapshot.revision >= push.revision else { return }
        if push != snapshot { push = snapshot }
    }

    private func applyInbox(_ snapshot: InboxSnapshot) {
        guard snapshot.credentialGeneration >= credentialGeneration,
              snapshot.credentialGeneration >= inbox.credentialGeneration,
              snapshot.credentialGeneration > inbox.credentialGeneration || snapshot.revision >= inbox.revision else { return }
        if snapshot.credentialGeneration != inbox.credentialGeneration {
            composerDrafts.removeAll()
            composerDraftTarget = nil
        }
        if let thread = snapshot.thread, thread.status == .draft { composerDraftTarget = thread.target }
        if let draft = composerDraftTarget,
           snapshot.conversations.contains(where: { $0.id == draft.conversationId })
            || (snapshot.thread?.target == draft && snapshot.thread?.status == .unavailable
                && snapshot.readState == .confirmed) {
            composerDraftTarget = nil
        }
        var recoveryFailure: RasheedClientError?
        for draft in snapshot.attachments + (snapshot.pendingSend?.files ?? [])
            where !draft.localPath.isEmpty {
            do {
                if let file = try RasheedAttachmentFile.restored(path: draft.localPath,
                    attachment: RasheedSupportAttachment(draft.attachment)) {
                    InboxFilePool.shared.retainCore(file: file, scope: fileScope,
                        generation: draft.target.credentialGeneration)
                }
            } catch { recoveryFailure = .Storage(reason: error.localizedDescription) }
        }
        if inbox != snapshot {
            inbox = snapshot
            assigneeAvatars.reconcile(client: self)
            retryLocalFileCleanup()
        }
        if let recoveryFailure { localFileError = recoveryFailure }
    }

    func assigneeImage(for target: InboxTarget) -> String? {
        guard target.credentialGeneration == credentialGeneration,
              snapshot.credentialGeneration == target.credentialGeneration,
              inbox.credentialGeneration == target.credentialGeneration,
              snapshot.profile != nil, snapshot.profileState != .unknown,
              snapshot.uncertainIdentity == nil, inbox.readState != .unknown else { return nil }
        if let thread = inbox.thread, thread.target == target { return thread.summary?.assignee?.image }
        return inbox.conversations.first { $0.id == target.conversationId }?.assignee?.image
    }

    private static func normalizedPlatformURL(_ url: URL) throws -> URL {
        let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              scheme == "https" || local else {
            throw RasheedClientError.Failed(reason: "Use HTTPS for the support server, or HTTP on loopback.")
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = ""
        guard let normalized = components?.url else {
            throw RasheedClientError.Failed(reason: "Invalid support URL.")
        }
        return normalized
    }
}

private final class CorePushListener: RasheedCore.PushListener {
    private let receive: @MainActor @Sendable (PushSnapshot) -> Void

    init(receive: @escaping @MainActor @Sendable (PushSnapshot) -> Void) {
        self.receive = receive
    }

    func onPushSnapshot(snapshot: PushSnapshot) {
        Task { @MainActor [receive] in receive(snapshot) }
    }
}

private final class CoreInboxListener: RasheedCore.InboxListener {
    private let receive: @MainActor @Sendable (InboxSnapshot) -> Void

    init(receive: @escaping @MainActor @Sendable (InboxSnapshot) -> Void) {
        self.receive = receive
    }

    func onInboxSnapshot(snapshot: InboxSnapshot) {
        Task { @MainActor [receive] in receive(snapshot) }
    }
}

private final class ClientSnapshotListener: RasheedCore.SnapshotListener {
    private let receive: @MainActor @Sendable (RasheedSnapshot) -> Void

    init(receive: @escaping @MainActor @Sendable (RasheedSnapshot) -> Void) {
        self.receive = receive
    }

    func onSnapshot(snapshot: RasheedSnapshot) {
        Task { @MainActor [receive] in receive(snapshot) }
    }
}

@MainActor
private final class ClientIdentityRefresher: RasheedCore.IdentityRefresher {
    private let refresh: @MainActor () async throws -> SignedIdentity?

    init(refresh: @escaping @MainActor () async throws -> SignedIdentity?) {
        self.refresh = refresh
    }

    func refreshIdentity() async throws -> RasheedCore.SignedIdentity? {
        do { return try await refresh()?.coreValue }
        catch { throw RasheedClientError.wrapping(error) }
    }
}
