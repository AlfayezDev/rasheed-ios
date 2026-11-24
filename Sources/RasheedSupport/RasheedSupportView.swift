import SwiftUI

@MainActor
public struct RasheedSupportWidget: View {
    @ObservedObject private var client: RasheedClient
    private let locale: Language
    private let theme: RasheedTheme
    private let manageConnection: Bool
    private let refreshIdentity: (@MainActor () async throws -> SignedIdentity?)?
    private let onError: (@MainActor (RasheedClientError) -> Void)?
    private let initialNotificationTarget: RasheedNotificationTarget?
    private let onDismiss: (() -> Void)?
    @Binding private var isOpen: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AccessibilityFocusState private var launcherFocused: Bool

    public init(client: RasheedClient, locale: Language, theme: RasheedTheme = .system,
                open: Binding<Bool>, manageConnection: Bool = true,
                refreshIdentity: (@MainActor () async throws -> SignedIdentity?)? = nil,
                onError: (@MainActor (RasheedClientError) -> Void)? = nil,
                initialNotificationTarget: RasheedNotificationTarget? = nil,
                onDismiss: (() -> Void)? = nil) {
        self.client = client
        self.locale = locale
        self.theme = theme
        self.manageConnection = manageConnection
        self.refreshIdentity = refreshIdentity
        self.onError = onError
        self.initialNotificationTarget = initialNotificationTarget
        self.onDismiss = onDismiss
        _isOpen = open
    }

    /// Replies not yet seen across the loaded conversations of the current session.
    private var unread: Int {
        guard client.inbox.credentialGeneration == client.credentialGeneration else { return 0 }
        return client.inbox.conversations.reduce(0) { $0 + Int($1.unread) }
    }

