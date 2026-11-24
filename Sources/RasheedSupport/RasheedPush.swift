import Foundation
import SwiftUI
import UIKit
import UserNotifications

public struct RasheedNotificationTarget: Sendable, Equatable {
	public let scope: PushScope
	public let conversationId: String?

	public init(scope: PushScope, conversationId: String?) {
		self.scope = scope
		self.conversationId = conversationId
	}
}

@MainActor
extension RasheedClient {
	/// The host callback owns presentation, including an RN Fabric widget's lease.
	@discardableResult
	public func handlePushNotification(
		_ userInfo: [AnyHashable: Any],
		onAccepted: (@MainActor () -> Void)? = nil,
		onOpen: @escaping @MainActor (RasheedNotificationTarget) -> Void
	) -> Bool {
		guard let payload = RasheedNotificationData(userInfo: userInfo),
			let scope = currentPushScope(for: userInfo) else { return false }
		let destination = notificationDestination(payload)
		guard destination.valid else { return false }
		if let id = payload.pushId {
			let parts = [scope.workspaceId, scope.contactId, scope.epoch, String(scope.sequence),
				String(scope.credentialGeneration), id]
			let key = parts.map { "\($0.utf8.count):\($0)" }.joined()
			if !notificationDedupe.remember(key) { return true }
		}
		guard isPushScopeCurrent(scope) else { return false }
		onAccepted?()
		if let id = destination.id {
			guard isPushScopeCurrent(scope) else { return false }
			onOpen(RasheedNotificationTarget(scope: scope, conversationId: id))
		} else {
			Task { @MainActor [weak self] in
				guard let self, self.isPushScopeCurrent(scope) else { return }
				let id = await self.latestPushConversation(scope: scope)
				guard !Task.isCancelled, self.isPushScopeCurrent(scope) else { return }
				onOpen(RasheedNotificationTarget(scope: scope, conversationId: id))
			}
		}
		return true
	}

	/// The support target a tapped notification opens, for a launch from a notification: it connects, waits while this
	/// device's push registration is pending or registering, then matches the notification to the current session. nil
	/// when the notification belongs to another session; cancel the task to stop waiting.
	public func notificationTarget(for userInfo: [AnyHashable: Any]) async -> RasheedNotificationTarget? {
		guard let payload = RasheedNotificationData(userInfo: userInfo) else { return nil }
		try? await connect()
		for await snapshot in $push.values where snapshot.status != .pending && snapshot.status != .registering { break }
		let destination = notificationDestination(payload)
		guard !Task.isCancelled, destination.valid, let scope = currentPushScope(for: userInfo) else { return nil }
		let id: String?
		if let known = destination.id { id = known } else { id = await latestPushConversation(scope: scope) }
		guard !Task.isCancelled, isPushScopeCurrent(scope) else { return nil }
		return RasheedNotificationTarget(scope: scope, conversationId: id)
	}

	public func isConversationVisible(scope: PushScope, conversationId: String?) -> Bool {
		guard isPushScopeCurrent(scope), UIApplication.shared.applicationState == .active,
			let conversationId, let thread = inbox.thread, inbox.readState == .confirmed,
			inbox.credentialGeneration == scope.credentialGeneration,
			thread.target.credentialGeneration == scope.credentialGeneration,
			thread.target.conversationId == conversationId, thread.status != .unavailable else { return false }
		conversationPresentations = conversationPresentations.filter { $0.value.view != nil }
		let visible = conversationPresentations.values.contains {
			$0.target == thread.target && $0.isVisible
		}
		return visible && isPushScopeCurrent(scope)
	}

