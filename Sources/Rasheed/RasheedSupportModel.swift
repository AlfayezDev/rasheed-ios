import Combine
import Foundation
import os
import PhotosUI
import RasheedCore
import SwiftUI
import UIKit

struct RasheedComposerDraft {
	var text: String
	var reply: RasheedSupportReply?
}

private final class WeakAttachmentFile {
	weak var file: RasheedAttachmentFile?
	init(_ file: RasheedAttachmentFile) { self.file = file }
}

@MainActor
public final class RasheedSupportModel: ObservableObject {
	public enum Phase: Sendable, Equatable { case loading, idle, ready, failed }
	public enum Delivery: Sendable, Equatable { case sending, failed, uncertain, canceled }

	public let client: RasheedClient
	@Published public private(set) var configuration: RasheedSupportConfiguration
	@Published public private(set) var inboxSnapshot: InboxSnapshot
	@Published public private(set) var contentRevision = UUID()
	@Published public private(set) var connectionError: Error?
	/// An outage's quiet status, from the client.
	@Published private(set) var connectionNotice: RasheedClient.ConnectionNotice?
	@Published public private(set) var sendError: Error?
	@Published public private(set) var attachmentError: Error?
	@Published public private(set) var discardError: Error?
	@Published public private(set) var preparingLocalFile = false
	@Published public private(set) var submitting = false
	/// The thread is being read again to find out whether a send with an unknown outcome arrived.
	@Published public private(set) var checkingSent = false
	@Published public private(set) var requestedSpace: RasheedSupportSpace?
	@Published public private(set) var requestedConversationId: String?
	@Published public private(set) var requestedNotificationTarget: RasheedNotificationTarget?
	/// A guest who pressed Start a conversation has joined; the inbox opens a draft once it can.
	@Published private(set) var startRequested = false
	@Published public private(set) var pushSnapshot: PushSnapshot
	public var pushStatus: PushStatus { pushSnapshot.status }
	public var pushError: Error? { pushSnapshot.error.map { InboxDisplayError(info: $0) } }
	@Published public var draft = ""
	@Published public var replyTo: RasheedSupportReply?
	public var onIncomingMessage: ((RasheedSupportMessage) -> Void)?

	private struct Submission {
		let id: UUID
		let target: InboxTarget
		let text: String
		let quoteId: String?
	}

	private var subscriptions: Set<AnyCancellable> = []
	private var downloads: [String: WeakAttachmentFile] = [:]
	private var downloadTasks: [String: Task<RasheedAttachmentFile, Error>] = [:]
	private var generation: UInt64
	private var projectedConversationId: String?
	private var watermarks: [String: UInt64] = [:]
	private var incomingInitialized = false
	private var submission: Submission?
	private var activeSend: UUID?
	private var discardedMessageId: String?
	private var presented = false {
		didSet { if presented != oldValue { client.supportScreens += presented ? 1 : -1 } }
	}
	/// The thread on screen, which the view keeps current; nil while none is.
	var visibleThread: InboxTarget?
	private var heardUnread: (onScreen: String?, total: Int)?
	private var heardConnected = false
	/// Each conversation's latest row when the connection was last confirmed: rows up to it arrive with the resync.
	private var resyncedThrough: [String: UInt64] = [:]
	/// Each conversation's latest row and unread count as last heard while connected; nil until then, so a cold start
	/// never sounds for what it loads.
	private var heardRows: [String: (seq: UInt64, unread: Int)]?
	private var notificationNavigation = UUID()
	private var notificationNavigationTarget: RasheedNotificationTarget?
	private var identitySnapshot: RasheedSnapshot
	private var markingRead: Task<Void, Never>?

