import Foundation
import Dispatch
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

public enum RasheedNotificationImageLoader {
	static let maxBytes = 5 * 1024 * 1024
	static let timeout: TimeInterval = 8
	private static let deadlineQueue = DispatchQueue(label: "ai.rasheed.notification.deadline",
		qos: .userInitiated, attributes: .concurrent)
	private static let workQueue = DispatchQueue(label: "ai.rasheed.notification.image",
		qos: .utility, attributes: .concurrent)

	/// An unconsumed image owns its private file, including when work finishes after timeout.
	public final class Attachment: @unchecked Sendable {
		public let value: UNNotificationAttachment
		private let lock = NSLock()
		private var systemOwned = false

		fileprivate init(_ value: UNNotificationAttachment) { self.value = value }

		public func releaseToSystem() {
			lock.lock()
			systemOwned = true
			lock.unlock()
		}

		deinit {
			lock.lock()
			let remove = !systemOwned
			lock.unlock()
			if remove {
				let url = value.url
				RasheedNotificationImageLoader.workQueue.async {
					let scoped = url.startAccessingSecurityScopedResource()
					defer { if scoped { url.stopAccessingSecurityScopedResource() } }
					try? FileManager.default.removeItem(at: url)
				}
			}
		}
	}

	public final class Request: @unchecked Sendable {
		private let lock = NSLock()
		private let deadline: DispatchTime
		private var completion: ((Result<Attachment, Error>) -> Void)?
		private var timer: DispatchSourceTimer?
		private var session: URLSession?

		fileprivate init(completion: @escaping (Result<Attachment, Error>) -> Void) {
			deadline = .now() + RasheedNotificationImageLoader.timeout
			self.completion = completion
		}

		fileprivate var isActive: Bool {
			lock.lock()
			defer { lock.unlock() }
			return completion != nil && DispatchTime.now() < deadline
		}

		fileprivate func armDeadline() {
			let timer = DispatchSource.makeTimerSource(queue: RasheedNotificationImageLoader.deadlineQueue)
			timer.schedule(deadline: deadline, leeway: .nanoseconds(0))
			timer.setEventHandler { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
			lock.lock()
			self.timer = timer
			lock.unlock()
			timer.resume()
		}

		fileprivate func install(_ session: URLSession) -> Bool {
			lock.lock()
			let active = completion != nil
			if active { self.session = session }
			lock.unlock()
			if !active { session.invalidateAndCancel() }
			return active
		}

		public func cancel() { finish(.failure(URLError(.cancelled))) }

		fileprivate func finish(_ result: Result<Attachment, Error>) {
			lock.lock()
			guard let completion else { lock.unlock(); return }
			self.completion = nil
			let timer = self.timer
			self.timer = nil
			let session = self.session
			self.session = nil
			let timedOut = DispatchTime.now() >= deadline
			lock.unlock()
			timer?.cancel()
			// Neither cancellation nor fallback waits for synchronous image/file work or the main queue.
			completion(timedOut ? .failure(URLError(.timedOut)) : result)
			session?.invalidateAndCancel()
		}
	}

	@discardableResult
	public static func load(
		_ url: URL,
		hosts: Set<String>,
		completion: @escaping (Result<Attachment, Error>) -> Void
	) -> Request {
		let request = Request(completion: completion)
		request.armDeadline()
		workQueue.async {
			guard request.isActive else { return }
			guard RasheedNotificationImage.isAllowed(url, hosts: hosts) else {
				request.finish(.failure(RasheedNotificationImageError.disallowedURL))
				return
			}
			BoundedImageDownloader(request: request).start(url)
		}
		return request
	}