	/// Nil means unrelated. A recognized but stale/malformed Rasheed alert returns no presentation.
	public func handleForegroundNotification(
		_ notification: UNNotification,
		trustedImageHosts: Set<String> = []
	) async -> UNNotificationPresentationOptions? {
		let userInfo = notification.request.content.userInfo
		guard userInfo["rasheed"] as? String == "true" else { return nil }
		guard let payload = RasheedNotificationData(userInfo: userInfo),
			let scope = currentPushScope(for: userInfo),
			UIApplication.shared.applicationState == .active else { return [] }
		let destination = notificationDestination(payload)
		guard destination.valid else { return [] }
		let conversationId: String?
		if let id = destination.id { conversationId = id }
		else {
			conversationId = await latestPushConversation(scope: scope)
			guard !Task.isCancelled, isPushScopeCurrent(scope) else { return [] }
		}
		guard isPushScopeCurrent(scope) else { return [] }
		if isConversationVisible(scope: scope, conversationId: conversationId) { return [] }
		if foregroundNotifications[notification.request.identifier] == scope {
			return foregroundOptions(scope: scope)
		}
		let image: RasheedNotificationImageLoader.Attachment?
		if let source = payload.image, let url = URL(string: source),
			RasheedNotificationImage.isAllowed(url, hosts: trustedImageHosts) {
			guard isPushScopeCurrent(scope) else { return [] }
			image = await RasheedNotificationImageLoader.load(url, hosts: trustedImageHosts)
			guard !Task.isCancelled, isPushScopeCurrent(scope) else { return [] }
		} else { image = nil }
		guard isPushScopeCurrent(scope) else { return [] }
		if isConversationVisible(scope: scope, conversationId: conversationId) { return [] }
		guard image != nil || !notification.request.content.attachments.isEmpty else {
			return foregroundOptions(scope: scope)
		}
		guard let content = notification.request.content.mutableCopy() as? UNMutableNotificationContent else { return [] }
		content.attachments = image.map { [$0.value] } ?? []
		content.sound = playsSound && supportScreens == 0 ? content.sound ?? .default : nil
		let identifier = "rasheed.rich." + UUID().uuidString
		if foregroundNotifications.count >= 256, let oldest = foregroundNotifications.keys.first {
			foregroundNotifications.removeValue(forKey: oldest)
		}
		foregroundNotifications[identifier] = scope
		guard isPushScopeCurrent(scope), UIApplication.shared.applicationState == .active else {
			foregroundNotifications.removeValue(forKey: identifier)
			return []
		}
		do {
			image?.releaseToSystem()
			try await UNUserNotificationCenter.current().add(
				UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
			guard !Task.isCancelled, isPushScopeCurrent(scope) else {
				UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
				UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
				foregroundNotifications.removeValue(forKey: identifier)
				return []
			}
			return []
		} catch {
			foregroundNotifications.removeValue(forKey: identifier)
			guard isPushScopeCurrent(scope) else { return [] }
			// The original can be used only when it has no unvalidated provider attachments.
			return notification.request.content.attachments.isEmpty ? foregroundOptions(scope: scope) : []
		}
	}

	private func foregroundOptions(scope: PushScope) -> UNNotificationPresentationOptions {
		guard isPushScopeCurrent(scope), UIApplication.shared.applicationState == .active else { return [] }
		return playsSound && supportScreens == 0 ? [.banner, .list, .sound] : [.banner, .list]
	}

	@discardableResult
	public func handleDeepLink(_ url: URL, onOpen: @MainActor (String) -> Void) -> Bool {
		guard let id = RasheedDeepLink.conversationId(from: url, client: self) else { return false }
		onOpen(id)
		return true
	}

	private func notificationDestination(_ payload: RasheedNotificationData) -> (valid: Bool, id: String?) {
		guard let raw = payload.url else { return (true, payload.conversationId) }
		guard let url = URL(string: raw), let id = RasheedDeepLink.conversationId(from: url, client: self),
			payload.conversationId == nil || payload.conversationId == id else { return (false, nil) }
		return (true, id)
	}

	func latestPushConversation(scope: PushScope) async -> String? {
		guard isPushScopeCurrent(scope) else { return nil }
		do { try await loadConversations() }
		catch {
			guard isPushScopeCurrent(scope) else { return nil }
			return nil
		}
		guard !Task.isCancelled, isPushScopeCurrent(scope),
			inbox.credentialGeneration == scope.credentialGeneration, inbox.readState == .confirmed else { return nil }
		return inbox.conversations.first { $0.lastAuthor != .contact }?.id
	}
}

@MainActor
struct ConversationPresentation {
	weak var view: UIView?
	let target: InboxTarget

	var isVisible: Bool {
		guard let view, let window = view.window, !window.isHidden,
			window.windowScene?.activationState == .foregroundActive,
			view.bounds.width > 0, view.bounds.height > 0 else { return false }
		var visibleRect = view.convert(view.bounds, to: window).intersection(window.bounds)
		var ancestor: UIView? = view
		while let current = ancestor {
			guard !current.isHidden, current.alpha > 0.01 else { return false }
			if current.clipsToBounds {
				visibleRect = visibleRect.intersection(current.convert(current.bounds, to: window))
			}
			ancestor = current.superview
		}
		guard !visibleRect.isNull, !visibleRect.isEmpty else { return false }
		var responder: UIResponder? = view
		while let current = responder {
			if let controller = current as? UIViewController {
				var ancestor: UIViewController? = controller
				while let current = ancestor {
					guard current.presentedViewController == nil else { return false }
					ancestor = current.parent
				}
				return true
			}
			responder = current.next
		}
		return false
	}
}

@MainActor
struct ConversationVisibilityProbe: UIViewRepresentable {
	let client: RasheedClient
	let target: InboxTarget?

	final class Marker: UIView { weak var client: RasheedClient? }

	func makeUIView(context: Context) -> Marker {
		let view = Marker()
		view.isUserInteractionEnabled = false
		view.isAccessibilityElement = false
		return view
	}

	func updateUIView(_ view: Marker, context: Context) {
		view.client?.conversationPresentations.removeValue(forKey: ObjectIdentifier(view))
		view.client = client
		if let target {
			client.conversationPresentations[ObjectIdentifier(view)] = ConversationPresentation(view: view, target: target)
		}
	}

	static func dismantleUIView(_ view: Marker, coordinator: ()) {
		view.client?.conversationPresentations.removeValue(forKey: ObjectIdentifier(view))
		view.client = nil
	}
}