	public init(client: RasheedClient, configuration: RasheedSupportConfiguration) {
		self.client = client
		self.configuration = configuration
		inboxSnapshot = client.inbox
		pushSnapshot = client.push
		identitySnapshot = client.snapshot
		generation = client.credentialGeneration
		client.$snapshot.sink { [weak self] snapshot in
			guard let self else { return }
			self.identitySnapshot = snapshot
			self.project(self.client.inbox)
		}.store(in: &subscriptions)
		client.$inbox.sink { [weak self] snapshot in self?.project(snapshot) }
			.store(in: &subscriptions)
		client.$localFileError.sink { [weak self] error in
			if let error { self?.discardError = error }
		}.store(in: &subscriptions)
		client.$push.sink { [weak self] snapshot in self?.pushSnapshot = snapshot }
			.store(in: &subscriptions)
		client.$connectionNotice.sink { [weak self] notice in self?.connectionNotice = notice }
			.store(in: &subscriptions)
		// The core's keepalive runs only while the inbox is active, so an open support screen rests it in the background.
		for (name, active) in [(UIApplication.didEnterBackgroundNotification, false),
			(UIApplication.willEnterForegroundNotification, true)] {
			NotificationCenter.default.publisher(for: name).sink { [weak self] _ in
				Task { @MainActor [weak self] in
					guard let self, self.presented else { return }
					try? await self.client.setInboxActive(active)
				}
			}.store(in: &subscriptions)
		}
	}

	public func updatePresentation(language: Language, theme: RasheedTheme) {
		configuration.language = language
		configuration.theme = theme
	}

	public var target: InboxTarget? {
		guard inboxSnapshot.credentialGeneration == identitySnapshot.credentialGeneration,
			inboxSnapshot.thread?.target.credentialGeneration == identitySnapshot.credentialGeneration else { return nil }
		return inboxSnapshot.thread?.target
	}
	public var conversationId: String? { target?.conversationId }
	public var draftConversationId: String? {
		guard let target = client.composerDraftTarget, target.credentialGeneration == generation else { return nil }
		return target.conversationId
	}
	public var workspaceID: String { client.workspaceId }
	public var workspaceName: String? { identitySnapshot.workspace?.name }
	public var memberId: String? { identitySnapshot.profile?.id }
	public var identityReady: Bool {
		identitySnapshot.status == .ready && identitySnapshot.profileState == .confirmed
			&& identitySnapshot.profile != nil && identitySnapshot.uncertainIdentity == nil
	}
	public var canStartConversation: Bool {
		identityReady && inboxSnapshot.credentialGeneration == identitySnapshot.credentialGeneration
			&& inboxSnapshot.readState == .confirmed
	}
	public var canCompose: Bool { canStartConversation && canType }
	/// The thread on screen takes typing: it is open or a draft. The field stays usable through an outage, since what
	/// is typed stays local; sending waits for the connection (`canCompose`).
	public var canType: Bool {
		target != nil && (inboxSnapshot.thread?.status == .draft || inboxSnapshot.thread?.status == .open)
	}
	/// A send is still on its way or needs a decision. The core keeps a confirmed send until the next one replaces it.
	public var hasPendingSend: Bool { inboxSnapshot.pendingSend.map { $0.state != .confirmed } == true || submitting }
	public var phase: Phase {
		if inboxSnapshot.readState != .unknown { return .ready }
		if !reconnecting, connectionError != nil || identitySnapshot.status == .error { return .failed }
		return presented || reconnecting ? .loading : .idle
	}
	public var conversations: [RasheedSupportConversation] {
		guard inboxSnapshot.credentialGeneration == generation,
			identitySnapshot.credentialGeneration == generation else { return [] }
		return inboxSnapshot.conversations.map {
			RasheedSupportConversation(conversationId: $0.id,
				conversationStatus: $0.status == .closed ? "closed" : "open",
				lastMessageAt: microsToMillis($0.lastMessageAt), lastMessageAuthorKind: $0.lastAuthor.sdkValue,
				lastMessagePreview: $0.preview.isEmpty ? nil : $0.preview,
				createdAt: microsToMillis($0.createdAt),
				assignee: $0.assignee.map { RasheedSupportAssignee(name: $0.name, image: $0.image) },
				unread: Int($0.unread), lastAuthorName: $0.lastAuthorName.flatMap { $0.isEmpty ? nil : $0 })
		}
	}
	/// Unread replies across the loaded conversations.
	public var unreadCount: Int { conversations.reduce(0) { $0 + $1.unread } }
	/// The open conversation a send was refused for, because another one is already open.
	public var movedConversationId: String? {
		guard target != nil else { return nil }
		return inboxSnapshot.thread?.movedTo
	}
	public var messages: [RasheedSupportMessage] {
		guard target != nil else { return [] }
		return inboxSnapshot.thread?.messages.map(message) ?? []
	}
	public var assignee: RasheedSupportAssignee? {
		guard target != nil else { return nil }
		return inboxSnapshot.thread?.summary?.assignee.map {
			RasheedSupportAssignee(name: $0.name, image: $0.image)
		}
	}
	public var isClosed: Bool {
		inboxSnapshot.thread?.status == .closed || inboxSnapshot.thread?.status == .unavailable
	}
	public var isDraft: Bool { inboxSnapshot.thread?.status == .draft }
	public var nextConversationCursor: String? { inboxSnapshot.nextCursor }
	public var loadingConversations: Bool { inboxSnapshot.listState.isRunning }
	public var loadingOlder: Bool { inboxSnapshot.thread?.historyState.isRunning == true }
	var loadingThread: Bool { inboxSnapshot.thread?.loadState.isRunning == true }
	public var hasMoreHistory: Bool { inboxSnapshot.thread?.hasOlder == true }
	public var browsingHistory: Bool { inboxSnapshot.thread?.hasNewer == true }
	/// The connection is being opened, or restored after it dropped.
	public var reconnecting: Bool { client.connectionDown }
	public var preparingAttachment: Bool { preparingLocalFile || inboxSnapshot.attachmentState.isRunning }
	public var sending: Bool { submitting || inboxSnapshot.pendingSend?.state.isRunning == true }
	public var pendingAttachments: [RasheedPendingAttachment] {
		guard let target else { return [] }
		return inboxSnapshot.attachments.filter { $0.target == target }.map {
			RasheedPendingAttachment(id: $0.attachment.id, file: RasheedSupportAttachment($0.attachment),
				ready: $0.state == .ready, uploading: [.reserving, .uploading, .completing].contains($0.state),
				failed: $0.state == .failed || $0.state == .outcomeUnknown)
		}
	}
	public var outbox: [RasheedSupportMessage] {
		guard let pending = inboxSnapshot.pendingSend, pending.target == target,
			pending.state != .confirmed, !messages.contains(where: { $0.id == pending.message.id }) else { return [] }
		return [message(pending.message)]
	}

