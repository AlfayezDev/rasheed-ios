import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
struct RasheedInboxView<Home: View, Settings: View>: View {
	@ObservedObject private var model: RasheedSupportModel
	private let home: Home
	private let settings: Settings
	private let toggleLanguage: () -> Void
	@State private var space: RasheedSupportSpace
	@State private var transcriptOrigin: RasheedSupportSpace
	@State private var selectedConversation: String?
	@State private var composingNew = false
	/// Support settings, opened from the Messages list; Back returns to it.
	@State private var showingSettings = false
	@State private var viewerContext: RasheedMediaViewerContext?
	@State private var pickedItem: PhotosPickerItem?
	/// The photo picker is presented from the view, not from inside the attach menu, where iOS 26 never presents it.
	@State private var choosingPhoto = false
	@State private var importingFile = false
	@State private var fileTarget: InboxTarget?
	@State private var fileImportTask: Task<Void, Never>?
	@State private var olderAnchor: String?
	@State private var highlightedReplyTargetID: String?
	/// Attachments whose download failed, shown on their rows, and images whose thumbnail failed to load.
	@State private var fileFailures: Set<String> = []
	@State private var thumbnailFailures: Set<String> = []
	@State private var downloading: Set<String> = []
	@State private var sharedFile: RasheedSharedFile?
	/// The screen's content has scrolled under the header, which then shows its divider.
	@State private var contentScrolled = false
	/// Start a conversation focuses the draft's composer once it appears.
	@State private var focusComposerOnOpen = false
	@State private var stagedHeight: CGFloat = 0
	/// The follower and the measurements behind it, held by reference: a scroll phase or a scroll frame updates only
	/// the views that draw from them, not every row of the transcript.
	@State private var transcriptState = RasheedTranscriptState()
	/// The contact's newest message the transcript has seen, so their own message is told apart from a reply that
	/// lands in the same update.
	@State private var newestOwnId: String?
	@FocusState private var composerFocused: Bool
	/// What a multi-line field keeps once the tab just typed into it is taken out (see `typedTabRemoved`).
	@State private var composerWithoutTab: String?
	@State private var retryingPush = false
	@State private var scopedNotification: RasheedNotificationTarget?
	@State private var initialNotificationHandled = false
	/// This screen announced the current outage, so it announces the return too.
	@State private var outageAnnounced = false
	/// When support last came back, so a flapping connection is announced once, not at every drop.
	@State private var lastRecovery = Date.distantPast
	@Environment(\.dismiss) private var dismiss
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@Environment(\.dynamicTypeSize) private var dynamicTypeSize
	/// Counts the app's returns to the foreground, so an open thread checks its unread replies again.
	@State private var activations = 0
	/// Dynamic Type for text built from runs of different fonts, which a view modifier can't size.
	@ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

	/// The longest message the database takes, counted as it counts: in UTF-16 code units.
	private static var messageLimit: Int { 8_000 }

	private let initialMediaIndex: Int?
	private let initialNotificationTarget: RasheedNotificationTarget?
	private struct Selection: Equatable {
		let conversationId: String?
		let ready: Bool
		let notification: RasheedNotificationTarget?
		let initialNotificationPending: Bool
	}

	init(
		model: RasheedSupportModel,
		initialSpace: RasheedSupportSpace = .home,
		initialConversationID: String? = nil,
		initialMediaIndex: Int? = nil,
		initialNotificationTarget: RasheedNotificationTarget? = nil,
		toggleLanguage: @escaping () -> Void,
		@ViewBuilder home: () -> Home,
		@ViewBuilder settings: () -> Settings
	) {
		self.model = model
		self.home = home()
		self.settings = settings()
		self.toggleLanguage = toggleLanguage
		_space = State(initialValue: initialNotificationTarget != nil ? .home : initialConversationID == nil ? initialSpace : .messages)
		_transcriptOrigin = State(initialValue: initialSpace)
		_selectedConversation = State(initialValue: initialNotificationTarget == nil ? initialConversationID : nil)
		self.initialMediaIndex = initialMediaIndex
		self.initialNotificationTarget = initialNotificationTarget
	}

	private var theme: RasheedSupportTheme {
		.resolve(forcedColorScheme ?? colorScheme)
	}

	private var isShowingTranscript: Bool {
		space == .messages && (selectedConversation != nil || composingNew)
			&& (scopedNotification.map { model.client.isPushScopeCurrent($0.scope) } ?? true)
	}

	/// The selected thread is on screen, not covered by the viewer or a picker.
	private var threadVisible: Bool {
		isShowingTranscript && selectedConversation != nil && selectedConversation == model.target?.conversationId
			&& viewerContext == nil && !choosingPhoto && !importingFile
	}

	private struct ReadCheck: Equatable {
		let visible: Bool
		let unread: Int
		let latest: String?
		let loading: Bool
		let browsingHistory: Bool
		let activations: Int
	}

	private struct ScreenKey: Equatable {
		let space: RasheedSupportSpace
		let conversation: String?
		let composing: Bool
		let settings: Bool
	}

	/// The space on screen: Home while a notification's scope is no longer current.
	private var shownSpace: RasheedSupportSpace {
		scopedNotification.map { model.client.isPushScopeCurrent($0.scope) } == false ? .home : space
	}

	private var isShowingSettings: Bool { showingSettings && shownSpace == .messages && !isShowingTranscript }

	/// As on the web, the tabs appear once the guest has joined, on Home and the Messages list.
	private var showsTabs: Bool {
		model.client.snapshot.profile != nil && !isShowingTranscript && !isShowingSettings
	}

