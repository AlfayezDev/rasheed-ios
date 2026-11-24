import Foundation

// The lock protects leases, core pins and failed deletions, including releases from detached copies.
final class InboxFilePool: @unchecked Sendable {
	static let shared = InboxFilePool()
	static let cleanupChanged = Notification.Name("ai.rasheed.support.private-file-cleanup")

	struct Scope: Hashable, Sendable {
		let platform: String
		let workspace: String
	}

	struct Metadata: Sendable {
		let directory: URL
		let url: URL
		let name: String
		let mimeType: String
		let byteLength: Int
	}

	private struct CoreOwner {
		var generation: UInt64
		var selections: Set<UUID> = []
	}

	private final class Entry {
		let metadata: Metadata
		var leases: Set<UUID> = []
		var coreOwners: [Scope: CoreOwner] = [:]
		var failure: RasheedClientError?
		init(metadata: Metadata) { self.metadata = metadata }
	}

	private let lock = NSLock()
	private var entries: [String: Entry] = [:]

	private init() {}

	private func path(_ url: URL) -> String { url.standardizedFileURL.path }

	func register(_ metadata: Metadata) -> UUID {
		lock.lock()
		defer { lock.unlock() }
		let key = path(metadata.url)
		let entry = entries[key] ?? Entry(metadata: metadata)
		let token = UUID()
		entry.leases.insert(token)
		entries[key] = entry
		return token
	}

	func lease(path: String) -> RasheedAttachmentFile? {
		lock.lock()
		defer { lock.unlock() }
		guard let entry = entries[self.path(URL(fileURLWithPath: path))] else { return nil }
		let token = UUID()
		entry.leases.insert(token)
		return RasheedAttachmentFile(metadata: entry.metadata, token: token)
	}

	func release(url: URL, token: UUID) {
		mutate {
			entries[path(url)]?.leases.remove(token)
			deleteUnused()
		}
	}

	func retainCore(file: RasheedAttachmentFile, scope: Scope, generation: UInt64) {
		lock.lock()
		defer { lock.unlock() }
		guard let entry = entries[path(file.url)] else { preconditionFailure("A live private-file lease must be registered.") }
		var owner = entry.coreOwners[scope] ?? CoreOwner(generation: generation)
		owner.generation = max(owner.generation, generation)
		entry.coreOwners[scope] = owner
	}

	func beginSelection(files: [RasheedAttachmentFile], scope: Scope, generation: UInt64) -> UUID {
		lock.lock()
		defer { lock.unlock() }
		let token = UUID()
		for file in files {
			guard let entry = entries[path(file.url)] else { preconditionFailure("A live private-file lease must be registered.") }
			var owner = entry.coreOwners[scope] ?? CoreOwner(generation: generation)
			owner.generation = max(owner.generation, generation)
			owner.selections.insert(token)
			entry.coreOwners[scope] = owner
		}
		return token
	}

	func endSelection(_ token: UUID, scope: Scope) {
		lock.lock()
		defer { lock.unlock() }
		for entry in entries.values {
			guard var owner = entry.coreOwners[scope] else { continue }
			owner.selections.remove(token)
			entry.coreOwners[scope] = owner
		}
	}

	func reconcileCore(scope: Scope, generation: UInt64, references: Set<String>, confirmed: Bool) {
		let referenced = Set(references.map { path(URL(fileURLWithPath: $0)) })
		mutate {
			for (key, entry) in entries where !referenced.contains(key) {
				guard let owner = entry.coreOwners[scope], owner.selections.isEmpty else { continue }
				// An unknown identity can hide a journal without releasing its files.
				if confirmed || owner.generation < generation { entry.coreOwners.removeValue(forKey: scope) }
			}
			deleteUnused()
		}
	}

	func recordFailure(url: URL, error: Error) {
		mutate { entries[path(url)]?.failure = .Storage(reason: error.localizedDescription) }
	}

	var cleanupError: RasheedClientError? {
		lock.lock()
		defer { lock.unlock() }
		return failureLocked()
	}

	@discardableResult
	func retryCleanup() -> RasheedClientError? {
		mutate { deleteUnused() }
		return cleanupError
	}

	private func failureLocked() -> RasheedClientError? {
		entries.keys.sorted().compactMap { entries[$0]?.failure }.first
	}

	private func mutate(_ operation: () -> Void) {
		lock.lock()
		let before = failureLocked()
		operation()
		let changed = before != failureLocked()
		lock.unlock()
		if changed { NotificationCenter.default.post(name: Self.cleanupChanged, object: nil) }
	}

	private func deleteUnused() {
		for (key, entry) in entries where entry.leases.isEmpty && entry.coreOwners.isEmpty {
			do {
				try FileManager.default.removeItem(at: entry.metadata.directory)
				entries.removeValue(forKey: key)
			} catch {
				let failure = error as NSError
				if failure.domain == NSCocoaErrorDomain
					&& (failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError) {
					entries.removeValue(forKey: key)
				} else {
					entry.failure = .Storage(reason: error.localizedDescription)
				}
			}
		}
	}
}