	public func start(conversationId: String? = nil) async {
		_ = await start(conversationId: conversationId, pushScope: nil)
	}

	func start(notificationTarget: RasheedNotificationTarget) async -> Bool {
		guard client.isPushScopeCurrent(notificationTarget.scope) else { return false }
		if let destination = notificationNavigationTarget, destination != notificationTarget { return false }
		notificationNavigationTarget = notificationTarget
		return await start(conversationId: notificationTarget.conversationId, pushScope: notificationTarget.scope)
	}

	private func start(conversationId: String?, pushScope: PushScope?, navigation: UUID? = nil) async -> Bool {
		let expectedGeneration = generation
		func current() -> Bool {
			(navigation == nil || notificationNavigation == navigation)
				&& (pushScope.map { client.isPushScopeCurrent($0) } ?? (generation == expectedGeneration))
		}
		guard current(), !Task.isCancelled else { return false }
		presented = true
		guard pushScope != nil || identityReady else { return false }
		do {
			try await client.setInboxActive(true)
			try Task.checkCancellation()
			guard current() else { return false }
			let destination: String?
			if let pushScope {
				guard let target = notificationNavigationTarget, target.scope == pushScope else { return false }
				destination = target.conversationId
			} else { destination = conversationId }
			if let destination, destination != self.conversationId {
				try await client.setActiveConversation(destination)
				guard current(), !Task.isCancelled else { return false }
			}
			guard current(), !Task.isCancelled else { return false }
			connectionError = nil
			return true
		} catch {
			if !Task.isCancelled, current() { readFailed(error) }
			return false
		}
	}

	/// One ephemeral notification navigation; its scope is never reduced to an unguarded ID.
	@discardableResult
	public func openNotification(_ target: RasheedNotificationTarget) async -> Bool {
		guard client.isPushScopeCurrent(target.scope), !Task.isCancelled else { return false }
		client.refreshSnapshots()
		guard client.isPushScopeCurrent(target.scope) else { return false }
		let navigation = UUID()
		notificationNavigation = navigation
		notificationNavigationTarget = target
		let id: String?
		if let conversationId = target.conversationId { id = conversationId }
		else {
			id = await client.latestPushConversation(scope: target.scope)
			guard notificationNavigation == navigation, client.isPushScopeCurrent(target.scope),
				!Task.isCancelled else { return false }
		}
		let resolved = RasheedNotificationTarget(scope: target.scope, conversationId: id)
		guard notificationNavigation == navigation, client.isPushScopeCurrent(target.scope) else { return false }
		notificationNavigationTarget = resolved
		guard await start(conversationId: resolved.conversationId, pushScope: resolved.scope, navigation: navigation) else { return false }
		guard notificationNavigation == navigation, client.isPushScopeCurrent(target.scope),
			!Task.isCancelled, let destination = notificationNavigationTarget,
			destination.scope == target.scope else { return false }
		requestedSpace = nil
		requestedConversationId = nil
		requestedNotificationTarget = destination
		return true
	}

