import SwiftUI
import UIKit
import UserNotifications

@MainActor
public enum RasheedSupport {
	public typealias Space = RasheedSupportSpace
	public enum Content: Sendable { case conversation(id: String) }
	public private(set) static var current: RasheedSupportModel?
	public private(set) static var lastError: Error?
	public static var isInitialized: Bool { current != nil }
	private static var host: UIViewController?

	public static func initialize(client: RasheedClient, configuration: RasheedSupportConfiguration) {
		if let current, current.client === client, current.configuration == configuration { return }
		host?.dismiss(animated: false)
		host = nil
		current?.stop()
		current = RasheedSupportModel(client: client, configuration: configuration)
		lastError = nil
	}

	public static func present(_ space: Space = .home, conversationId: String? = nil) {
		present(space, conversationId: conversationId, notificationTarget: nil)
	}

	private static func present(_ space: Space, conversationId: String?, notificationTarget: RasheedNotificationTarget?) {
		guard let model = current else {
			lastError = RasheedSupportError.notConfigured
			return
		}
		if let notificationTarget, !model.client.isPushScopeCurrent(notificationTarget.scope) { return }
		if let host, host.presentingViewController != nil {
			if let notificationTarget {
				Task { @MainActor in
					guard current === model, model.client.isPushScopeCurrent(notificationTarget.scope) else { return }
					_ = await model.openNotification(notificationTarget)
					guard current === model, model.client.isPushScopeCurrent(notificationTarget.scope) else { return }
				}
			} else { model.open(space: space, conversationId: conversationId) }
			return
		}
		guard let presenter = topViewController() else { return }
		let controller = UIHostingController(rootView: RasheedSupportView(model: model,
			initialSpace: space, initialConversationID: conversationId, initialNotificationTarget: notificationTarget))
		controller.modalPresentationStyle = model.configuration.presentation.fillsScreen ? .fullScreen : .pageSheet
		controller.overrideUserInterfaceStyle = model.configuration.theme.colorScheme.map(UIUserInterfaceStyle.init) ?? .unspecified
		if let notificationTarget, !model.client.isPushScopeCurrent(notificationTarget.scope) { return }
		presenter.present(controller, animated: !UIAccessibility.isReduceMotionEnabled)
		host = controller
	}

	public static func presentContent(_ content: Content) {
		switch content {
		case .conversation(let id): present(.messages, conversationId: id)
		}
	}

	public static func hide() {
		current?.stop()
		host?.dismiss(animated: true)
		host = nil
	}

	public static func shutdown() -> Task<Void, Error> {
		let retirement = current?.shutdown() ?? Task<Void, Error> {}
		hide()
		return retirement
	}

	public static func identify(_ identity: SignedIdentity) async throws {
		guard let current else { throw RasheedSupportError.notConfigured }
		do {
			try await current.client.identify(identity)
			lastError = nil
		} catch {
			lastError = error
			throw error
		}
	}

	@discardableResult
	public static func setPushToken(_ token: String) async throws -> Bool {
		guard let current else { throw RasheedSupportError.notConfigured }
		do {
			let registered = try await current.client.setPushToken(token)
			lastError = nil
			return registered
		} catch { lastError = error; throw error }
	}

	public static func unregisterPush() async throws {
		guard let current else { throw RasheedSupportError.notConfigured }
		do { try await current.client.unregisterPush(); lastError = nil }
		catch { lastError = error; throw error }
	}

	public static func retryPushRegistration() async throws {
		guard let current else { throw RasheedSupportError.notConfigured }
		do { try await current.client.retryPushRegistration(); lastError = nil }
		catch { lastError = error; throw error }
	}

	@discardableResult
	public static func handleDeepLink(_ url: URL) -> Bool {
		guard let current else { return false }
		return current.client.handleDeepLink(url) { present(.messages, conversationId: $0) }
	}

	/// Recognition is not authorization. Use the live instance scope hook before presentation.
	public static func isRasheedPushNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
		userInfo["rasheed"] as? String == "true"
	}

	@discardableResult
	public static func handlePushNotification(
		_ userInfo: [AnyHashable: Any],
		onAccepted: (@MainActor () -> Void)? = nil
	) -> Bool {
		guard let client = current?.client else { return false }
		return client.handlePushNotification(userInfo, onAccepted: onAccepted) { [weak client] target in
			guard let client, current?.client === client, client.isPushScopeCurrent(target.scope) else { return }
			present(.messages, conversationId: nil, notificationTarget: target)
		}
	}

	public static func handleForegroundNotification(
		_ notification: UNNotification
	) async -> UNNotificationPresentationOptions? {
		guard let model = current else {
			return isRasheedPushNotification(notification.request.content.userInfo) ? [] : nil
		}
		let scope = model.client.currentPushScope(for: notification.request.content.userInfo)
		let result = await model.client.handleForegroundNotification(notification,
			trustedImageHosts: model.configuration.trustedImageHosts)
		guard current?.client === model.client else { return [] }
		if isRasheedPushNotification(notification.request.content.userInfo) {
			guard let scope, model.client.isPushScopeCurrent(scope) else { return [] }
		}
		return result
	}

	private static func topViewController() -> UIViewController? {
		let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
		guard var top = windows.first(where: \.isKeyWindow)?.rootViewController
			?? windows.first?.rootViewController else { return nil }
		while true {
			if let presented = top.presentedViewController { top = presented }
			else if let navigation = top as? UINavigationController, let visible = navigation.visibleViewController { top = visible }
			else if let tab = top as? UITabBarController, let selected = tab.selectedViewController { top = selected }
			else { return top }
		}
	}
}

@MainActor
enum RasheedDeepLink {
	static func conversationId(from url: URL, client: RasheedClient) -> String? {
		guard url.user == nil, url.password == nil, url.fragment == nil else { return nil }
		let raw: String?
		if url.scheme?.lowercased() == "rasheedchat" {
			guard url.host?.lowercased() == "conversation", url.port == nil, url.query == nil else { return nil }
			let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
			guard segments.count == 1 else { return nil }
			raw = segments.first
		} else {
			let defaultPort = client.platformURL.scheme?.lowercased() == "https" ? 443 : 80
			guard url.scheme?.lowercased() == client.platformURL.scheme?.lowercased(),
				url.host?.lowercased() == client.platformURL.host?.lowercased(),
				(url.port ?? defaultPort) == (client.platformURL.port ?? defaultPort) else { return nil }
			let segments = url.path.split(separator: "/")
			guard segments.count == 2, String(segments[0]) == client.workspaceId, segments[1] == "widget",
				let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
				items.filter({ $0.name == "conversation" }).count == 1 else { return nil }
			raw = items.first { $0.name == "conversation" }?.value
		}
		guard let raw, !raw.isEmpty, raw.utf8.count <= 256,
			!raw.contains(where: { $0.isWhitespace || $0.isNewline }),
			!raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
		return raw
	}
}