    public var body: some View {
        let colors = RasheedSupportTheme.resolve(theme.colorScheme ?? colorScheme)
        let copy = SupportCopy(isArabic: locale == .ar)
        // The web's launcher: a 52-point circle in the ink with the message glyph, and the unread count at its
        // top-end corner.
        Button { isOpen = true } label: {
            Image(systemName: "message")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(colors.onAccent)
                .frame(width: 52, height: 52)
                .background(colors.accent, in: Circle())
                .shadow(color: .black.opacity(colors.isDark ? 0.5 : 0.25), radius: 8, y: 7)
                .overlay(alignment: .topTrailing) {
                    if unread > 0 && !isOpen {
                        Text(unread > 9 ? "9+" : "\(unread)")
                            .font(RasheedFont.font(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(colors.onAccent)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(colors.danger, in: Capsule())
                            .padding(2)
                            .background(colors.surface, in: Capsule())
                            .fixedSize()
                            .environment(\.layoutDirection, .leftToRight)
                            .padding(.top, -6)
                            .padding(.trailing, -6)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(RasheedPressStyle(scale: 0.97, radius: 26, pressedOpacity: 1))
        .accessibilityLabel(unread > 0
            ? RasheedCount.launcherUnread.text(unread, language: locale) : copy.title)
        .accessibilityFocused($launcherFocused)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .environment(\.layoutDirection, locale == .ar ? .rightToLeft : .leftToRight)
        .preferredColorScheme(theme == .system ? nil : theme == .dark ? .dark : .light)
        .rasheedSupportPresentation(isPresented: $isOpen, onDismiss: onDismiss) {
            RasheedSupportView(client: client, locale: locale, theme: theme,
                               refreshIdentity: refreshIdentity, manageConnection: manageConnection,
                               onError: onError, initialNotificationTarget: initialNotificationTarget)
        }
        .onChange(of: isOpen) { _, open in if !open { launcherFocused = true } }
    }
}

public extension View {
    /// Presents support as the web widget does on phones: full screen on iPhone, a sheet on iPad. With Reduce Motion it
    /// appears and leaves without sliding. `RasheedSupportWidget` presents this way; use it when you present
    /// `RasheedSupportView` yourself. `onDismiss` runs once support has left the screen.
    func rasheedSupportPresentation<Support: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                                   @ViewBuilder content: @escaping () -> Support) -> some View {
        modifier(RasheedSupportCover(isPresented: isPresented, onDismiss: onDismiss, support: content))
    }
}

extension RasheedSupportPresentation {
    /// The idiom, not the size class, so turning a large iPhone sideways never swaps a cover for a sheet.
    @MainActor var fillsScreen: Bool {
        switch self {
        case .automatic: UIDevice.current.userInterfaceIdiom == .phone
        case .fullScreen: true
        case .sheet: false
        }
    }
}

private struct RasheedSupportCover<Support: View>: ViewModifier {
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?
    let support: () -> Support
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let cover = RasheedSupportPresentation.automatic.fillsScreen
        content
            .sheet(isPresented: Binding(get: { isPresented && !cover }, set: { if !$0 { isPresented = false } }),
                   onDismiss: onDismiss) {
                support().presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: Binding(get: { isPresented && cover }, set: { if !$0 { isPresented = false } }),
                             onDismiss: onDismiss) {
                support()
            }
            .transaction(value: isPresented) { if reduceMotion { $0.disablesAnimations = true } }
    }
}

@MainActor
public struct RasheedSupportView: View {
    @ObservedObject private var client: RasheedClient
    private let locale: Language
    private let theme: RasheedTheme
    private let identity: SignedIdentity?
    private let initialSpace: RasheedSupportSpace
    private let initialConversationID: String?
    private let initialMediaIndex: Int?
    private let initialNotificationTarget: RasheedNotificationTarget?
    private let providedModel: RasheedSupportModel?
    private let refreshIdentity: (@MainActor () async throws -> SignedIdentity?)?
    private let manageConnection: Bool
    private let onError: (@MainActor (RasheedClientError) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var language: Language
    @State private var pending: PendingAction?
    @State private var confirmEnd = false
    @State private var viewOwner = UUID()
    @State private var viewError: RasheedClientError?
    @AccessibilityFocusState private var endFocus: EndControl?

    private enum PendingAction { case join, identify, leave, retry }
    private enum EndControl { case start, cancel }

    public init(client: RasheedClient, locale: Language, theme: RasheedTheme = .system,
                identity: SignedIdentity? = nil,
                initialSpace: RasheedSupportSpace = .home,
                initialConversationID: String? = nil, initialMediaIndex: Int? = nil,
                refreshIdentity: (@MainActor () async throws -> SignedIdentity?)? = nil,
                manageConnection: Bool = true,
                onError: (@MainActor (RasheedClientError) -> Void)? = nil,
                initialNotificationTarget: RasheedNotificationTarget? = nil) {
        self.client = client
        self.locale = locale
        self.theme = theme
        self.identity = identity
        self.initialSpace = initialSpace
        self.initialConversationID = initialConversationID
        self.initialMediaIndex = initialMediaIndex
        self.initialNotificationTarget = initialNotificationTarget
        providedModel = nil
        self.refreshIdentity = refreshIdentity
        self.manageConnection = manageConnection
        self.onError = onError
        _language = State(initialValue: locale)
    }

    public init(model: RasheedSupportModel, initialSpace: RasheedSupportSpace = .home,
                initialConversationID: String? = nil, initialMediaIndex: Int? = nil,
                refreshIdentity: (@MainActor () async throws -> SignedIdentity?)? = nil,
                initialNotificationTarget: RasheedNotificationTarget? = nil) {
        client = model.client
        locale = model.configuration.language
        theme = model.configuration.theme
        identity = nil
        self.refreshIdentity = refreshIdentity
        manageConnection = true
        onError = nil
        self.initialSpace = initialSpace
        self.initialConversationID = initialConversationID
        self.initialMediaIndex = initialMediaIndex
        self.initialNotificationTarget = initialNotificationTarget
        providedModel = model
        _language = State(initialValue: model.configuration.language)
    }

    private var copy: SupportCopy { SupportCopy(isArabic: language == .ar) }
    private var dark: Bool { theme == .dark || (theme == .system && colorScheme == .dark) }
    private var colors: RasheedSupportTheme { .resolve(dark ? .dark : .light) }
    private var failure: RasheedClientError? { client.failedAction?.error ?? client.uncertainIdentity ?? client.snapshot.error ?? viewError }
    private var missingWorkspace: Bool { client.snapshot.workspaceReady && client.snapshot.workspace == nil }
    /// A failure to show. An outage shows its own quiet status instead, and the client restores the connection.
    private var unavailable: Bool { (failure != nil || missingWorkspace) && !client.connectionDown }
    private var storageFailed: Bool {
        if case .Storage? = client.snapshot.error { return true }
        if case .Storage? = failure { return true }
        return false
    }
    private var guestConfirmed: Bool { client.snapshot.status == .ready && client.snapshot.profileState == .confirmed }
    private var canEnd: Bool {
        client.snapshot.profile != nil || failure?.uncertain == true || client.uncertainIdentity != nil || storageFailed
    }

    public var body: some View {
        RasheedInboxPresentation(client: client, locale: language, theme: theme,
                                 initialSpace: initialSpace, initialConversationID: initialConversationID,
                                 initialMediaIndex: initialMediaIndex,
                                 initialNotificationTarget: initialNotificationTarget, model: providedModel,
                                 toggleLanguage: { language = language == .ar ? .en : .ar }) {
            home
        } settings: {
            settings
        }
        .id(ObjectIdentifier(client))
        .background(colors.surface).foregroundStyle(colors.ink).tint(colors.ink)
        // VoiceOver's escape gesture closes support, as the header's close button does.
        .accessibilityAction(.escape) { dismiss() }
        .environment(\.layoutDirection, language == .ar ? .rightToLeft : .leftToRight)
        .preferredColorScheme(theme == .system ? nil : dark ? .dark : .light)
        .task { if manageConnection { await connect() } }
        .task(id: identity) {
            guard let identity else { return }
            if let action = client.failedAction?.action,
               case .identify(let previous) = action, previous == identity.coreValue { return }
            await change(.identify) { try await client.identify(identity) }
        }
        .onChange(of: locale) { _, value in language = value }
        .onChange(of: client.snapshot.error) { _, error in
            if let error { onError?(error) }
        }
        .onChange(of: client.credentialGeneration) { _, _ in
            viewOwner = UUID()
            pending = nil
            viewError = nil
            confirmEnd = false
        }
        .onDisappear {
            viewOwner = UUID()
            pending = nil
        }
    }

    /// Home's session section, under the question and any conversations, as on the web: Start a conversation for a
    /// guest, placeholders until the session is known, a failure with its retry, and the status line.
    private var home: some View {
        VStack(alignment: .leading, spacing: 24) {
            if client.snapshot.profile == nil && !unavailable {
                if client.snapshot.profileState == .unknown {
                    placeholders
                } else {
                    GuestStart(copy: copy, busy: pending == .join, disabled: !guestConfirmed || pending != nil,
                               theme: colors) { started in
                        run(.join) {
                            try await client.join(language: language)
                            started()
                        }
                    }
                }
            }
            notices
            if client.snapshot.profile == nil && unavailable && canEnd { endSession }
            Text(statusText.isEmpty ? " " : statusText)
                .rasheed(.meta)
                .foregroundStyle(colors.muted)
                .accessibilityHidden(statusText.isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The web's support settings, reached from the Messages list: the profile, then ending this device's session.
    private var settings: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text(copy.settings)
                .rasheed(.heading)
                .accessibilityAddTraits(.isHeader)
            if let profile = client.snapshot.profile {
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile.name.isEmpty ? copy.guest : profile.name)
                        .rasheed(.sub, weight: .semibold)
                    if !profile.email.isEmpty {
                        Text(profile.email)
                            .rasheed(.sub)
                            .foregroundStyle(colors.muted)
                            .environment(\.layoutDirection, .leftToRight)
                    }
                }
                .textSelection(.enabled)
                soundSetting
                endSession
                    .padding(.top, 24)
                    .overlay(alignment: .top) { colors.border.frame(height: 1) }
            }
            notices
            if !statusText.isEmpty {
                Text(statusText).rasheed(.meta).foregroundStyle(colors.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The web's Sound setting: replies chime while support is open. The whole row toggles it.
    private var soundSetting: some View {
        Toggle(isOn: $client.soundOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy.sound).rasheed(.sub)
                Text(copy.soundHint).rasheed(.meta).foregroundStyle(colors.muted)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { client.soundOn.toggle() }
        }
        .tint(colors.accent)
        .accessibilityIdentifier("rasheed.sound")
    }

    /// What failed and its one retry.
    @ViewBuilder private var notices: some View {
        if unavailable {
            Text(copy.error(identityExpired ? .Rejected(code: "IDENTITY_EXPIRED", status: nil) : failure))
                .rasheed(.meta)
                .foregroundStyle(colors.danger)
                .textSelection(.enabled)
            if !identityExpired || refreshIdentity != nil {
                RasheedSecondaryButton(title: copy.retry, identifier: "rasheed.retry.session",
                                       disabled: pending != nil, theme: colors) {
                    run(.retry) { try await client.retry(refreshIdentity: refreshIdentity) }
                }
            }
        }
    }

    /// Ending the session asks once, in place.
    @ViewBuilder private var endSession: some View {
        if confirmEnd {
            VStack(alignment: .leading, spacing: 10) {
                Text(copy.confirmClear).rasheed(.sub)
                HStack(spacing: 8) {
                    RasheedSecondaryButton(title: copy.cancel, disabled: pending == .leave, theme: colors) {
                        confirmEnd = false
                        endFocus = .start
                    }
                    .accessibilityFocused($endFocus, equals: .cancel)
                    RasheedSecondaryButton(title: pending == .leave ? copy.clearing : copy.confirm,
                                           identifier: "rasheed.end.confirm", destructive: true,
                                           disabled: pending != nil || !canEnd, theme: colors) {
                        run(.leave) { try await client.leave() }
                    }
                }
            }
        } else {
            Button {
                confirmEnd = true
                endFocus = .cancel
            } label: {
                Text(copy.clear)
                    .rasheed(.sub)
                    .foregroundStyle(colors.ink)
                    .padding(8)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            // As on the web, the pressed fill and focus ring get 8 points around the text, which stays on the edge.
            .buttonStyle(RasheedRowStyle(theme: colors, radius: RasheedRadius.control, outset: 0, inset: 0))
            .padding(.horizontal, -8)
            .disabled(pending != nil || !canEnd)
            .accessibilityFocused($endFocus, equals: .start)
            .accessibilityIdentifier("rasheed.end")
        }
    }

    /// The web's loading placeholders: Start a conversation's control and its note.
    private var placeholders: some View {
        VStack(alignment: .leading, spacing: 12) {
            placeholder(1, height: 48, radius: RasheedRadius.control)
            placeholder(0.7, height: 19.5, radius: RasheedRadius.chip)
        }
        .accessibilityHidden(true)
    }

    private func placeholder(_ fraction: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(colors.ink.opacity(0.07))
                .frame(width: geometry.size.width * fraction)
        }
        .frame(height: height)
    }

    /// Ending the session. An outage's status shows under the header's title instead.
    private var statusText: String { pending == .leave ? copy.clearing : "" }

    private var identityExpired: Bool {
        if let failure, case .Rejected(let code, _) = failure, code == "IDENTITY_EXPIRED" { return true }
        if let action = client.failedAction?.action, case .identify(let identity) = action {
            return identity.expiresAt <= Int64(Date().timeIntervalSince1970 * 1_000)
        }
        return false
    }

    private func connect() async {
        let owner = viewOwner
        do {
            try await client.connect()
            if viewOwner == owner { viewError = nil }
        }
        catch {
            let failure = RasheedClientError.wrapping(error)
            // A dropped connection is the client's to restore; meanwhile the outage shows its status.
            if viewOwner == owner, failure != .Disconnected {
                viewError = failure
                if client.snapshot.error != failure { onError?(failure) }
            }
        }
    }

    private func run(_ action: PendingAction, _ operation: @escaping @MainActor () async throws -> Void) {
        guard pending == nil else { return }
        pending = action
        Task { @MainActor in await change(action, operation) }
    }

    private func change(_ action: PendingAction, _ operation: @MainActor () async throws -> Void) async {
        let owner = viewOwner
        pending = action
        viewError = nil
        do { try await operation() }
        catch {
            if owner == viewOwner {
                let failure = RasheedClientError.wrapping(error)
                viewError = failure
                onError?(failure)
            }
        }
        if owner == viewOwner { pending = nil }
    }
}

@MainActor
private struct RasheedInboxPresentation<Home: View, Settings: View>: View {
    @StateObject private var model: RasheedSupportModel
    @ObservedObject private var client: RasheedClient
    let locale: Language
    let theme: RasheedTheme
    let initialSpace: RasheedSupportSpace
    let initialConversationID: String?
    let initialMediaIndex: Int?
    let initialNotificationTarget: RasheedNotificationTarget?
    let toggleLanguage: () -> Void
    let home: Home
    let settings: Settings

    init(client: RasheedClient, locale: Language, theme: RasheedTheme,
         initialSpace: RasheedSupportSpace, initialConversationID: String?, initialMediaIndex: Int?,
         initialNotificationTarget: RasheedNotificationTarget?,
         model: RasheedSupportModel?,
         toggleLanguage: @escaping () -> Void,
         @ViewBuilder home: () -> Home,
         @ViewBuilder settings: () -> Settings) {
        self.client = client
        self.locale = locale
        self.theme = theme
        self.initialSpace = initialSpace
        self.initialConversationID = initialConversationID
        self.initialMediaIndex = initialMediaIndex
        self.initialNotificationTarget = initialNotificationTarget
        self.toggleLanguage = toggleLanguage
        self.home = home()
        self.settings = settings()
        _model = StateObject(wrappedValue: model ?? RasheedSupportModel(client: client,
            configuration: RasheedSupportConfiguration(language: locale, theme: theme)))
    }

    var body: some View {
        RasheedInboxView(model: model, initialSpace: initialSpace,
                         initialConversationID: initialConversationID, initialMediaIndex: initialMediaIndex,
                         initialNotificationTarget: initialNotificationTarget, toggleLanguage: toggleLanguage) {
            home
        } settings: {
            settings
        }
            .id(client.credentialGeneration)
            .onChange(of: locale) { _, value in model.updatePresentation(language: value, theme: theme) }
            .onChange(of: theme) { _, value in model.updatePresentation(language: locale, theme: value) }
    }
}

private struct SupportCopy {
    let isArabic: Bool
    var title: String { isArabic ? "الدعم" : "Support" }
    var guest: String { isArabic ? "ضيف" : "Guest" }
    var start: String { isArabic ? "بدء محادثة" : "Start a conversation" }
    var starting: String { isArabic ? "جارٍ بدء المحادثة…" : "Starting…" }
    var guestNote: String { isArabic ? "ستتحدث معنا ضيفًا من هذا الجهاز، دون تسجيل دخول." : "You’ll chat as a guest on this device. No sign-in needed." }
    var sound: String { isArabic ? "الصوت" : "Sound" }
    var soundHint: String { isArabic ? "تشغيل صوت عند وصول رد جديد." : "Play a sound for new replies." }
    var settings: String { isArabic ? "إعدادات الدعم" : "Support settings" }
    var clear: String { isArabic ? "إنهاء جلسة الدعم على هذا الجهاز" : "End support session on this device" }
    var confirmClear: String { isArabic ? "إنهاء جلسة الدعم على هذا الجهاز؟" : "End support session on this device?" }
    var confirm: String { isArabic ? "إنهاء الجلسة" : "End session" }
    var cancel: String { isArabic ? "إلغاء" : "Cancel" }
    var clearing: String { isArabic ? "جارٍ إنهاء الجلسة…" : "Ending session…" }
    var retry: String { isArabic ? "إعادة المحاولة" : "Try again" }

    func error(_ error: RasheedClientError?) -> String {
        guard let error else { return isArabic ? "الدعم غير متاح الآن." : "Support is unavailable right now." }
        switch error {
        case .OutcomeUnknown: return isArabic ? "تعذّر تأكيد التغيير. أعد المحاولة للتحقق من جلسة هذا الجهاز." : "The change could not be confirmed. Try again to check this device’s session."
        case .Canceled: return isArabic ? "أُلغي الطلب. أعد المحاولة للتحقق من جلسة هذا الجهاز." : "The request was canceled. Try again to check this device’s session."
        case .Rejected(let code, _) where code == "IDENTITY_EXPIRED":
            return isArabic ? "سجّل الدخول إلى التطبيق مجددًا للاتصال بالدعم." : "Sign in to the app again to reconnect to support."
        case .Rejected: return isArabic ? "رُفض الطلب." : "The request was refused."
        default: return isArabic ? "الدعم غير متاح الآن." : "Support is unavailable right now."
        }
    }
}

/// Before joining, as on the web: Start a conversation joins as a guest in the current language, then the inbox opens
/// an empty local draft and focuses its composer. Nothing is created on the server until the first send.
private struct GuestStart: View {
    @Environment(\.rasheedStart) private var start
    let copy: SupportCopy
    let busy: Bool
    let disabled: Bool
    let theme: RasheedSupportTheme
    let join: (@escaping @MainActor () -> Void) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RasheedPrimaryButton(title: busy ? copy.starting : copy.start, identifier: "rasheed.join", chevron: true,
                                 disabled: disabled, theme: theme) {
                let start = start
                join { start?.run() }
            }
            Text(copy.guestNote)
                .rasheed(.meta)
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