	func consumeNotificationRequest() { requestedNotificationTarget = nil }

	func clearNotificationNavigation() {
		clearRequest()
		notificationNavigationTarget = nil
	}

	@discardableResult
	public func startConversation() async -> Bool {
		let expectedGeneration = generation
		do {
			_ = try await client.startConversation()
			guard generation == expectedGeneration else { return false }
			connectionError = nil
			return true
		} catch {
			if generation == expectedGeneration { readFailed(error) }
			return false
		}
	}

	public func stop() {
		presented = false
		clearRequest()
		saveDraft()
	}

	public func isActivelyViewing(conversationId: String?) -> Bool {
		guard let scope = client.push.scope else { return false }
		return client.isConversationVisible(scope: scope, conversationId: conversationId)
	}

	@discardableResult
	public func setPushToken(_ token: String) async throws -> Bool {
		try await client.setPushToken(token)
	}

	public func unregisterPush() async throws { try await client.unregisterPush() }

	public func retryPushRegistration() async throws { try await client.retryPushRegistration() }

	public func latestReplyConversationId() async -> String? {
		await loadConversations()
		return inboxSnapshot.conversations.first { $0.lastAuthor != .contact }?.id
	}

	public func loadConversations(more: Bool = false) async {
		let expectedGeneration = generation
		do {
			try await client.loadConversations(cursor: more ? nextConversationCursor : nil)
			if generation == expectedGeneration { connectionError = nil }
		} catch { if generation == expectedGeneration { readFailed(error) } }
	}

	@discardableResult
	public func loadOlder() async -> String? {
		guard let target else { return nil }
		let anchor = messages.first?.id
		do { try await client.loadOlderMessages(target: target) }
		catch { if self.target == target { readFailed(error) } }
		return anchor
	}

	public func showLatest() {
		guard let target else { return }
		Task {
			do { try await client.jumpToLatest(target: target) }
			catch { if self.target == target { readFailed(error) } }
		}
	}

	public func revealMessage(_ id: String) async -> Bool {
		guard let target else { return false }
		do {
			try await client.revealMessage(target: target, messageId: id)
			return self.target == target && messages.contains { $0.id == id }
		} catch {
			if self.target == target { readFailed(error) }
			return false
		}
	}

	public func reply(to message: RasheedSupportMessage) {
		guard canCompose, message.conversationId == conversationId, delivery(of: message) == nil else { return }
		replyTo = RasheedSupportReply(message)
	}

	public func stagePhoto(_ item: PhotosPickerItem, target: InboxTarget) async {
		guard self.target == target, !preparingLocalFile else { return }
		preparingLocalFile = true
		defer { if generation == target.credentialGeneration { preparingLocalFile = false } }
		do {
			guard let picked = try await item.loadTransferable(type: RasheedPickedFile.self) else {
				throw RasheedSupportError.invalidRequest
			}
			try Task.checkCancellation()
			guard self.target == target else { return }
			try await client.selectPrivateFiles(target: target, files: [picked.file])
			attachmentError = nil
		} catch {
			if !Task.isCancelled, self.target == target { attachmentError = error }
		}
	}

	public func stageFiles(_ result: Result<[URL], Error>, target: InboxTarget) async {
		guard self.target == target, !preparingLocalFile else { return }
		preparingLocalFile = true
		defer { if generation == target.credentialGeneration { preparingLocalFile = false } }
		do {
			let urls = try result.get()
			var files: [RasheedAttachmentFile] = []
			for url in urls {
				let copy = Task.detached(priority: .userInitiated) { try RasheedAttachmentFile.copy(from: url) }
				let file = try await withTaskCancellationHandler {
					try await copy.value
				} onCancel: { copy.cancel() }
				files.append(file)
				try Task.checkCancellation()
				guard self.target == target else { return }
			}
			try await client.selectPrivateFiles(target: target, files: files)
			attachmentError = nil
		} catch {
			if !Task.isCancelled, self.target == target { attachmentError = error }
		}
	}