	public static func load(_ url: URL, hosts: Set<String>) async -> Attachment? {
		let pending = PendingRequest()
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				let request = load(url, hosts: hosts) { result in
					continuation.resume(returning: try? result.get())
				}
				pending.install(request)
			}
		} onCancel: { pending.cancel() }
	}

	private final class PendingRequest: @unchecked Sendable {
		private let lock = NSLock()
		private var request: Request?
		private var canceled = false

		func install(_ request: Request) {
			lock.lock()
			let canceled = self.canceled
			if !canceled { self.request = request }
			lock.unlock()
			if canceled { request.cancel() }
		}

		func cancel() {
			lock.lock()
			canceled = true
			let request = self.request
			self.request = nil
			lock.unlock()
			request?.cancel()
		}
	}

	private final class BoundedImageDownloader: NSObject, URLSessionDataDelegate {
		private let request: Request
		private var buffer = Data()
		private var imageType: UTType?

		init(request: Request) { self.request = request }

		func start(_ url: URL) {
			let configuration = URLSessionConfiguration.ephemeral
			configuration.timeoutIntervalForRequest = RasheedNotificationImageLoader.timeout
			configuration.timeoutIntervalForResource = RasheedNotificationImageLoader.timeout
			configuration.httpCookieStorage = nil
			configuration.httpShouldSetCookies = false
			configuration.urlCredentialStorage = nil
			configuration.urlCache = nil
			let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
			var download = URLRequest(url: url)
			download.timeoutInterval = RasheedNotificationImageLoader.timeout
			download.cachePolicy = .reloadIgnoringLocalCacheData
			let task = session.dataTask(with: download)
			guard request.install(session) else { return }
			task.resume()
		}

		func urlSession(_ session: URLSession, task: URLSessionTask,
			willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest,
			completionHandler: @escaping (URLRequest?) -> Void) {
			completionHandler(nil)
			request.finish(.failure(RasheedNotificationImageError.redirect))
		}

		func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
			didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
			guard request.isActive else { completionHandler(.cancel); return }
			guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
				completionHandler(.cancel)
				request.finish(.failure(RasheedNotificationImageError.badStatus))
				return
			}
			guard response.expectedContentLength <= Int64(RasheedNotificationImageLoader.maxBytes) else {
				completionHandler(.cancel)
				request.finish(.failure(RasheedNotificationImageError.tooLarge))
				return
			}
			guard let mimeType = response.mimeType, let type = UTType(mimeType: mimeType),
				[UTType.jpeg, .png, .gif, .heic].contains(type) else {
				completionHandler(.cancel)
				request.finish(.failure(RasheedNotificationImageError.unsupportedType))
				return
			}
			imageType = type
			completionHandler(.allow)
		}

		func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
			guard request.isActive else { return }
			guard data.count <= RasheedNotificationImageLoader.maxBytes - buffer.count else {
				request.finish(.failure(RasheedNotificationImageError.tooLarge))
				return
			}
			buffer.append(data)
		}

		func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
			guard request.isActive else { return }
			if let error { request.finish(.failure(error)); return }
			do { request.finish(.success(try makeAttachment())) }
			catch { request.finish(.failure(error)) }
		}

		private func makeAttachment() throws -> Attachment {
			guard !buffer.isEmpty else { throw RasheedNotificationImageError.empty }
			guard let type = imageType,
				let source = CGImageSourceCreateWithData(buffer as CFData, nil),
				let identifier = CGImageSourceGetType(source), UTType(identifier as String) == type else {
				throw RasheedNotificationImageError.unsupportedType
			}
			guard request.isActive else { throw URLError(.cancelled) }
			let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rasheed-notification-\(UUID().uuidString)")
			defer { try? FileManager.default.removeItem(at: directory) }
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
				attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
			let target = directory.appendingPathComponent("image.\(type.preferredFilenameExtension ?? "img")")
			try buffer.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
			guard request.isActive else { throw URLError(.cancelled) }
			let attachment = try UNNotificationAttachment(identifier: "rasheed-image", url: target,
				options: [UNNotificationAttachmentOptionsTypeHintKey: type.identifier])
			return Attachment(attachment)
		}
	}
}

enum RasheedNotificationImageError: Error, Sendable {
	case disallowedURL
	case redirect
	case badStatus
	case tooLarge
	case empty
	case unsupportedType
}

public enum RasheedNotificationImage {
	public static func isAllowed(_ url: URL, hosts: Set<String>) -> Bool {
		guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
			url.user == nil, url.password == nil, url.fragment == nil,
			url.port == nil || url.port == 443 else { return false }
		return hosts.contains { $0.lowercased() == host }
	}
}