	private var stepAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.18) }

	private var liveMedia: [RasheedSupportAttachment] {
		shownMessages.flatMap(\.attachments)
	}

	var body: some View {
		ZStack {
			VStack(spacing: 0) {
				header
				failureBanner
				content
				if showsTabs {
					tabBar
				}
			}
			.background(theme.surface.ignoresSafeArea())
			// The lightbox is modal: VoiceOver and taps never reach the chat dimmed behind it.
			.accessibilityHidden(viewerContext != nil)

			if let viewerContext {
				RasheedLightbox(
					context: viewerContext,
					language: model.configuration.language,
					model: model
				) {
					withAnimation(stepAnimation) {
						self.viewerContext = nil
					}
				}
				.zIndex(1)
				.transition(.opacity)
			}
		}
		.background {
			ConversationVisibilityProbe(client: model.client, target: threadVisible ? model.target : nil)
		}
		// The reply sound tells the thread on screen from the rest.
		.onChange(of: threadVisible ? model.target : nil, initial: true) { _, target in model.visibleThread = target }
		// Replies count as read once the thread's latest messages are on screen in the foreground: on opening, on
		// returning to the app and as replies arrive.
		.task(id: ReadCheck(visible: threadVisible, unread: model.target.map { model.unread(of: $0.conversationId) } ?? 0,
			latest: model.inboxSnapshot.thread?.messages.last?.id, loading: model.loadingThread,
			browsingHistory: model.browsingHistory, activations: activations)) {
			guard threadVisible, UIApplication.shared.applicationState == .active else { return }
			model.markRead()
		}
		.onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
			activations += 1
		}
		// VoiceOver hears an outage once, when its status appears, and once when support is back; a drop within 30 s
		// of the last return stays on screen only.
		.onChange(of: model.connectionNotice) { _, notice in
			if let notice {
				guard !outageAnnounced, Date().timeIntervalSince(lastRecovery) > 30,
					UIApplication.shared.applicationState == .active else { return }
				outageAnnounced = true
				UIAccessibility.post(notification: .announcement, argument: notice.text(arabic: model.configuration.language == .ar))
			} else {
				defer { outageAnnounced = false }
				guard model.client.snapshot.status == .ready else { return }
				lastRecovery = Date()
				if outageAnnounced {
					UIAccessibility.post(notification: .announcement, argument: localized("Connected to support", "متصل بالدعم"))
				}
			}
		}
		// Start a conversation joined as a guest; its draft opens once the inbox is ready, unless the guest moved on.
		.task(id: model.startRequested && model.canStartConversation) {
			guard model.startRequested, model.canStartConversation else { return }
			model.consumeStartRequest()
			guard shownSpace == .home else { return }
			startConversation(focusComposer: true)
		}
		.onChange(of: ScreenKey(space: shownSpace, conversation: isShowingTranscript ? selectedConversation : nil,
			composing: composingNew, settings: isShowingSettings)) {
			contentScrolled = false
			// The screens swap in place, so VoiceOver is told the screen changed and starts again at its top.
			UIAccessibility.post(notification: .screenChanged, argument: nil)
		}
		.sheet(item: $sharedFile) { RasheedShareSheet(shared: $0).presentationDetents([.medium, .large]) }
		.task(id: Selection(conversationId: isShowingTranscript ? selectedConversation : nil,
			ready: model.identityReady, notification: scopedNotification,
			initialNotificationPending: initialNotificationTarget != nil && !initialNotificationHandled)) {
			guard initialNotificationTarget == nil || initialNotificationHandled || scopedNotification != nil else { return }
			await startVisibleConversation()
		}
		.task(id: initialNotificationTarget) {
			initialNotificationHandled = false
			defer { initialNotificationHandled = true }
			guard let target = initialNotificationTarget, model.client.isPushScopeCurrent(target.scope) else { return }
			guard await model.openNotification(target) else { return }
			guard model.client.isPushScopeCurrent(target.scope), !Task.isCancelled else { return }
			if let resolved = model.requestedNotificationTarget, resolved.scope == target.scope {
				applyNotification(resolved)
			}
		}
		.onChange(of: model.requestedNotificationTarget) { target in
			guard let target else { return }
			applyNotification(target)
		}
		.onChange(of: model.pushSnapshot) { _ in
			if let target = scopedNotification, !model.client.isPushScopeCurrent(target.scope) {
				clearScopedNotification()
			}
		}
		.onDisappear {
			fileImportTask?.cancel()
			pickedItem = nil
			viewerContext = nil
			model.visibleThread = nil
			model.stop()
		}
		.onChange(of: model.contentRevision) { _ in
			fileImportTask?.cancel()
			fileFailures = []
			thumbnailFailures = []
			downloading = []
			sharedFile = nil
			pickedItem = nil
			transcriptState.latest = nil
			transcriptState = RasheedTranscriptState()
			olderAnchor = nil
			highlightedReplyTargetID = nil
			newestOwnId = nil
			viewerContext = nil
			importingFile = false
			choosingPhoto = false
			fileTarget = nil
			composerFocused = false
		}
		.photosPicker(isPresented: $choosingPhoto, selection: $pickedItem, matching: .any(of: [.images, .videos]),
			preferredItemEncoding: .compatible)
		.task(id: pickedItem) {
			if let item = pickedItem, let fileTarget { await model.stagePhoto(item, target: fileTarget) }
			if !Task.isCancelled { pickedItem = nil }
		}
		.fileImporter(isPresented: $importingFile, allowedContentTypes: [.image, .movie, .audio, .pdf, .plainText, .content], allowsMultipleSelection: true) { result in
			guard let target = fileTarget else { return }
			fileImportTask?.cancel()
			fileImportTask = Task {
				await model.stageFiles(result, target: target)
			}
		}
		.onChange(of: space) { space in
			if space != .messages {
				scopedNotification = nil
				showingSettings = false
			}
			if space == .messages, selectedConversation == nil, scopedNotification == nil {
				Task { await model.loadConversations() }
			}
		}
		.onChange(of: model.requestedSpace) { requested in
			guard let requested else { return }
			scopedNotification = nil
			let conversationId = model.requestedConversationId
			let alreadySelected = space == requested && selectedConversation == conversationId && !composingNew
			if requested == .messages && conversationId != nil && !isShowingTranscript {
				transcriptOrigin = space
			}
			model.clearRequest()
			withAnimation(stepAnimation) {
				space = requested
				selectedConversation = conversationId
				composingNew = false
				showingSettings = false
			}
			if alreadySelected {
				Task { await startVisibleConversation() }
			}
		}
		.onChange(of: model.conversationId) { id in
			guard composingNew, let id else { return }
			selectedConversation = id
			composingNew = false
		}
		.preferredColorScheme(forcedColorScheme)
		.environment(\.layoutDirection, model.configuration.language == .ar ? .rightToLeft : .leftToRight)
		.environment(\.rasheedArabic, model.configuration.language == .ar)
	}

	private var forcedColorScheme: ColorScheme? { model.configuration.theme.colorScheme }

	private func applyNotification(_ target: RasheedNotificationTarget) {
		model.consumeNotificationRequest()
		guard model.client.isPushScopeCurrent(target.scope) else { return }
		withAnimation(stepAnimation) {
			guard model.client.isPushScopeCurrent(target.scope) else { return }
			if !isShowingTranscript { transcriptOrigin = space }
			scopedNotification = target
			space = .messages
			selectedConversation = target.conversationId
			composingNew = false
			showingSettings = false
		}
	}

	private func clearScopedNotification() {
		scopedNotification = nil
		model.clearRequest()
		selectedConversation = nil
		composingNew = false
		viewerContext = nil
		fileImportTask?.cancel()
		pickedItem = nil
		space = .home
	}

	private func startVisibleConversation() async {
		if let target = scopedNotification,
			space == .messages, selectedConversation == target.conversationId {
			guard model.client.isPushScopeCurrent(target.scope) else { clearScopedNotification(); return }
			guard await model.start(notificationTarget: target) else {
				if scopedNotification == target, !model.client.isPushScopeCurrent(target.scope) { clearScopedNotification() }
				return
			}
			guard scopedNotification == target, space == .messages, selectedConversation == target.conversationId else { return }
			guard model.client.isPushScopeCurrent(target.scope), !Task.isCancelled else {
				if !model.client.isPushScopeCurrent(target.scope) { clearScopedNotification() }
				return
			}
		} else {
			scopedNotification = nil
			await model.start(conversationId: isShowingTranscript ? selectedConversation : nil)
			guard !Task.isCancelled else { return }
		}
		openInitialMediaIfNeeded()
	}

	private func openInitialMediaIfNeeded() {
		guard let initialMediaIndex, viewerContext == nil, selectedConversation != nil else { return }
		guard !liveMedia.isEmpty else { return }
		viewerContext = RasheedMediaViewerContext(
			attachments: liveMedia,
			index: min(max(initialMediaIndex, 0), liveMedia.count - 1)
		)
	}

	/// The web's header on every screen: Back except on Home, the workspace's logo and name (an assigned thread's
	/// assignee instead), the language toggle and close. Larger text grows it past 64 points instead of spilling.
	private var header: some View {
		HStack(spacing: 4) {
			if shownSpace != .home {
				RasheedIconButton(systemName: "chevron.backward", label: backTitle, identifier: "rasheed.back",
					theme: theme, action: goBack)
					.padding(.leading, -4)
			}
			if let assignee = headerAssignee {
				RasheedAssigneeAvatar(name: assignee.title, image: assignee.image, target: model.target, client: model.client,
					size: 28, theme: theme)
			} else if let logo = model.client.snapshot.workspace?.logoURL {
				WorkspaceLogo(url: logo, theme: theme).id(logo)
			}
			VStack(alignment: .leading, spacing: 1) {
				if brandingPending && headerAssignee == nil {
					RoundedRectangle(cornerRadius: RasheedRadius.chip, style: .continuous)
						.fill(theme.ink.opacity(0.07))
						.frame(width: 120, height: 18)
						.accessibilityHidden(true)
				} else {
					Text(headerAssignee?.title ?? organizationTitle)
						.rasheed(.title)
						.foregroundStyle(theme.ink)
						.lineLimit(2)
						.accessibilityAddTraits(.isHeader)
				}
				// An outage's status, under the title on every screen, so showing it moves no content.
				if let notice = model.connectionNotice {
					Text(notice.text(arabic: model.configuration.language == .ar))
						.rasheed(.meta)
						.foregroundStyle(theme.muted)
						.lineLimit(1)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			HStack(spacing: 2) {
				Button(action: toggleLanguage) {
					Text(nextLanguage)
						.rasheed(.control)
						.foregroundStyle(theme.ink)
						.padding(8)
						.frame(minWidth: 44, minHeight: 44)
						.contentShape(Rectangle())
				}
				.buttonStyle(RasheedPressStyle())
				.accessibilityLabel(languageLabel)
				.accessibilityIdentifier("rasheed.language")
				RasheedIconButton(systemName: "xmark", label: closeTitle, identifier: "rasheed.close", size: 14,
					theme: theme) { dismiss() }
			}
		}
		.padding(.horizontal, 12)
		.frame(minHeight: 64)
		// As on the web, the hairline appears once the content scrolls under the header.
		.overlay(alignment: .bottom) {
			theme.border.frame(height: 1).opacity(contentScrolled ? 1 : 0)
				.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: contentScrolled)
		}
	}

	/// In an assigned thread the header shows the assignee's avatar and name in place of the workspace's, as on the web.
	private var headerAssignee: (title: String, image: String?)? {
		guard isShowingTranscript, showsModelThread, let assignee = model.assignee else { return nil }
		let name = assignee.name.trimmingCharacters(in: .whitespacesAndNewlines)
		return (name.isEmpty ? supportTeamText : name, assignee.image)
	}

	/// The workspace is still loading: its name keeps a placeholder instead of flashing the fallback title.
	private var brandingPending: Bool {
		let snapshot = model.client.snapshot
		return snapshot.workspace == nil && !snapshot.workspaceReady
			&& (model.reconnecting || (snapshot.status != .error && snapshot.error == nil))
	}

	private var nextLanguage: String { model.configuration.language == .ar ? "English" : "العربية" }
	private var languageLabel: String { localized("Language", "اللغة") + ": " + nextLanguage }

	/// Back from a thread returns where it was opened, from settings to Messages, from Messages to Home.
	private func goBack() {
		if isShowingTranscript {
			scopedNotification = nil
			model.clearNotificationNavigation()
			withAnimation(stepAnimation) {
				selectedConversation = nil
				composingNew = false
				space = transcriptOrigin
			}
		} else if isShowingSettings {
			withAnimation(stepAnimation) { showingSettings = false }
		} else {
			withAnimation(stepAnimation) { space = .home }
		}
	}

	private var organizationTitle: String {
		model.workspaceName.flatMap { $0.isEmpty ? nil : $0 } ?? localized("Support", "الدعم")
	}

	/// Opens a conversation's thread; Back returns to the space it was opened from.
	private func showConversation(_ id: String) {
		scopedNotification = nil
		model.clearNotificationNavigation()
		transcriptOrigin = space
		composingNew = false
		showingSettings = false
		selectedConversation = id
		space = .messages
	}

	@ViewBuilder private var content: some View {
		switch shownSpace {
		case .home:
			ScrollView {
				VStack(alignment: .leading, spacing: 0) {
					// The question gives way to the open conversation, as on the web.
					if model.client.snapshot.profile == nil || openConversation == nil {
						Text(localized("How can we help today?", "كيف نساعدك اليوم؟"))
							.rasheed(.hero)
							.foregroundStyle(theme.ink)
							.fixedSize(horizontal: false, vertical: true)
							// The web's 18ch measure, which breaks the English question over two lines, and its two-line
							// minimum, which keeps Home's controls in place in both languages.
							.frame(maxWidth: 10.8 * RasheedType.hero.size * min(typeScale, 1.8), alignment: .leading)
							.frame(minHeight: 64.8 * min(typeScale, 1.8), alignment: .topLeading)
							.accessibilityAddTraits(.isHeader)
							.padding(.horizontal, 20)
							.padding(.top, 36)
					}
					VStack(alignment: .leading, spacing: 24) {
						if model.client.snapshot.profile != nil {
							homeConversations
						}
						home
							.environment(\.rasheedStart, RasheedStartAction { [model] in model.requestStart() })
					}
					.padding(.horizontal, 20)
					.padding(.vertical, 24)
				}
				.frame(maxWidth: 600, alignment: .leading)
				.frame(maxWidth: .infinity)
			}
			.modifier(RasheedScrolledEdge(scrolled: $contentScrolled))
		case .messages:
			if isShowingTranscript {
				transcript
			} else if isShowingSettings {
				ScrollView {
					settings
						.padding(.horizontal, 24)
						.padding(.top, 16)
						.padding(.bottom, 24)
						.frame(maxWidth: 600, alignment: .leading)
						.frame(maxWidth: .infinity)
				}
				.modifier(RasheedScrolledEdge(scrolled: $contentScrolled))
			} else {
				conversationList
			}
		}
	}

	private var openConversation: RasheedSupportConversation? {
		model.conversations.first { $0.conversationStatus != "closed" }
	}

	/// Joined Home, as on the web: the open conversation's card, else New conversation; then up to two closed ones.
	@ViewBuilder private var homeConversations: some View {
		let rows = conversationRows
		if let current = rows.first(where: \.isOpen) {
			activeConversation(current)
		} else {
			newConversationButton
		}
		let closed = Array(rows.filter { !$0.isOpen }.prefix(2))
		if !closed.isEmpty {
			conversationRowList(closed)
		}
	}

	/// New conversation opens a local draft, or the draft not sent yet; nothing is created before its first send.
	private var newConversationButton: some View {
		RasheedPrimaryButton(title: newConversationText, identifier: "rasheed.start", chevron: true,
			disabled: !model.canStartConversation, theme: theme) { startConversation() }
	}

	/// The open conversation on Home, as on the web: its meta line, three lines of its latest message and Continue
	/// conversation, on the muted fill.
	private func activeConversation(_ row: ConversationRow) -> some View {
		let shape = RoundedRectangle(cornerRadius: RasheedRadius.card, style: .continuous)
		// The schedule only redraws each minute; its entry date is the minute's start, so the time reads the server's
		// clock instead.
		return TimelineView(.everyMinute) { _ in
			let now = model.client.serverNow
			Button {
				withAnimation(stepAnimation) { showConversation(row.id) }
			} label: {
				VStack(alignment: .leading, spacing: 12) {
					conversationMeta(row, now: now)
					Text(row.preview)
						.rasheed(.body, weight: row.unread > 0 ? .semibold : nil)
						.foregroundStyle(theme.ink)
						.lineLimit(3)
						.frame(maxWidth: .infinity, alignment: .leading)
						.environment(\.layoutDirection, Self.direction(of: row.preview) ?? interfaceDirection)
					HStack(spacing: 12) {
						Text(continueConversationText).rasheed(.control)
						Spacer(minLength: 0)
						Image(systemName: "chevron.forward").font(.system(size: 17, weight: .regular))
					}
					.foregroundStyle(theme.ink)
				}
				.padding(16)
				.background(theme.surfaceMuted, in: shape)
				.rasheedBorder(theme.ink.opacity(0.08), radius: RasheedRadius.card)
				.contentShape(shape)
			}
			.buttonStyle(RasheedCardStyle(theme: theme, radius: RasheedRadius.card))
			.accessibilityIdentifier("rasheed.conversation")
			.accessibilityLabel(rowLabel(row, now: now, action: continueConversationText))
		}
	}

	/// The web's meta line: Closed or Open and when, or who replied and when beside their initials. Unread replies
	/// turn it from muted to ink.
	private func conversationMeta(_ row: ConversationRow, now: Date) -> some View {
		HStack(spacing: 6) {
			if let name = row.replier {
				RasheedAvatar(name: name, size: 20, theme: theme)
			}
			Text(metaText(row, now: now))
				.rasheed(.meta)
				.lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
				.truncationMode(.tail)
		}
		.foregroundStyle(row.unread > 0 ? theme.ink : theme.muted)
		.frame(maxWidth: .infinity, alignment: .leading)
		.frame(minHeight: 20)
	}

	private func metaText(_ row: ConversationRow, now: Date) -> String {
		let state: String
		if let name = row.replier {
			state = localized("{name} replied", "رد من {name}").replacingOccurrences(of: "{name}", with: "\u{2068}\(name)\u{2069}")
		} else {
			state = row.isOpen ? localized("Open", "مفتوحة") : localized("Closed", "مغلقة")
		}
		return state + " · " + "\u{2068}" + RasheedClock.relative(row.updatedAt, language: model.configuration.language, now: now) + "\u{2069}"
	}

	/// What VoiceOver reads for a conversation: the meta line, the preview and any new replies.
	private func rowLabel(_ row: ConversationRow, now: Date, action: String? = nil) -> String {
		var parts = [metaText(row, now: now), row.preview, action].compactMap { $0 }
		if row.unread > 0 { parts.append(RasheedCount.newReplies.text(row.unread, language: model.configuration.language)) }
		return parts.joined(separator: listSeparator)
	}

	/// The Messages list, as on the web: its title with More, the conversations, then New conversation.
	private var conversationList: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 20) {
				HStack(spacing: 12) {
					Text(messagesTitle)
						.rasheed(.heading)
						.foregroundStyle(theme.ink)
						.accessibilityAddTraits(.isHeader)
					Spacer(minLength: 0)
					RasheedIconButton(systemName: "ellipsis", label: settingsTitle, identifier: "rasheed.settings",
						size: 17, weight: .medium, theme: theme) {
						withAnimation(stepAnimation) { showingSettings = true }
					}
				}
				.frame(minHeight: 44)
				let rows = conversationRows
				if rows.isEmpty && (model.loadingConversations || model.phase == .loading) {
					Text(loadingText)
						.rasheed(.sub)
						.foregroundStyle(theme.muted)
				} else if model.phase == .ready && rows.isEmpty {
					Text(localized("Your conversations will appear here.", "ستظهر محادثاتك هنا."))
						.rasheed(.sub)
						.foregroundStyle(theme.muted)
				}
				if !rows.isEmpty {
					conversationRowList(rows)
				}
				if !rows.isEmpty && model.loadingConversations {
					ProgressView().tint(theme.muted).frame(maxWidth: .infinity, minHeight: 44)
				} else if model.nextConversationCursor != nil {
					RasheedSecondaryButton(title: moreConversationsText, theme: theme) {
						Task { await model.loadConversations(more: true) }
					}
				}
				// Starting while a conversation is open would only reopen it; its row is already listed.
				if openConversation == nil {
					newConversationButton
				}
			}
			.padding(.horizontal, 24)
			.padding(.top, 16)
			.padding(.bottom, 24)
			.frame(maxWidth: 600, alignment: .leading)
			.frame(maxWidth: .infinity)
		}
		.modifier(RasheedScrolledEdge(scrolled: $contentScrolled))
	}

	private struct ConversationRow {
		let id: String
		let preview: String
		let isOpen: Bool
		let updatedAt: Int
		let unread: Int
		/// The teammate whose reply is the latest message of an open conversation.
		let replier: String?
	}

	private var conversationRows: [ConversationRow] {
		model.conversations.map { conversation in
			let isOpen = conversation.conversationStatus != "closed"
			return ConversationRow(
				id: conversation.conversationId,
				preview: conversation.lastMessagePreview.flatMap(Self.singleLine) ?? localized("No messages yet", "لا توجد رسائل بعد"),
				isOpen: isOpen,
				updatedAt: conversation.lastMessageAt ?? conversation.createdAt,
				unread: conversation.unread,
				replier: isOpen && conversation.lastMessageAuthorKind == "member"
					? conversation.lastAuthorName ?? supportTeamText : nil
			)
		}
	}

	/// A multi-line message keeps its words in a one-line preview.
	nonisolated static func singleLine(_ text: String) -> String? {
		let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }.joined(separator: " ")
		return line.isEmpty ? nil : line
	}

	/// Conversation rows divided by hairlines. Their times read again each minute while the list is on screen.
	private func conversationRowList(_ rows: [ConversationRow]) -> some View {
		TimelineView(.everyMinute) { _ in
			let now = model.client.serverNow
			// Up to a thousand conversations page in, so rows are built as they scroll into view.
			LazyVStack(spacing: 0) {
				ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
					conversationRow(row, now: now)
						.overlay(alignment: .top) {
							if index > 0 { theme.border.frame(height: 1) }
						}
				}
			}
		}
	}

	/// A conversation in a list, as on the web: its meta line, two lines of its latest message, a chevron.
	private func conversationRow(_ row: ConversationRow, now: Date) -> some View {
		Button {
			withAnimation(stepAnimation) { showConversation(row.id) }
		} label: {
			VStack(alignment: .leading, spacing: 5) {
				conversationMeta(row, now: now)
				Text(row.preview)
					.rasheed(.sub, weight: row.unread > 0 ? .semibold : nil)
					.foregroundStyle(theme.ink)
					.lineLimit(2)
					.frame(maxWidth: .infinity, alignment: .leading)
					.environment(\.layoutDirection, Self.direction(of: row.preview) ?? interfaceDirection)
			}
			.padding(.vertical, 14)
			.padding(.trailing, 28)
			.frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
			.overlay(alignment: .trailing) {
				Image(systemName: "chevron.forward")
					.font(.system(size: 17, weight: .regular))
					.foregroundStyle(theme.muted)
			}
			.contentShape(Rectangle())
		}
		.buttonStyle(RasheedRowStyle(theme: theme))
		.accessibilityIdentifier("rasheed.conversation")
		.accessibilityLabel(rowLabel(row, now: now))
	}

	@ViewBuilder private var transcript: some View {
		if showsModelThread {
			liveTranscript
		} else {
			// The thread is still being opened, or waits for the connection. It is unavailable once opening failed or
			// the session has no customer any more.
			VStack {
				if model.reconnecting || (model.connectionError == nil && model.client.snapshot.profile != nil) {
					Text(loadingText).rasheed(.sub).foregroundStyle(theme.muted)
				} else {
					Text(unavailableText).rasheed(.sub).foregroundStyle(theme.muted)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	/// The model holds the thread on screen: the conversation selected, or the new one being composed. That one keeps its
	/// thread, and the composer its focus, when its first send gives it an id, before the selection follows the id.
	private var showsModelThread: Bool {
		if composingNew, selectedConversation == nil { return model.isDraft || model.conversationId != nil }
		return selectedConversation != nil && selectedConversation == model.conversationId
	}

	/// The stored messages, then the contact's texts still on their way, which follow the latest messages, not older history.
	private var shownMessages: [RasheedSupportMessage] {
		model.outbox.isEmpty || model.browsingHistory ? model.messages : model.messages + model.outbox
	}

	private var failedIDs: [String] {
		model.outbox.filter { model.delivery(of: $0) == .failed }.map(\.id)
	}

	private var liveTranscript: some View {
		VStack(spacing: 0) {
			if shownMessages.isEmpty && !model.hasMoreHistory && !model.browsingHistory {
				draftHint
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
			} else {
			transcriptScroll(messages: shownMessages)
				.id(model.contentRevision)
				// Over the transcript's bottom edge, so showing it moves no row.
				.overlay(alignment: .bottom) {
					RasheedLatestControl(
						state: transcriptState,
						shown: !shownMessages.isEmpty || model.browsingHistory,
						browsingHistory: model.browsingHistory,
						theme: theme,
						title: jumpToLatestText,
						action: { showLatest() }
					)
				}
			}
			// A closed conversation hides the composer and offers the open one, else a new one, in its place.
			if model.isClosed {
				Group {
					if let open = openConversation, open.id != model.conversationId {
						RasheedPrimaryButton(title: continueConversationText, identifier: "rasheed.resume", chevron: true,
							theme: theme) {
							withAnimation(stepAnimation) { showConversation(open.id) }
						}
					} else {
						newConversationButton
					}
				}
				.padding(.horizontal, 16)
				.padding(.top, 8)
				.padding(.bottom, 12)
			} else {
				if let moved = model.movedConversationId {
					movedNotice(moved)
				}
				composer
					.task(id: focusComposerOnOpen && model.canCompose) {
						guard focusComposerOnOpen, model.canCompose else { return }
						focusComposerOnOpen = false
						composerFocused = true
					}
			}
		}
	}

	/// A send refused because another conversation is open, as on the web: the notice and the way there.
	private func movedNotice(_ id: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(localized("You already have an open conversation. Send your message there.",
				"لديك محادثة مفتوحة أخرى. أرسل رسالتك فيها."))
				.rasheed(.sub)
				.foregroundStyle(theme.muted)
				.fixedSize(horizontal: false, vertical: true)
			RasheedSecondaryButton(title: localized("Go to conversation", "الانتقال إلى المحادثة"),
				identifier: "rasheed.moved", theme: theme) {
				withAnimation(stepAnimation) { showConversation(id) }
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.horizontal, 16)
		.padding(.top, 8)
	}

	private func transcriptScroll(messages: [RasheedSupportMessage]) -> some View {
		followingScroll(messages: messages)
			.onAppear {
				newestOwnId = shownMessages.last(where: { $0.authorKind == "contact" })?.id
				transcriptState.follow.appear()
			}
			// An onChange action still sees the previous render's `messages`, so the newest message comes from the model.
			// The contact's own message counts even when a reply lands in the same update after it.
			.onChange(of: shownMessages.last?.id) { _ in
				guard !model.browsingHistory, !shownMessages.isEmpty else { return }
				let ownId = shownMessages.last(where: { $0.authorKind == "contact" })?.id
				let own = ownId != nil && ownId != newestOwnId
				newestOwnId = ownId
				transcriptState.follow.arrival(own: own)
			}
			.onChange(of: model.browsingHistory) { browsing in
				if !browsing { transcriptState.follow.appear() }
			}
			// A failed send stays in the thread with its Retry; follow the end so the Retry is in view.
			.onChange(of: failedIDs) { failed in
				guard !model.browsingHistory, failed.count > 0 else { return }
				transcriptState.follow.arrival(own: true)
			}
			.onChange(of: messages.first?.id) { _ in
				guard model.browsingHistory, let olderAnchor else { return }
				transcriptState.follow.leave(to: .message(olderAnchor, anchor: .top))
				self.olderAnchor = nil
			}
			.task(id: highlightedReplyTargetID) {
				guard let replyTargetID = highlightedReplyTargetID else { return }
				try? await Task.sleep(nanoseconds: 1_200_000_000)
				guard !Task.isCancelled, highlightedReplyTargetID == replyTargetID else { return }
				withAnimation(stepAnimation) {
					highlightedReplyTargetID = nil
				}
			}
	}

	@ViewBuilder private func followingScroll(messages: [RasheedSupportMessage]) -> some View {
		if #available(iOS 18.0, *) {
			RasheedFollowScroll(state: transcriptState, scrolled: $contentScrolled) {
				transcriptStack(messages: messages, measured: false)
			}
		} else {
			guardedScroll(messages: messages)
		}
	}

	/// iOS 16 and 17 report no scroll phase or scroll geometry, so the end is judged from the rows' reported frames.
	private func guardedScroll(messages: [RasheedSupportMessage]) -> some View {
		GeometryReader { viewport in
		ScrollViewReader { proxy in
			ScrollView {
				transcriptStack(messages: messages, measured: true)
			}
			.scrollDismissesKeyboard(.interactively)
			.coordinateSpace(name: "rasheed-transcript")
			.onPreferenceChange(RasheedTranscriptContentKey.self) { content in
				guard let content else { return }
				let resized = content.height != transcriptState.content.height
				transcriptState.content = content
				guardEnd(viewportHeight: viewport.size.height, resized: resized)
			}
			.onChange(of: viewport.size.height) { height in
				transcriptState.follow.viewportChanged()
				guardEnd(viewportHeight: height, resized: true)
			}
			.onPreferenceChange(RasheedTranscriptVisibilityKey.self) { visibility in
				transcriptState.latest = visibility
				guardEnd(viewportHeight: viewport.size.height, resized: false)
			}
			.background {
				RasheedFollowRequests(state: transcriptState) { request in
					withAnimation(request.animated ? .easeOut(duration: 0.18) : nil) {
						switch request.target {
						case .end:
							// The newest row's bottom stands in for the end: a scroll view reader has no scroll to its true end.
							if let newest = shownMessages.last?.id { proxy.scrollTo(newest, anchor: .bottom) }
						case .message(let id, let anchor):
							proxy.scrollTo(id, anchor: anchor.unitPoint)
						}
					}
				}
			}
		}
		}
	}

	private enum TranscriptItem: Identifiable {
		case day(id: String, text: String)
		case message(RasheedSupportMessage, grouped: Bool)
		case closed

		var id: String {
			switch self {
			case .day(let id, _): "day-\(id)"
			case .message(let message, _): message.id
			case .closed: "closed"
			}
		}
	}

	/// The rows with their day separators, the closed line and the grouping of one author's run: the second and later
	/// message of a run on one day drop their avatar and name. The closed line is the last row.
	private func transcriptItems(_ messages: [RasheedSupportMessage]) -> [TranscriptItem] {
		let language = model.configuration.language
		let calendar = Calendar.current
		func day(_ message: RasheedSupportMessage) -> Date {
			Date(timeIntervalSince1970: Double(message.createdAt) / 1_000)
		}
		var items: [TranscriptItem] = []
		var previous: RasheedSupportMessage?
		var lastDay: RasheedSupportMessage?
		for message in messages {
			let newDay = lastDay.map { !calendar.isDate(day($0), inSameDayAs: day(message)) } ?? true
			if newDay {
				items.append(.day(id: message.id, text: RasheedClock.date(message.createdAt, language: language)))
			}
			// An automated message stands alone: it joins no run and starts none.
			let grouped = !newDay && message.authorKind != "automation" && previous.map {
				$0.authorKind != "automation" && $0.authorKind == message.authorKind && $0.authorMemberId == message.authorMemberId
			} == true
			items.append(.message(message, grouped: grouped))
			previous = message
			lastDay = message
		}
		if model.isClosed { items.append(.closed) }
		return items
	}

	private func transcriptStack(
		messages: [RasheedSupportMessage],
		measured: Bool
	) -> some View {
		Group {
			// The recent messages are laid out in full. A lazy stack estimates the rows it hasn't measured, and a row far
			// taller than its estimate (a long text, a tall list, any row at the largest text sizes) kept its layout from
			// ever settling. Older history can run to hundreds of messages, so it stays lazy.
			if model.browsingHistory {
				LazyVStack(alignment: .leading, spacing: 0) {
					transcriptRows(messages: messages, measured: measured)
				}
			} else {
				VStack(alignment: .leading, spacing: 0) {
					transcriptRows(messages: messages, measured: measured)
				}
			}
		}
		.background {
			if measured {
				GeometryReader { content in
					Color.clear.preference(key: RasheedTranscriptContentKey.self,
						value: content.frame(in: .named("rasheed-transcript")))
				}
			}
		}
		.padding(.horizontal, 16)
		.padding(.top, 18)
		.padding(.bottom, 20)
	}

	@ViewBuilder private func transcriptRows(
		messages: [RasheedSupportMessage],
		measured: Bool
	) -> some View {
		if model.hasMoreHistory {
			Button(action: loadOlder) {
				HStack(spacing: 8) {
					Text(olderMessagesText).rasheed(.meta).foregroundStyle(theme.muted)
				if model.loadingOlder {
					ProgressView().controlSize(.small).tint(theme.muted)
				}
				}
				.frame(maxWidth: .infinity, minHeight: 44)
			}
			.buttonStyle(.plain)
			.disabled(model.loadingOlder)
			.modifier(RasheedTopSentinel(measured: measured) { olderCameIntoView() })
		}
		ForEach(transcriptItems(messages)) { item in
			switch item {
			case .day(_, let text):
				Text(text)
					.rasheed(.caption)
					.foregroundStyle(theme.muted)
					.frame(maxWidth: .infinity)
					.padding(.bottom, 24)
					.accessibilityAddTraits(.isHeader)
			case .closed:
				Text(closedText)
					.rasheed(.sub)
					.foregroundStyle(theme.muted)
					.frame(maxWidth: .infinity)
					.padding(.vertical, 12)
			case .message(let message, let grouped):
				let quoteSelectable = message.replyTo != nil && model.target != nil
				let signature = rowSignature(message, grouped: grouped, quoteSelectable: quoteSelectable)
				RasheedMemoRow(signature: signature) {
					messageRow(
						signature,
						onSelectReply: { replyID in
							Task {
								guard await model.revealMessage(replyID) else { return }
								withAnimation(stepAnimation) { highlightedReplyTargetID = replyID }
								transcriptState.follow.leave(to: .message(replyID, anchor: .center), animated: !reduceMotion)
							}
						}
					)
				}
				.equatable()
					.id(message.id)
					.background {
						if measured, message.id == messages.last?.id {
							GeometryReader { marker in
								Color.clear.preference(key: RasheedTranscriptVisibilityKey.self,
									value: RasheedTranscriptVisibility(conversationId: message.conversationId, cursor: message.cursor,
										bottom: marker.frame(in: .named("rasheed-transcript")).maxY))
							}
						}
					}
			}
		}
	}

	/// The top of the transcript came into view: load older history when the reader brought it there, not when the
	/// transcript merely opens at its end.
	private func olderCameIntoView() {
		guard !transcriptState.follow.following || transcriptState.follow.phase != .idle else { return }
		loadOlder()
	}

	private func loadOlder() {
		guard model.hasMoreHistory, !model.loadingOlder else { return }
		olderAnchor = model.messages.first?.id
		transcriptState.follow.leave()
		Task { _ = await model.loadOlder() }
	}

	/// The end counts as in view once the newest row's own bottom edge is: the stack's frame also carries estimates
	/// for rows not yet measured.
	private func guardEnd(viewportHeight: CGFloat, resized: Bool) {
		guard !model.browsingHistory, !shownMessages.isEmpty else { return }
		let atEnd = (transcriptState.latest?.bottom ?? transcriptState.content.maxY) <= viewportHeight + 2
		guard atEnd != transcriptState.follow.atEnd || (!atEnd && transcriptState.follow.following) else { return }
		transcriptState.follow.endChangedWithoutPhase(atEnd: atEnd, resized: resized)
	}

	/// Older history gives way to the latest messages; otherwise the transcript returns to its end and follows it.
	private func showLatest() {
		if model.browsingHistory {
			model.showLatest()
		} else {
			transcriptState.follow.showLatest(animated: !reduceMotion)
		}
	}

	/// The web's hint in an empty draft: one muted line, centred, 28 above the composer card. It goes with the first
	/// message, sent or still on its way.
	@ViewBuilder private var draftHint: some View {
		if model.isDraft {
			Text(localized("Send a message to start the conversation.", "أرسل رسالة لبدء المحادثة."))
				.rasheed(.meta)
				.foregroundStyle(theme.muted)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.frame(maxWidth: .infinity)
				.padding(.horizontal, 24)
				// The composer adds 8 above its card.
				.padding(.bottom, 20)
		}
	}

	private func authorName(_ message: RasheedSupportMessage) -> String {
		authorName(kind: message.authorKind, displayName: message.authorDisplayName)
	}

	/// The web's labels: the author's name; without one, the contact's own name or Guest, the support team (never an
	/// internal ID) or System.
	private func authorName(kind: String, displayName: String?) -> String {
		if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
		switch kind {
		case "contact": return contactName
		case "automation": return localized("System", "النظام")
		default: return supportTeamText
		}
	}

	private var contactName: String {
		let name = model.client.snapshot.profile?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return name.isEmpty ? localized("Guest", "ضيف") : name
	}

	/// Everything a message row draws from. A row whose signature is unchanged is not built again, so a keystroke, a
	/// scroll or a send leaves the other rows alone.
	private struct RowSignature: Equatable {
		let message: RasheedSupportMessage
		let grouped: Bool
		let dark: Bool
		let language: RasheedLanguage
		let reduceMotion: Bool
		/// The quote's text runs take their size from it; other text reads Dynamic Type itself.
		let typeScale: CGFloat
		let canReply: Bool
		let replyTarget: Bool
		let highlighted: Bool
		let quoteSelectable: Bool
		let attachments: [AttachmentState]
		let delivery: RasheedSupportModel.Delivery?
		let canRetry: Bool
		let failureReason: String?
		/// The fallback byline for the contact's own messages.
		let contactName: String
		/// A send whose outcome is unknown is being checked.
		let checking: Bool
	}

	private func rowSignature(_ message: RasheedSupportMessage, grouped: Bool, quoteSelectable: Bool) -> RowSignature {
		return RowSignature(
			message: message,
			grouped: grouped,
			dark: theme.isDark,
			language: model.configuration.language,
			reduceMotion: reduceMotion,
			typeScale: typeScale,
			canReply: canReply(message),
			replyTarget: model.replyTo?.id == message.id,
			highlighted: highlightedReplyTargetID == message.id,
			quoteSelectable: quoteSelectable,
			attachments: message.attachments.map {
				AttachmentState(failed: fileFailures.contains($0.id), thumbnailFailed: thumbnailFailures.contains($0.id),
					downloading: downloading.contains($0.id))
			},
			delivery: model.delivery(of: message),
			canRetry: model.canRetry(message.id),
			failureReason: model.failureReason(of: message),
			contactName: contactName,
			checking: model.delivery(of: message) == .uncertain
				&& (model.checkingSent || model.loadingThread || model.reconnecting)
		)
	}

	private func canReply(_ message: RasheedSupportMessage) -> Bool {
		message.conversationId == model.conversationId && model.canCompose && model.delivery(of: message) == nil
	}

	private func messageRow(
		_ signature: RowSignature,
		onSelectReply: @escaping (String) -> Void
	) -> some View {
		let message = signature.message
		let grouped = signature.grouped
		let quoteSelectable = signature.quoteSelectable
		let isAutomation = message.authorKind == "automation"
		let author = authorName(message)
		let canReply = signature.canReply
		let isReplyTarget = signature.replyTarget
		let isHighlightedReplyTarget = signature.highlighted
		let flashShape = RoundedRectangle(cornerRadius: RasheedRadius.control, style: .continuous)

		return Group {
			if isAutomation {
				automationColumn(signature, onSelectReply: onSelectReply)
			} else {
			HStack(alignment: .top, spacing: 12) {
				// A grouped message keeps the avatar's column but not its height.
				Group {
					if grouped { Color.clear } else {
						RasheedAvatar(name: author, size: 28, theme: theme)
					}
				}
				.frame(width: 28, height: grouped ? 0 : 28)

				VStack(alignment: .leading, spacing: 0) {
					if !grouped {
						HStack(alignment: .firstTextBaseline, spacing: 10) {
							Text(author)
								.rasheed(.meta, weight: .semibold)
								.foregroundStyle(theme.ink)
								.lineLimit(1)
								.truncationMode(.tail)
							Text(RasheedClock.time(message.createdAt, language: model.configuration.language))
								.rasheed(.caption)
								.foregroundStyle(theme.muted)
								.fixedSize(horizontal: true, vertical: false)
						}
						.frame(minHeight: 24, alignment: .topLeading)
						.accessibilityElement(children: .combine)
					}
					VStack(alignment: .leading, spacing: 6) {
						messageContent(signature, centred: false, onSelectReply: onSelectReply)
					}
					// Outside the spaced stack, so a text that goes out fast never moves its row.
					if let delivery = signature.delivery {
						// As on the web: a message that wasn't sent returns to the composer to edit. One whose outcome is
						// unknown may have arrived, so it is never sent again: Check reads the thread again.
						let uncertain = delivery == .uncertain
						RasheedDeliveryLabel(
							delivery: delivery,
							text: deliveryText(delivery),
							theme: theme,
							reason: signature.failureReason,
							retryTitle: retrySendTitle,
							secondaryTitle: !uncertain ? localized("Edit message", "تعديل الرسالة")
								: signature.checking ? loadingText
								: localized("Check for sent messages", "التحقق من الرسائل المرسلة"),
							secondaryIdentifier: uncertain ? "rasheed.check" : "rasheed.edit",
							secondaryDisabled: signature.checking,
							cancelTitle: localized("Cancel sending", "إيقاف الإرسال"),
							onRetry: signature.canRetry && !uncertain ? { model.retry(message.id) } : nil,
							onSecondary: uncertain ? { model.checkSent() } : {
								model.edit(message.id)
								composerFocused = true
							},
							onCancel: { model.cancelSend() }
						)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			// Rows sit 14 apart; a message continuing its author's run rises 8 into that gap, as on the web.
			.padding(.top, grouped ? -8 : 0)
			.padding(.bottom, 14)
			}
		}
		.contentShape(Rectangle())
		.accessibilityActions {
			if canReply {
				Button(replyTitle) { model.reply(to: message) }
			}
		}
		// The jump to a quoted message flashes it in both themes; the message being replied to keeps a quiet fill only
		// in dark, since in light message content sits on no fill and the quote bar already names it.
		.background {
			if isHighlightedReplyTarget {
				flashShape.fill(theme.ink.opacity(0.08))
			} else if isReplyTarget && theme.isDark {
				flashShape.fill(theme.ink.opacity(0.05))
			}
		}
		.contextMenu {
			if canReply {
				Button {
					model.reply(to: message)
				} label: {
					Label(replyTitle, systemImage: "arrowshape.turn.up.left")
				}
			}
			Button {
				UIPasteboard.general.string = message.body
			} label: {
				Label(localized("Copy message", "نسخ الرسالة"), systemImage: "doc.on.doc")
			}
			.disabled(message.body.isEmpty)
		}
		.transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
	}

	/// An automated message: no avatar, name or time, its content in a centred column. The question keeps its own
	/// writing direction and centres; attachments centre.
	private func automationColumn(
		_ signature: RowSignature,
		onSelectReply: @escaping (String) -> Void
	) -> some View {
		VStack(alignment: .center, spacing: 8) {
			messageContent(signature, centred: true, onSelectReply: onSelectReply)
		}
		.frame(maxWidth: 320)
		.frame(maxWidth: .infinity)
		.padding(.vertical, 12)
	}

	/// A message's quote, body and attachments. A `centred` (automated) message centres its body, and VoiceOver
	/// says it is automated before reading it.
	@ViewBuilder private func messageContent(
		_ signature: RowSignature,
		centred: Bool,
		onSelectReply: @escaping (String) -> Void
	) -> some View {
		let message = signature.message
		let quoteSelectable = signature.quoteSelectable
		if let reply = message.replyTo {
			quote(reply, canSelect: quoteSelectable) { onSelectReply(reply.id) }
		}
		if !message.body.isEmpty {
			Text(message.body)
				.rasheed(.body)
				// The web's 1.6 line height over Plex's 1.5.
				.lineSpacing(1.6 * min(signature.typeScale, 1.8))
				.foregroundStyle(theme.ink)
				.multilineTextAlignment(centred ? .center : .leading)
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
				// Each text reads in its own direction from its first letter, so a Latin message stays left to right in Arabic.
				.environment(\.layoutDirection, Self.direction(of: message.body) ?? interfaceDirection)
				.accessibilityLabel(centred ? automatedMessageText(message) + listSeparator + message.body : message.body)
		}
		// After the text, as on the web.
		attachmentViews(signature, centred: centred)
	}

	/// What VoiceOver says first on an automated message: that it is one, and when it came.
	private func automatedMessageText(_ message: RasheedSupportMessage) -> String {
		let time = RasheedClock.time(message.createdAt, language: model.configuration.language)
		return localized("Automated message, \(time)", "رسالة تلقائية، \(time)")
	}

	/// The message a reply answers, as on the web: its author and text, two lines at most, on the muted fill behind a
	/// 3-point bar at the start. A tap jumps to it. The box keeps its own height; the 44-point target reaches past it
	/// without moving the rows around it.
	private func quote(_ reply: RasheedSupportReply, canSelect: Bool, action: @escaping () -> Void) -> some View {
		let author = authorName(kind: reply.authorKind, displayName: reply.authorDisplayName)
		let arabic = model.configuration.language == .ar
		// The mark sets the line's direction, so the author leads in Arabic even when their name is Latin.
		var preview = Text(directionMark) + Text(author)
			.font(RasheedType.caption.font(scale: typeScale, weight: .medium, arabic: arabic))
		if !reply.body.isEmpty {
			preview = preview + Text(" · " + reply.body)
				.font(RasheedType.caption.font(scale: typeScale, arabic: arabic))
		}
		return Button(action: action) {
			preview
				.foregroundStyle(theme.ink)
				.lineLimit(2)
				.truncationMode(.tail)
				.multilineTextAlignment(.leading)
				.padding(.vertical, 8)
				.padding(.horizontal, 10)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(theme.surfaceMuted)
				.overlay(alignment: .leading) { theme.accent.frame(width: 3) }
				.padding(.vertical, 5)
				.contentShape(Rectangle())
		}
		.buttonStyle(RasheedPressStyle(scale: 0.98))
		.disabled(!canSelect)
		.accessibilityHint(canSelect ? localized("Go to original message", "الانتقال إلى الرسالة الأصلية") : "")
		.padding(.vertical, -5)
	}

	// MARK: Attachments

	/// What an attachment's row shows: its download failed, its thumbnail failed, or a download is under way.
	private struct AttachmentState: Equatable {
		let failed: Bool
		let thumbnailFailed: Bool
		let downloading: Bool
	}

	/// Each attachment as the web's file row. An image small enough shows its thumbnail above its row, except an
	/// animated GIF under Reduce Motion.
	@ViewBuilder private func attachmentViews(_ signature: RowSignature, centred: Bool) -> some View {
		ForEach(Array(zip(signature.message.attachments, signature.attachments)), id: \.0.id) { attachment, state in
			let thumbnail = attachment.hasLiveThumbnail && !state.thumbnailFailed
				&& !(signature.reduceMotion && attachment.mimeType == "image/gif")
			VStack(alignment: centred ? .center : .leading, spacing: 6) {
				if thumbnail {
					Button { openMedia(attachment) } label: {
						RasheedThumbnail(attachment: attachment, model: model, theme: theme) {
							thumbnailFailures.insert(attachment.id)
							fileFailures.insert(attachment.id)
						}
					}
					.buttonStyle(RasheedPressStyle(scale: 0.98))
					.accessibilityLabel(previewTitle + ": " + attachment.fileName)
				}
				RasheedFileRow(name: attachment.fileName, kind: attachment.kind,
					meta: state.failed ? fileFailedText : rasheedFileMeta(name: attachment.fileName,
						byteLength: attachment.byteLength, language: model.configuration.language),
					failed: state.failed, theme: theme) {
					if !thumbnail {
						RasheedIconButton(systemName: attachment.kind == .video || attachment.kind == .audio ? "play" : "eye",
							label: previewTitle + ": " + attachment.fileName, size: 15, theme: theme) { openMedia(attachment) }
					}
					RasheedIconButton(systemName: "square.and.arrow.down", label: downloadTitle + ": " + attachment.fileName,
						size: 15, theme: theme) { download(attachment) }
						.disabled(state.downloading)
				}
				.frame(maxWidth: 320)
			}
			.frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
		}
	}

	private func openMedia(_ attachment: RasheedSupportAttachment) {
		var sources: [String: RasheedMediaSource] = [:]
		for message in shownMessages {
			for item in message.attachments {
				sources[item.id] = RasheedMediaSource(author: authorName(message), createdAt: message.createdAt)
			}
		}
		// The media as they are now, also for a row kept from an earlier update.
		let media = liveMedia
		guard let index = media.firstIndex(where: { $0.id == attachment.id }) else { return }
		viewerContext = RasheedMediaViewerContext(attachments: media, index: index, sources: sources)
	}

	/// Download hands the private file to the share sheet, to save to Files or Photos. A failure shows on the row
	/// until a download or preview succeeds.
	private func download(_ attachment: RasheedSupportAttachment) {
		guard !downloading.contains(attachment.id) else { return }
		downloading.insert(attachment.id)
		let revision = model.contentRevision
		Task {
			defer { downloading.remove(attachment.id) }
			do {
				let file = try await model.download(attachment)
				guard model.contentRevision == revision else { return }
				fileFailures.remove(attachment.id)
				sharedFile = RasheedSharedFile(file: file)
			} catch {
				guard model.contentRevision == revision, !(error is CancellationError),
					(error as? RasheedClientError) != .Canceled else { return }
				fileFailures.insert(attachment.id)
			}
		}
	}

	private func spinnerAnimation(_ sending: Bool) -> Animation? {
		if sending { return (reduceMotion ? Animation.linear(duration: 0) : .easeOut(duration: 0.15)).delay(0.4) }
		return reduceMotion ? nil : .easeOut(duration: 0.12)
	}

	private var composing: Bool { model.canCompose }

	/// The composer holds something it may send once no send or file is in progress.
	private var sendReady: Bool {
		composing
			&& !model.hasPendingSend
			&& (!model.pendingAttachments.isEmpty
				|| !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
	}

	// MARK: Composer

	/// The web's reply preview at the top of the composer card: "Replying to {name}" over up to three lines of the
	/// quote, on the muted fill behind a 3-point bar, with Cancel reply beside it. VoiceOver reads the whole quote.
	@ViewBuilder private var replyPreview: some View {
		if let reply = model.replyTo {
			let name = authorName(kind: reply.authorKind, displayName: reply.authorDisplayName)
			let title = localized("Replying to {name}", "الرد على {name}")
				.replacingOccurrences(of: "{name}", with: "\u{2068}\(name)\u{2069}")
			HStack(alignment: .top, spacing: 4) {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.rasheed(.caption, weight: .semibold)
						.foregroundStyle(theme.ink)
						.lineLimit(1)
						.truncationMode(.tail)
					if !reply.body.isEmpty {
						Text(reply.body)
							.rasheed(.caption)
							.foregroundStyle(theme.muted)
							.lineLimit(3)
							.truncationMode(.tail)
							.fixedSize(horizontal: false, vertical: true)
							.frame(maxWidth: .infinity, alignment: .leading)
							.environment(\.layoutDirection, Self.direction(of: reply.body) ?? interfaceDirection)
					}
				}
				.padding(.horizontal, 10)
				.padding(.vertical, 8)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(theme.surfaceMuted)
				.overlay(alignment: .leading) { theme.accent.frame(width: 3) }
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(reply.body.isEmpty ? title : title + listSeparator + reply.body)
				RasheedIconButton(systemName: "xmark", label: cancelReplyTitle, size: 14, theme: theme) {
					model.replyTo = nil
				}
			}
			.padding(4)
		}
	}

	private var composer: some View {
		composerBox
			.padding(.horizontal, 12)
			.padding(.top, 8)
			.padding(.bottom, 12)
	}

	/// One box: the staged files in a single scrolling line, the auto-growing field, then attach, a counter near the
	/// limit and Send.
	private var composerBox: some View {
		VStack(spacing: 0) {
			replyPreview
			stagedFiles
			// The field stays enabled through a send and an outage, so it keeps its focus, the keyboard stays up and the
			// transcript doesn't move; the model keeps what is typed meanwhile.
			composerField(
				text: Binding(
					get: { model.draft },
					set: { text in
						let limited = Self.limited(text, toUTF16: Self.messageLimit)
						composerWithoutTab = Self.typedTabRemoved(from: limited, old: model.draft)
						model.draft = limited
					}
				),
				placeholder: placeholderText,
				enabled: model.canType
			)
			// Tab leaves the composer. Its tab character was stored for one update, so the field shows the text
			// without it.
			.onChange(of: model.draft) { _ in
				guard let kept = composerWithoutTab else { return }
				composerWithoutTab = nil
				model.draft = kept
				composerFocused = false
			}
			HStack(spacing: 4) {
				attachMenu
				Spacer(minLength: 0)
				if let remaining = counterText {
					Text(remaining)
						.rasheed(.mono)
						.monospacedDigit()
						.foregroundStyle(model.draft.utf16.count >= Self.messageLimit ? theme.danger : theme.muted)
						.padding(.horizontal, 4)
						.environment(\.layoutDirection, .leftToRight)
				}
				composerSendButton(
					ready: sendReady,
					preparing: model.preparingAttachment
				) {
					Task { await model.send() }
				}
			}
		}
		.padding(RasheedRadius.chip)
		.rasheedField(focused: composerFocused, radius: RasheedRadius.composer, theme: theme)
	}

	/// The characters left once the text comes within an eighth of its limit, counted as the server counts them.
	private var counterText: String? {
		let used = model.draft.utf16.count
		let limit = Self.messageLimit
		guard used > 0, limit - used <= limit / 8 else { return nil }
		return formattedNumber(limit - used)
	}

	/// The text cut to at most `limit` UTF-16 code units, at a character boundary.
	nonisolated static func limited(_ text: String, toUTF16 limit: Int) -> String {
		guard text.utf16.count > limit else { return text }
		var used = 0
		var kept = ""
		for character in text {
			used += character.utf16.count
			guard used <= limit else { break }
			kept.append(character)
		}
		return kept
	}

	private var attachMenu: some View {
		let disabled = !model.canCompose || model.hasPendingSend || model.preparingAttachment
			|| model.pendingAttachments.count >= RasheedAttachmentFile.maximumCount
		return Menu {
			Button {
				fileTarget = model.target
				choosingPhoto = true
			} label: {
				Label(attachTitle, systemImage: "photo")
			}
			Button {
				fileTarget = model.target
				importingFile = true
			} label: { Label(localized("Add file", "إضافة ملف"), systemImage: "doc") }
		} label: {
			Image(systemName: "paperclip")
				.font(.system(size: 19, weight: .regular))
				.foregroundStyle(theme.muted)
				.frame(width: 44, height: 44)
				.contentShape(Rectangle())
				.opacity(disabled ? 0.4 : 1)
		}
		.buttonStyle(RasheedPressStyle(radius: 22))
		.disabled(disabled)
		.accessibilityLabel(localized("Attach files", "إرفاق ملفات"))
	}

	/// The staged files as the web's file rows, each with Remove, in a list that scrolls past 144 points.
	@ViewBuilder private var stagedFiles: some View {
		if !model.pendingAttachments.isEmpty {
			ScrollViewReader { proxy in
				ScrollView {
					VStack(spacing: 6) {
						ForEach(model.pendingAttachments) { file in
							RasheedFileRow(name: file.file.fileName, kind: file.file.kind, meta: stagedMeta(file),
								failed: file.failed, theme: theme) {
								RasheedIconButton(systemName: "xmark", label: removeAttachmentTitle + ": " + file.file.fileName,
									size: 14, theme: theme) { model.removeAttachment(file.id) }
							}
							.id(file.id)
						}
					}
					.padding(.horizontal, 4)
					.padding(.top, 4)
					.padding(.bottom, 6)
					.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stagedHeight = $0 }
				}
				.scrollBounceBehavior(.basedOnSize)
				.frame(height: min(stagedHeight, 144))
				.onChange(of: model.pendingAttachments.last?.id) { _, id in
					guard let id else { return }
					withAnimation(stepAnimation) { proxy.scrollTo(id, anchor: .bottom) }
				}
			}
		}
	}

	private func stagedMeta(_ file: RasheedPendingAttachment) -> String {
		if file.failed { return localized("Couldn’t upload this file. Your draft is kept.", "تعذّر رفع الملف. مسودتك محفوظة.") }
		if file.uploading { return localized("Uploading…", "جارٍ الرفع…") }
		return rasheedFileMeta(name: file.file.fileName, byteLength: file.file.byteLength, language: model.configuration.language)
	}

	private func composerField(
		text: Binding<String>,
		placeholder: String,
		enabled: Bool
	) -> some View {
		TextField(text: text, prompt: Text(placeholder).foregroundColor(theme.muted), axis: .vertical) { Text(placeholder) }
			.lineLimit(1...8)
			.focused($composerFocused)
			.rasheed(.body)
			.textFieldStyle(.plain)
			.foregroundStyle(theme.ink)
			.tint(theme.ink)
			.padding(.horizontal, 10)
			.padding(.top, 10)
			.padding(.bottom, 6)
			.frame(minHeight: 48, alignment: .topLeading)
			// The field draws one line; a tap on the box's padding around it also puts the cursor in it.
			.background {
				Color.clear
					.contentShape(Rectangle())
					.onTapGesture { if enabled { composerFocused = true } }
					.accessibilityHidden(true)
			}
			.disabled(!enabled)
			.accessibilityIdentifier("rasheed.composer")
	}

	private func composerSendButton(ready: Bool, preparing: Bool, action: @escaping () -> Void) -> some View {
		let enabled = ready && !preparing
		return Button(action: action) {
			ZStack {
				Circle().fill(theme.surfaceMuted)
				Circle()
					.fill(theme.accent)
					.opacity(enabled ? 1 : 0)
					.animation(spinnerAnimation(preparing), value: preparing)
				Image(systemName: "arrow.up")
					.font(.system(size: 17, weight: .medium))
					.foregroundStyle(enabled ? theme.onAccent : theme.muted)
					.opacity(preparing ? 0 : 1)
					.animation(spinnerAnimation(preparing), value: preparing)
				ZStack {
					if preparing {
						ProgressView()
							.controlSize(.small)
							.tint(theme.muted)
							.transition(.opacity)
					}
				}
				.animation(spinnerAnimation(preparing), value: preparing)
			}
			.frame(width: 44, height: 44)
			.contentShape(Circle())
		}
		.buttonStyle(RasheedPressStyle(radius: 22))
		.disabled(!enabled)
		.accessibilityLabel(sendTitle)
		.accessibilityValue(preparing ? localized("Preparing attachments…", "جارٍ تجهيز المرفقات…") : "")
		.accessibilityIdentifier("rasheed.send")
	}

	// MARK: Tabs

	/// The web's two text tabs under a hairline; the current one takes the muted fill.
	private var tabBar: some View {
		HStack(spacing: 8) {
			tabButton(.home, title: homeTitle)
				.accessibilityIdentifier("rasheed.tab.home")
			tabButton(.messages, title: messagesTitle)
				.accessibilityIdentifier("rasheed.tab.messages")
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 8)
		.overlay(alignment: .top) { theme.border.frame(height: 1) }
	}

	private func tabButton(_ target: RasheedSupportSpace, title: String) -> some View {
		let selected = shownSpace == target
		return Button {
			guard space != target else { return }
			withAnimation(stepAnimation) {
				space = target
			}
		} label: {
			Text(title)
				.rasheed(.control)
				.foregroundStyle(selected ? theme.ink : theme.muted)
				.padding(.horizontal, 6)
				.frame(maxWidth: .infinity, minHeight: 44)
				.background(selected ? theme.surfaceMuted : .clear,
					in: RoundedRectangle(cornerRadius: RasheedRadius.control, style: .continuous))
				.contentShape(Rectangle())
		}
		.buttonStyle(RasheedPressStyle())
		.accessibilityAddTraits(selected ? .isSelected : [])
	}

	/// The text without the tab character just typed into it, when that tab is the whole edit. On a hardware keyboard
	/// Tab and Shift+Tab type a tab into a multi-line field, where they move on from a single-line one: the composer
	/// removes the tab and gives up its focus. A paste keeps its tabs.
	nonisolated static func typedTabRemoved(from text: String, old: String) -> String? {
		guard text.count == old.count + 1 else { return nil }
		let offset = zip(old, text).prefix { $0 == $1 }.count
		var kept = text
		guard kept.remove(at: kept.index(kept.startIndex, offsetBy: offset)) == "\t", kept == old else { return nil }
		return kept
	}

	private func startConversation(focusComposer: Bool = false) {
		scopedNotification = nil
		model.clearNotificationNavigation()
		let origin = space
		Task {
			guard await model.startConversation() else { return }
			transcriptOrigin = origin
			selectedConversation = model.conversationId
			composingNew = model.isDraft
			showingSettings = false
			focusComposerOnOpen = focusComposer
			space = .messages
		}
	}

	@ViewBuilder private var failureBanner: some View {
		if model.pushError != nil || model.pushStatus == .outcomeUnknown {
			errorBanner(localized("Notification settings could not be confirmed.", "تعذّر تأكيد إعدادات الإشعارات."),
				action: model.pushSnapshot.canRetry ? {
					guard !retryingPush else { return }
					retryingPush = true
					Task {
						defer { retryingPush = false }
						do { try await model.retryPushRegistration() }
						catch { /* The core snapshot retains the retryable failure. */ }
					}
				} : nil)
				.disabled(retryingPush)
		}
		if let pending = model.inboxSnapshot.pendingSend, pending.state != .confirmed, pending.target != model.target {
			errorBanner(localized("A message is pending in another conversation.", "توجد رسالة معلّقة في محادثة أخرى."),
				actionTitle: localized("View message", "عرض الرسالة")) {
				model.open(space: .messages, conversationId: pending.target.conversationId)
			}
		}
		if let error = model.attachmentError {
			errorBanner((error as? RasheedSupportError) == .attachmentLimit
				? localized("Choose up to 10 files, 50 MB in total.", "اختر حتى 10 ملفات بحجم إجمالي لا يتجاوز 50 ميغابايت.")
				: localized("Couldn’t load the attachment. Choose the file again.", "تعذّر تحميل المرفق. اختر الملف مجددًا."),
				actionTitle: localized("Dismiss", "إغلاق")) { model.clearAttachmentError() }
		}
		// A send's own row shows its state; the banner is for a send that never got one.
		if let error = model.sendError, model.outbox.isEmpty,
			model.inboxSnapshot.pendingSend.map({ $0.state == .confirmed }) ?? true {
			errorBanner(sendErrorText(error), actionTitle: localized("Dismiss", "إغلاق")) { model.clearSendError() }
		}
		if model.discardError != nil {
			errorBanner(localized("Couldn’t remove this attachment.", "تعذّرت إزالة المرفق.")) { Task { await model.retryDiscardedUploads() } }
		}
		if model.connectionError != nil {
			errorBanner(connectionFailedText) { Task { await startVisibleConversation() } }
		}
	}

	/// A failure: what went wrong and the one action for it, in a row, or what went wrong alone when nothing here can
	/// fix it. Codes and statuses stay on the model's error values for the host app.
	private func errorBanner(_ title: String, actionTitle: String? = nil, action: (() -> Void)?) -> some View {
		HStack(alignment: .center, spacing: 8) {
			Circle().fill(theme.danger).frame(width: 6, height: 6)
				.accessibilityHidden(true)
			Text(title)
				.rasheed(.meta)
				.foregroundStyle(theme.ink)
			Spacer(minLength: 8)
			if let action {
				Button(action: action) {
					Text(actionTitle ?? retryTitle)
						.rasheed(.meta, weight: .semibold)
						.foregroundStyle(theme.ink)
						.frame(minWidth: 44, minHeight: 44)
						.contentShape(Rectangle())
				}
				.buttonStyle(.plain)
			}
		}
		.frame(minHeight: 44)
		.padding(.horizontal, 16)
		.onAppear { UIAccessibility.post(notification: .announcement, argument: title) }
	}

	private func localized(_ en: String, _ ar: String) -> String {
		model.configuration.language == .ar ? ar : en
	}

	private var interfaceDirection: LayoutDirection { model.configuration.language == .ar ? .rightToLeft : .leftToRight }

	/// A text's own writing direction from its first letter; nil without letters.
	nonisolated static func direction(of text: String) -> LayoutDirection? {
		text.unicodeScalars.first { $0.properties.isAlphabetic }.map { (0x0590 ... 0x08FF).contains($0.value) ? .rightToLeft : .leftToRight }
	}

	/// A strong mark of the interface's direction, for a line that starts with text of either script.
	private var directionMark: String { model.configuration.language == .ar ? "\u{200F}" : "\u{200E}" }

	private var replyTitle: String { localized("Reply", "الرد") }
	private var cancelReplyTitle: String { localized("Cancel reply", "إلغاء الرد") }
	private var retryTitle: String { localized("Try again", "إعادة المحاولة") }
	private var retrySendTitle: String { localized("Retry sending", "إعادة الإرسال") }
	private func sendErrorText(_ error: Error) -> String {
		if case .unavailable(let message)? = error as? RasheedSupportError { return message }
		return sendFailedText
	}

	private var sendFailedText: String { localized("Message not confirmed. Your draft is saved.", "لم يُؤكَّد إرسال الرسالة. مسودتك محفوظة.") }
	private var connectionFailedText: String { localized("Couldn’t update your messages.", "تعذّر تحديث الرسائل.") }
	private var olderMessagesText: String { localized("Load older messages", "تحميل الرسائل السابقة") }
	private var jumpToLatestText: String { localized("Jump to latest", "الانتقال إلى أحدث رسالة") }
	private var moreConversationsText: String { localized("More conversations", "المزيد من المحادثات") }
	private var closeTitle: String { localized("Close support", "إغلاق الدعم") }
	private var backTitle: String {
		if isShowingTranscript && transcriptOrigin == .home { return localized("Back to home", "العودة إلى الرئيسية") }
		if isShowingTranscript || isShowingSettings { return localized("Back to messages", "العودة إلى الرسائل") }
		return homeTitle
	}
	private var sendTitle: String { localized("Send", "إرسال") }
	private var homeTitle: String { localized("Home", "الرئيسية") }
	private var messagesTitle: String { localized("Messages", "الرسائل") }
	private var settingsTitle: String { localized("Support settings", "إعدادات الدعم") }
	private var placeholderText: String { localized("Write a message…", "اكتب رسالة…") }
	private var loadingText: String { localized("Loading…", "جارٍ التحميل…") }
	private var unavailableText: String { localized("This conversation is unavailable.", "هذه المحادثة غير متاحة.") }
	private var continueConversationText: String { localized("Continue conversation", "متابعة المحادثة") }
	private var supportTeamText: String { localized("Support team", "فريق الدعم") }
	private var previewTitle: String { localized("Preview", "معاينة") }
	private var downloadTitle: String { localized("Download attachment", "تنزيل المرفق") }
	private var fileFailedText: String { localized("Couldn’t download this file. Try again.", "تعذّر تنزيل الملف. أعد المحاولة.") }
	private var closedText: String { localized("Conversation closed", "أُغلقت المحادثة") }
	private var newConversationText: String { localized("New conversation", "محادثة جديدة") }
	private var attachTitle: String { localized("Add photo", "إضافة صورة") }
	private var removeAttachmentTitle: String { localized("Remove attachment", "إزالة المرفق") }
	private var sendingText: String { localized("Sending…", "جارٍ الإرسال…") }
	private var listSeparator: String { localized(", ", "، ") }
	// A bare "ar" locale takes its digits from the OS's CLDR data, which moved from Arabic-Indic to Latin; pin Latin like the rest of the SDK.
	private func formattedNumber(_ value: Int) -> String {
		value.formatted(.number.locale(RasheedClock.locale(model.configuration.language)))
	}

	private func deliveryText(_ delivery: RasheedSupportModel.Delivery) -> String {
		switch delivery {
		case .sending: sendingText
		case .failed: localized("Not sent", "لم تُرسل")
		case .uncertain: localized("Not confirmed. Check before sending again.", "لم يُؤكَّد الإرسال. تحقّق قبل الإرسال مجددًا.")
		case .canceled: localized("Sending stopped", "أُوقف الإرسال")
		}
	}

}

/// Calls `onVisible` when the transcript's top row scrolls into view: from iOS 18 by scroll visibility, before that by
/// the row's frame in the transcript's coordinate space. A plain onAppear fires for every row of the eager stack the
/// moment the transcript opens, so it can't say when the top is in view.
private struct RasheedTopSentinel: ViewModifier {
	let measured: Bool
	let onVisible: () -> Void

	func body(content: Content) -> some View {
		if #available(iOS 18.0, *), !measured {
			content.onScrollVisibilityChange(threshold: 0.01) { visible in
				if visible { onVisible() }
			}
		} else {
			content.background {
				GeometryReader { geometry in
					let visible = geometry.frame(in: .named("rasheed-transcript")).maxY > 0
					Color.clear
						.onAppear { if visible { onVisible() } }
						.onChange(of: visible) { visible in if visible { onVisible() } }
				}
			}
		}
	}
}

/// A row built only when its signature changes: SwiftUI compares the signatures and skips the content otherwise.
private struct RasheedMemoRow<Signature: Equatable, Content: View>: View, Equatable {
	let signature: Signature
	@ViewBuilder let content: () -> Content

	var body: some View { content() }

	static func == (lhs: Self, rhs: Self) -> Bool { lhs.signature == rhs.signature }
}

/// The transcript's scroll view from iOS 18. Its scroll phase says when a finger moves it and its geometry says when
/// its end is in view; a scroll position carries out the follower's requests. While following, a size change keeps
/// the end where it is; otherwise it keeps the rows the reader is looking at. It observes the follower itself, so a
/// phase change redraws this view and not the rows it holds.
@available(iOS 18.0, *)
private struct RasheedFollowScroll<Content: View>: View {
	@ObservedObject private var state: RasheedTranscriptState
	@State private var position = ScrollPosition(idType: String.self, edge: .bottom)
	@Binding private var scrolled: Bool
	private let content: Content

	init(state: RasheedTranscriptState, scrolled: Binding<Bool>, @ViewBuilder content: () -> Content) {
		self.state = state
		_scrolled = scrolled
		self.content = content()
	}

	var body: some View {
		ScrollView { content }
			.modifier(RasheedScrolledEdge(scrolled: $scrolled))
			.scrollDismissesKeyboard(.interactively)
			.scrollPosition($position)
			.defaultScrollAnchor(.bottom, for: .initialOffset)
			.defaultScrollAnchor(state.follow.following ? UnitPoint.bottom : UnitPoint.top, for: .sizeChanges)
			.onScrollPhaseChange { _, phase in
				state.follow.phaseChanged(to: RasheedFollow.Phase(phase))
			}
			// Reported on change only: scrolling alone changes neither value until the end comes into view or leaves it.
			.onScrollGeometryChange(for: RasheedScrollEnd.self) { geometry in
				RasheedScrollEnd(
					atEnd: RasheedFollow.isAtEnd(distance: geometry.contentSize.height + geometry.contentInsets.bottom
						- geometry.containerSize.height - geometry.contentOffset.y),
					viewportHeight: geometry.containerSize.height
				)
			} action: { old, new in
				if new.viewportHeight != old.viewportHeight { state.follow.viewportChanged() }
				state.follow.endChanged(atEnd: new.atEnd)
			}
			.onChange(of: state.follow.request) { _, request in
				guard let request else { return }
				withAnimation(request.animated ? .easeOut(duration: 0.18) : nil) {
					switch request.target {
					case .end:
						position.scrollTo(edge: .bottom)
					case .message(let id, let anchor):
						position.scrollTo(id: id, anchor: anchor.unitPoint)
					}
				}
			}
	}
}

/// The follower and what the transcript measured, by reference. Only the follower is published, and only the views
/// that draw from it observe it: the scroll view, the latest control and the iOS 16 and 17 request runner.
private final class RasheedTranscriptState: ObservableObject {
	@Published var follow = RasheedFollow()
	/// The transcript's rows in its viewport's coordinates, which place the newest row against the bottom edge (iOS 16
	/// and 17). Read when the end is judged, never drawn, so not published.
	var content: CGRect = .zero
	var latest: RasheedTranscriptVisibility?
}

/// Carries out the follower's requests on iOS 16 and 17, where a scroll view reader does the scrolling.
private struct RasheedFollowRequests: View {
	@ObservedObject var state: RasheedTranscriptState
	let perform: (RasheedFollow.Request) -> Void

	var body: some View {
		Color.clear
			.accessibilityHidden(true)
			.onChange(of: state.follow.request) { request in
				if let request { perform(request) }
			}
	}
}

/// Whether the transcript's end is in view, and the viewport's height: the keyboard, the composer and the banners change
/// it, and each change earns the follower fresh scrolls to the end.
private struct RasheedScrollEnd: Equatable {
	let atEnd: Bool
	let viewportHeight: CGFloat
}

@available(iOS 18.0, *)
private extension RasheedFollow.Phase {
	init(_ phase: ScrollPhase) {
		switch phase {
		case .idle: self = .idle
		case .tracking: self = .touching
		case .interacting: self = .dragging
		case .decelerating, .animating: self = .settling
		}
	}
}

private extension RasheedFollow.Anchor {
	var unitPoint: UnitPoint {
		switch self {
		case .top: .top
		case .center: .center
		case .bottom: .bottom
		}
	}
}

/// A frozen send's delivery state and its explicit actions, as on the web: the state's icon and caption, then bordered
/// actions. Sending shows only after a second, so a send that settles sooner stays silent.
private struct RasheedDeliveryLabel: View {
	let delivery: RasheedSupportModel.Delivery
	let text: String
	let theme: RasheedSupportTheme
	var reason: String?
	var retryTitle = ""
	var secondaryTitle = ""
	var secondaryIdentifier = ""
	var secondaryDisabled = false
	var cancelTitle = ""
	var onRetry: (() -> Void)?
	var onSecondary: (() -> Void)?
	var onCancel: (() -> Void)?
	@State private var slow = false

	private var shown: Bool { delivery != .sending || slow }

	private var symbol: String? {
		switch delivery {
		case .sending: "clock"
		case .failed: "exclamationmark.triangle"
		case .uncertain: "questionmark.circle"
		case .canceled: nil
		}
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				if let symbol {
					Image(systemName: symbol).font(.system(size: 12, weight: .regular))
				}
				Text(text).rasheed(.meta)
			}
			.foregroundStyle(delivery == .failed ? theme.danger : theme.muted)
			.accessibilityElement(children: .combine)
			.accessibilityHint(delivery == .failed ? reason ?? "" : "")
			// A message that wasn't sent waits for the person: it is never sent again on its own.
			ViewThatFits(in: .horizontal) {
				HStack(spacing: 4) { actions }
				VStack(alignment: .leading, spacing: 4) { actions }
			}
		}
		.padding(.top, 6)
		.frame(height: shown ? nil : 0, alignment: .top)
		.clipped()
		.opacity(shown ? 1 : 0)
		.accessibilityHidden(!shown)
		.task(id: delivery) {
			guard delivery == .sending, !slow else { return }
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			if !Task.isCancelled { slow = true }
		}
		.onChange(of: delivery) { _, delivery in
			if delivery == .failed || delivery == .uncertain {
				UIAccessibility.post(notification: .announcement, argument: text)
			}
		}
	}

	@ViewBuilder private var actions: some View {
		if delivery == .sending {
			if let onCancel { action(cancelTitle, identifier: "rasheed.cancel", onCancel) }
		} else {
			if let onRetry { action(retryTitle, identifier: "rasheed.retry", onRetry) }
			if let onSecondary {
				action(secondaryTitle, identifier: secondaryIdentifier, disabled: secondaryDisabled, onSecondary)
			}
		}
	}

	/// The web's recovery action: bordered on the panel; while busy, the muted fill.
	private func action(_ title: String, identifier: String, disabled: Bool = false,
		_ perform: @escaping () -> Void) -> some View {
		let shape = RoundedRectangle(cornerRadius: RasheedRadius.control, style: .continuous)
		return Button(action: perform) {
			Text(title)
				.rasheed(.meta, weight: .medium)
				.foregroundStyle(disabled ? theme.muted : theme.ink)
				.padding(.horizontal, 10)
				.padding(.vertical, 8)
				.frame(minWidth: 44, minHeight: 44)
				.background(disabled ? theme.surfaceMuted : theme.surface, in: shape)
				.rasheedBorder(theme.border, radius: RasheedRadius.control)
				.contentShape(shape)
		}
		.buttonStyle(RasheedPressStyle(pressedOpacity: 0.9))
		.disabled(disabled)
		.accessibilityIdentifier(identifier)
	}
}

/// "Jump to latest" shows while the reader is away from the transcript's end or reads older history. It overlays the
/// transcript's bottom edge, so showing it moves no row.
private struct RasheedLatestControl: View {
	@Environment(\.accessibilityReduceMotion) private var reduceMotion
	@ObservedObject private var state: RasheedTranscriptState
	private let shown: Bool
	private let browsingHistory: Bool
	private let theme: RasheedSupportTheme
	private let title: String
	private let action: () -> Void

	init(state: RasheedTranscriptState, shown: Bool, browsingHistory: Bool, theme: RasheedSupportTheme, title: String,
		action: @escaping () -> Void) {
		self.state = state
		self.shown = shown
		self.browsingHistory = browsingHistory
		self.theme = theme
		self.title = title
		self.action = action
	}

	private var visible: Bool { shown && (browsingHistory || !state.follow.following) }

	var body: some View {
		ZStack {
			if visible {
				Button(action: action) {
					HStack(spacing: 6) {
						Text(title)
							.rasheed(.caption, weight: .medium)
							.foregroundStyle(theme.ink)
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 7)
					.background(theme.surfaceMuted, in: Capsule())
					.shadow(color: .black.opacity(theme.isDark ? 0.35 : 0.12), radius: 8, y: 3)
					.frame(minHeight: 44)
					.contentShape(Rectangle())
				}
				.buttonStyle(RasheedPressStyle())
				.accessibilityIdentifier("rasheed.latest")
				.padding(.bottom, 4)
				.transition(.opacity)
			}
		}
		.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: visible)
	}
}

/// Reports whether a scroll view's content has moved under its top edge, for the header's hairline.
private struct RasheedScrolledEdge: ViewModifier {
	@Binding var scrolled: Bool

	func body(content: Content) -> some View {
		content.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { _, value in
			scrolled = value
		}
	}
}

/// Start a conversation, handed to Home's session section: the inbox opens a draft once the joined guest's inbox
/// is ready.
struct RasheedStartAction {
	let run: @MainActor () -> Void
}

private struct RasheedStartKey: EnvironmentKey {
	static let defaultValue: RasheedStartAction? = nil
}

extension EnvironmentValues {
	var rasheedStart: RasheedStartAction? {
		get { self[RasheedStartKey.self] }
		set { self[RasheedStartKey.self] = newValue }
	}
}