	public func removeAttachment(_ id: String) {
		let expectedGeneration = generation
		Task {
			do { try await client.removeFile(fileId: id) }
			catch { if generation == expectedGeneration { attachmentError = error } }
		}
	}

	public func clearAttachmentError() { attachmentError = nil }

	public func retryDiscardedUploads() async {
		discardError = nil
		client.retryLocalFileCleanup()
		if let error = client.localFileError { discardError = error }
		if let discardedMessageId { await discardFailed(discardedMessageId) }
	}

	public func download(_ attachment: RasheedSupportAttachment) async throws -> RasheedAttachmentFile {
		guard let target else { throw RasheedClientError.Canceled }
		let key = "\(target.credentialGeneration)/\(target.conversationId)/\(attachment.id)"
		if let file = downloads[key]?.file { return file }
		if let task = downloadTasks[key] {
			let file = try await task.value
			guard self.target == target else { throw RasheedClientError.Canceled }
			return file
		}
		downloads = downloads.filter { $0.value.file != nil }
		let localPath = (inboxSnapshot.attachments + (inboxSnapshot.pendingSend?.files ?? []))
			.first { $0.target == target && $0.attachment.id == attachment.id }?.localPath
		let sourceLease = localPath.flatMap { RasheedAttachmentFile.lease(path: $0) }
		let client = client
		let task = Task { @MainActor in
			if let sourceLease {
				let copy = Task.detached(priority: .utility) {
					try withExtendedLifetime(sourceLease) {
						try RasheedAttachmentFile.copy(from: sourceLease.url,
							named: attachment.fileName, mimeType: attachment.mimeType)
					}
				}
				return try await withTaskCancellationHandler {
					try await copy.value
				} onCancel: { copy.cancel() }
			}
			let directory = try RasheedAttachmentFile.makeDirectory()
			let file = RasheedAttachmentFile(directory: directory,
				url: directory.appendingPathComponent(RasheedAttachmentFile.safeName(attachment.fileName)),
				fileName: attachment.fileName, mimeType: attachment.mimeType, byteLength: attachment.byteLength)
			try await client.downloadAttachment(target: target, attachmentId: attachment.id, destinationPath: file.url.path)
			try Task.checkCancellation()
			return file
		}
		downloadTasks[key] = task
		defer { downloadTasks.removeValue(forKey: key) }
		let file = try await task.value
		guard self.target == target else { throw RasheedClientError.Canceled }
		downloads[key] = WeakAttachmentFile(file)
		return file
	}

	public func send() async {
		guard let target, canCompose, !hasPendingSend, !preparingAttachment else { return }
		let captured = Submission(id: UUID(), target: target, text: draft, quoteId: replyTo?.id)
		submission = captured
		activeSend = captured.id
		submitting = true
		defer {
			if submission?.id == captured.id { submission = nil }
			if activeSend == captured.id {
				activeSend = nil
				submitting = false
			}
		}
		do {
			_ = try await client.sendMessage(target: target, body: captured.text, quoteId: captured.quoteId)
			if self.target == target {
				if submission?.id == captured.id { clearSubmittedComposer(captured) }
				sendError = nil
			}
		} catch {
			if self.target == target {
				acceptFrozenComposer(inboxSnapshot)
				// A send the outage stopped before it was kept leaves the draft in place; Send works again once back.
				sendError = reconnecting ? nil : error
			}
		}
	}

	public func retrySend() async {
		guard let pending = inboxSnapshot.pendingSend else { return }
		await retryFrozen(pending.message.id)
	}

	public func clearSendError() { sendError = nil }

	public func retry(_ id: String) { Task { await retryFrozen(id) } }

	private func retryFrozen(_ id: String) async {
		let expectedGeneration = generation
		do {
			try await client.retrySend(messageId: id)
			if generation == expectedGeneration { sendError = nil }
		} catch { if generation == expectedGeneration { sendError = error } }
	}

	public func discard(_ id: String) { Task { await discardFailed(id) } }

