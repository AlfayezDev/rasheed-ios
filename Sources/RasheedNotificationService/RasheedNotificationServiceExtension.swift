import Foundation
import RasheedNotificationSupport
import UserNotifications

/// Enriches an already-accepted OS alert, not an authenticated app presentation.
open class RasheedNotificationServiceExtension: UNNotificationServiceExtension {
	open var trustedImageHosts: Set<String> { [] }
	open var workspaceID: String? { nil }

	private let lock = NSLock()
	private var delivery: Delivery?

	open override func didReceive(
		_ request: UNNotificationRequest,
		withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
	) {
		let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
			?? UNMutableNotificationContent()
		content.title = request.content.title
		content.subtitle = request.content.subtitle
		content.body = request.content.body
		content.sound = request.content.sound
		content.userInfo = request.content.userInfo
		// Do not let provider helpers bypass this extension's image policy.
		content.attachments = []
		let next = Delivery(content: content, handler: contentHandler)
		lock.lock()
		let previous = delivery
		delivery = next
		lock.unlock()
		previous?.finish()
		guard let payload = RasheedNotificationData(userInfo: request.content.userInfo),
			payload.belongs(to: workspaceID),
			let image = payload.image, let url = URL(string: image) else {
			next.finish()
			return
		}
		let request = RasheedNotificationImageLoader.load(url, hosts: trustedImageHosts) { result in
			next.finish(image: try? result.get())
		}
		next.install(request)
	}

	open override func serviceExtensionTimeWillExpire() {
		lock.lock()
		let current = delivery
		lock.unlock()
		current?.finish()
	}

	private final class Delivery {
		private let lock = NSLock()
		private let content: UNMutableNotificationContent
		private var handler: ((UNNotificationContent) -> Void)?
		private var request: RasheedNotificationImageLoader.Request?

		init(content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
			self.content = content
			self.handler = handler
		}

		func install(_ request: RasheedNotificationImageLoader.Request) {
			lock.lock()
			let finished = handler == nil
			if !finished { self.request = request }
			lock.unlock()
			if finished { request.cancel() }
		}

		func finish(image: RasheedNotificationImageLoader.Attachment? = nil) {
			lock.lock()
			guard let handler else { lock.unlock(); return }
			self.handler = nil
			let request = self.request
			self.request = nil
			if let image {
				content.attachments = [image.value]
				image.releaseToSystem()
			}
			lock.unlock()
			request?.cancel()
			handler(content)
		}
	}
}