	private func discardFailed(_ id: String) async {
		let expectedGeneration = generation
		discardedMessageId = id
		do {
			try await client.discardFailed(messageId: id)
			guard generation == expectedGeneration else { return }
			discardedMessageId = nil
			discardError = client.localFileError
			sendError = nil
		} catch { if generation == expectedGeneration { discardError = error } }
	}

	public func cancelSend() {
		guard let pending = inboxSnapshot.pendingSend else { return }
		client.cancelSend(messageId: pending.message.id)
	}

	/// Returns a message that wasn't sent to the composer, as on the web: always its files, and its text and quote when
	/// the composer is empty. The files' private copies stay leased while the send is discarded, then are staged again.
	public func edit(_ id: String) {
		guard let pending = inboxSnapshot.pendingSend, pending.message.id == id, pending.target == target else { return }
		let text = pending.message.body
		let quote = pending.message.quote.map {
			RasheedSupportReply(id: $0.id, createdAt: 0, authorKind: $0.author.sdkValue,
				authorDisplayName: $0.authorName.isEmpty ? nil : $0.authorName, body: $0.body)
		}
		let files = pending.files.compactMap { RasheedAttachmentFile.lease(path: $0.localPath) }
		Task {
			await discardFailed(id)
			guard discardError == nil, inboxSnapshot.pendingSend?.message.id != id, self.target == pending.target else { return }
			if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && replyTo == nil {
				draft = text
				replyTo = quote
			}
			guard !pending.files.isEmpty else { return }
			do {
				if !files.isEmpty { try await client.selectPrivateFiles(target: pending.target, files: files) }
				if files.count < pending.files.count { throw RasheedSupportError.invalidRequest }
			} catch {
				if self.target == pending.target { attachmentError = error }
			}
		}
	}

	/// Reads the thread again, as the web's Check for sent messages does: a send that arrived shows as sent. Nothing
	/// is sent again.
	public func checkSent() {
		guard !checkingSent else { return }
		checkingSent = true
		Task {
			defer { checkingSent = false }
			await start(conversationId: conversationId)
		}
	}

	/// The conversation's replies the customer hasn't seen.
	func unread(of conversationId: String) -> Int {
		Int(inboxSnapshot.conversations.first { $0.id == conversationId }?.unread
			?? inboxSnapshot.thread.flatMap { $0.target.conversationId == conversationId ? $0.summary?.unread : nil } ?? 0)
	}

	/// Clears the open thread's unread replies while its latest messages are on screen. One call runs at a time; a
	/// failure leaves them unread, and the next visit or reply tries again.
	func markRead() {
		guard markingRead == nil, let target, canStartConversation, !browsingHistory,
			!loadingThread, unread(of: target.conversationId) > 0 else { return }
		markingRead = Task {
			defer { markingRead = nil }
			do { try await client.markRead(target: target) }
			catch {
				Logger(subsystem: "io.rasheed.support", category: "inbox")
					.error("Marking replies read failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	func requestStart() { startRequested = true }

	func consumeStartRequest() { startRequested = false }

	public func canRetry(_ id: String) -> Bool {
		inboxSnapshot.pendingSend?.message.id == id && inboxSnapshot.pendingSend?.canRetry == true
	}

	public func delivery(of message: RasheedSupportMessage) -> Delivery? {
		guard let pending = inboxSnapshot.pendingSend, pending.message.id == message.id else { return nil }
		switch pending.state {
		case .running: return .sending
		case .failed: return .failed
		case .outcomeUnknown: return .uncertain
		case .canceled: return .canceled
		default: return nil
		}
	}

	public func failureReason(of message: RasheedSupportMessage) -> String? {
		guard let pending = inboxSnapshot.pendingSend, pending.message.id == message.id else { return nil }
		return pending.state.displayError?.localizedDescription
	}

	public func open(space: RasheedSupportSpace, conversationId: String? = nil) {
		clearNotificationNavigation()
		requestedConversationId = conversationId
		requestedSpace = space
	}

	public func clearRequest() {
		notificationNavigation = UUID()
		requestedNotificationTarget = nil
		requestedSpace = nil
		requestedConversationId = nil
	}

	public func identify(_ identity: SignedIdentity) async throws { try await client.identify(identity) }

	public func shutdown() -> Task<Void, Error> { client.beginLeave() }

	private func project(_ snapshot: InboxSnapshot) {
		let nextGeneration = max(snapshot.credentialGeneration, identitySnapshot.credentialGeneration)
		if nextGeneration != generation {
			generation = nextGeneration
			notificationNavigationTarget = nil
			client.composerDrafts.removeAll()
			draft = ""
			replyTo = nil
			submission = nil
			activeSend = nil
			discardedMessageId = nil
			submitting = false
			preparingLocalFile = false
			clearRequest()
			startRequested = false
			projectedConversationId = nil
			downloads.removeAll()
			for task in downloadTasks.values { task.cancel() }
			downloadTasks.removeAll()
			watermarks.removeAll()
			incomingInitialized = false
			heardRows = nil
			inboxSnapshot = InboxSnapshot(revision: snapshot.revision, credentialGeneration: nextGeneration,
				readState: .unknown, active: false, conversations: [], nextCursor: nil, listState: .idle,
				thread: nil, attachments: [], attachmentState: .idle, pendingSend: nil, discardState: .idle)
			sendError = nil
			attachmentError = nil
			connectionError = nil
			discardError = client.localFileError
			contentRevision = UUID()
		}
		guard snapshot.credentialGeneration == identitySnapshot.credentialGeneration,
			snapshot.credentialGeneration == generation else { return }
		let nextConversationId = snapshot.thread?.target.conversationId
		if projectedConversationId != nextConversationId {
			saveDraft()
			projectedConversationId = nextConversationId
			let saved = nextConversationId.flatMap { client.composerDrafts[$0] }
			draft = saved?.text ?? ""
			replyTo = saved?.reply
			downloads.removeAll()
			contentRevision = UUID()
		}
		let old = inboxSnapshot
		inboxSnapshot = snapshot
		listenForReplies(old: old, next: snapshot)
		acceptFrozenComposer(snapshot)
		// A send whose outcome was unknown turned out stored: its error is moot.
		if sendError != nil, let pending = snapshot.pendingSend, pending.state == .confirmed
			|| snapshot.thread?.messages.contains(where: { $0.id == pending.message.id }) == true { sendError = nil }
		if old.attachmentState != snapshot.attachmentState {
			attachmentError = snapshot.attachmentState.displayError
		}
		if old.discardState != snapshot.discardState {
			discardError = snapshot.discardState.displayError ?? client.localFileError
		}
		if reconnecting { connectionError = nil }
		else if old.listState != snapshot.listState || old.thread?.historyState != snapshot.thread?.historyState
			|| old.thread?.loadState != snapshot.thread?.loadState {
			connectionError = snapshot.listState.displayError
				?? snapshot.thread?.historyState.displayError ?? snapshot.thread?.loadState.displayError
		}
		if let moved = snapshot.thread?.movedTo, moved != requestedConversationId {
			if let destination = notificationNavigationTarget {
				let scope = destination.scope
				let target = RasheedNotificationTarget(scope: scope, conversationId: moved)
				if presented, snapshot.readState == .confirmed,
					snapshot.thread?.target.conversationId == destination.conversationId,
					snapshot.thread?.target.credentialGeneration == scope.credentialGeneration,
					client.isPushScopeCurrent(scope) {
					notificationNavigationTarget = target
					requestedNotificationTarget = target
				}
			}
		}
		if let thread = snapshot.thread {
			let id = thread.target.conversationId
			if incomingInitialized, let last = watermarks[id] {
				for row in thread.messages where row.seq > last && row.author != .contact {
					onIncomingMessage?(message(row))
				}
			}
			let baseline = watermarks[id] ?? thread.summary?.lastSeq ?? 0
			watermarks[id] = max(baseline, thread.messages.last?.seq ?? 0)
		}
		for row in snapshot.conversations where row.id != snapshot.thread?.target.conversationId {
			watermarks[row.id] = max(watermarks[row.id] ?? 0, row.lastSeq)
		}
		if snapshot.readState == .confirmed { incomingInitialized = true }
	}

	/// The web's reply sound while this support screen is open: a new staff or system row in the thread on screen once
	/// it has loaded, else a rise in the other conversations' unread total. A reconnect rings once when its resync brings
	/// replies that weren't shown or counted before the drop. Loads, older pages and the customer's own sends move the
	/// baseline silently; the chime plays only in the foreground.
	private func listenForReplies(old: InboxSnapshot, next: InboxSnapshot) {
		let connected = identityReady && next.readState == .confirmed
		defer { heardConnected = connected }
		var ring = false
		// The list is current when the connection is confirmed, but the thread's rows may follow in a later update. A
		// reconnect rings once if its resync brings staff or system replies that weren't shown or counted before the drop.
		if connected, !heardConnected {
			if let heard = heardRows {
				ring = next.conversations.contains { row in
					let before = heard[row.id] ?? (0, 0)
					return row.lastSeq > before.seq && (Int(row.unread) > before.unread || row.lastAuthor != .contact)
				}
			}
			resyncedThrough = Dictionary(next.conversations.map { ($0.id, $0.lastSeq) }, uniquingKeysWith: max)
		}
		if connected {
			heardRows = Dictionary(next.conversations.map { ($0.id, (seq: $0.lastSeq, unread: Int($0.unread))) },
				uniquingKeysWith: { first, _ in first })
		}
		let onScreen = visibleThread
		if !ring, connected, heardConnected, let target = onScreen, let before = old.thread, let after = next.thread,
			before.target == target, after.target == target, !before.hasNewer, !after.hasNewer,
			!before.loadState.isRunning, let last = before.messages.last?.createdAt {
			let known = Set(before.messages.map(\.id))
			let resynced = resyncedThrough[target.conversationId] ?? 0
			ring = after.messages.contains {
				$0.author != .contact && $0.createdAt > last && !known.contains($0.id) && $0.seq > resynced
			}
		}
		let total = connected && !next.listState.isRunning
			? next.conversations.reduce(0) { $0 + ($1.id == onScreen?.conversationId ? 0 : Int($1.unread)) } : nil
		if let total, let heard = heardUnread, heard.onScreen == onScreen?.conversationId, total > heard.total { ring = true }
		heardUnread = total.map { (onScreen?.conversationId, $0) }
		if ring, presented, client.playsSound, UIApplication.shared.applicationState == .active { RasheedChime.play() }
	}

	/// While the connection is down, the outage shows its own status and the reads run again once it is back.
	private func readFailed(_ error: Error) { connectionError = reconnecting ? nil : error }

	private func saveDraft() {
		guard let id = projectedConversationId else { return }
		client.composerDrafts[id] = draft.isEmpty && replyTo == nil ? nil : RasheedComposerDraft(text: draft, reply: replyTo)
	}

	private func acceptFrozenComposer(_ snapshot: InboxSnapshot) {
		guard let captured = submission, let pending = snapshot.pendingSend,
			pending.target == captured.target,
			pending.message.body == captured.text.trimmingCharacters(in: .whitespacesAndNewlines),
			pending.message.quote?.id == captured.quoteId else { return }
		clearSubmittedComposer(captured)
		submission = nil
	}

	private func clearSubmittedComposer(_ captured: Submission) {
		guard target == captured.target else { return }
		if draft == captured.text { draft = "" }
		if replyTo?.id == captured.quoteId { replyTo = nil }
		saveDraft()
	}

	private func message(_ row: RasheedCore.InboxMessage) -> RasheedSupportMessage {
		let quote = row.quote.map { quote in
			let original = inboxSnapshot.thread?.messages.first { $0.id == quote.id }
			return RasheedSupportReply(id: quote.id, createdAt: original.map { microsToMillis($0.createdAt) } ?? 0,
				authorKind: quote.author.sdkValue, authorDisplayName: quote.authorName.isEmpty ? nil : quote.authorName, body: quote.body)
		}
		return RasheedSupportMessage(id: row.id, conversationId: row.conversationId, authorKind: row.author.sdkValue,
			authorMemberId: row.authorId, authorDisplayName: row.authorName.isEmpty ? nil : row.authorName,
			body: row.body, createdAt: microsToMillis(row.createdAt), seq: Int(clamping: row.seq),
			replyTo: quote, attachments: row.attachments.map(RasheedSupportAttachment.init))
	}
}

private struct InboxDisplayError: LocalizedError {
	let info: RasheedCore.ErrorInfo
	var errorDescription: String? { info.message }
}

private extension RasheedCore.InboxActionState {
	var isRunning: Bool { self == .running }
	var displayError: Error? {
		switch self {
		case .failed(let error): InboxDisplayError(info: error)
		case .outcomeUnknown: RasheedClientError.OutcomeUnknown
		case .canceled: RasheedClientError.Canceled
		default: nil
		}
	}
}
