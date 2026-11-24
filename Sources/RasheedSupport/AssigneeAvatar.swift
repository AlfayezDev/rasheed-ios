import Combine
import Foundation
import SwiftUI
import UIKit
import os

struct AssigneeAvatarKey: Hashable {
	let generation: UInt64
	let conversationId: String
	let image: String
	var target: InboxTarget { InboxTarget(conversationId: conversationId, credentialGeneration: generation) }
}

@MainActor
final class AssigneeAvatarLease: ObservableObject {
	let key: AssigneeAvatarKey
	@Published private(set) var url: URL?
	private var file: RasheedAttachmentFile?
	private var releaseAction: (@MainActor @Sendable () -> Void)?

	init(key: AssigneeAvatarKey, file: RasheedAttachmentFile, release: @escaping @MainActor @Sendable () -> Void) {
		self.key = key
		self.file = file
		url = file.url
		releaseAction = release
	}

	func invalidate() { url = nil }

	func fileLease() -> RasheedAttachmentFile? { file }

	func release() {
		url = nil
		file = nil
		let action = releaseAction
		releaseAction = nil
		action?()
	}

	deinit {
		if let action = releaseAction { Task { @MainActor in action() } }
	}
}

@MainActor
final class AssigneeAvatarCache {
	private final class WeakLease {
		weak var value: AssigneeAvatarLease?
	}

	private final class Entry {
		let key: AssigneeAvatarKey
		var file: RasheedAttachmentFile?
		var task: Task<RasheedAttachmentFile, Error>?
		var leases: [UUID: WeakLease] = [:]
		var retired = false
		var ready = false
		var lastUsed: UInt64 = 0
		init(key: AssigneeAvatarKey) { self.key = key }
	}

	private var entries: [UUID: Entry] = [:]
	private var current: [AssigneeAvatarKey: UUID] = [:]
	private var clock: UInt64 = 0

	func acquire(client: RasheedClient, key: AssigneeAvatarKey) async throws -> AssigneeAvatarLease {
		guard client.assigneeImage(for: key.target) == key.image else { throw RasheedClientError.Canceled }
		let entryID: UUID
		let entry: Entry
		if let existing = current[key], let cached = entries[existing] {
			entryID = existing
			entry = cached
		} else {
			entryID = UUID()
			entry = Entry(key: key)
			entries[entryID] = entry
			current[key] = entryID
		}
		clock &+= 1
		entry.lastUsed = clock
		let leaseID = UUID()
		entry.leases[leaseID] = WeakLease()
		if entry.file == nil && entry.task == nil {
			entry.task = Task { @MainActor in
				let directory = try RasheedAttachmentFile.makeDirectory()
				let file = RasheedAttachmentFile(directory: directory, url: directory.appendingPathComponent("avatar"),
					fileName: "avatar", mimeType: "image/*", byteLength: 0)
				entry.file = file
				try await client.downloadAttachment(target: key.target, attachmentId: key.image, destinationPath: file.url.path)
				try Task.checkCancellation()
				guard !entry.retired, client.assigneeImage(for: key.target) == key.image else {
					throw RasheedClientError.Canceled
				}
				entry.ready = true
				return file
			}
		}
		do {
			let file: RasheedAttachmentFile
			if let task = entry.task { file = try await task.value }
			else if let cached = entry.file { file = cached }
			else { throw RasheedClientError.Failed(reason: "The private avatar is unavailable.") }
			entry.task = nil
			try Task.checkCancellation()
			guard !entry.retired, client.assigneeImage(for: key.target) == key.image else {
				throw RasheedClientError.Canceled
			}
			let lease = AssigneeAvatarLease(key: key, file: file) { [self] in
				release(entryID: entryID, leaseID: leaseID)
			}
			entry.leases[leaseID]?.value = lease
			prune()
			releaseUnused()
			return lease
		} catch {
			entry.task = nil
			if !entry.ready || client.assigneeImage(for: key.target) != key.image { retire(entryID) }
			release(entryID: entryID, leaseID: leaseID)
			throw error
		}
	}

	func reconcile(client: RasheedClient) {
		for (key, entryID) in current where client.assigneeImage(for: key.target) != key.image {
			retire(entryID)
		}
		releaseUnused()
	}

	func retireAll() {
		for entryID in Array(entries.keys) { retire(entryID) }
		releaseUnused()
	}

	private func retire(_ entryID: UUID) {
		guard let entry = entries[entryID], !entry.retired else { return }
		entry.retired = true
		if current[entry.key] == entryID { current.removeValue(forKey: entry.key) }
		entry.task?.cancel()
		for lease in entry.leases.values { lease.value?.invalidate() }
	}

	private func release(entryID: UUID, leaseID: UUID) {
		entries[entryID]?.leases.removeValue(forKey: leaseID)
		prune()
		releaseUnused()
	}

	private func prune() {
		let unused = entries.filter { !$0.value.retired && $0.value.leases.isEmpty && $0.value.task == nil }
			.sorted { $0.value.lastUsed > $1.value.lastUsed }
		for (entryID, _) in unused.dropFirst(16) { retire(entryID) }
	}

	func releaseUnused() {
		for (entryID, entry) in entries where entry.retired {
			guard entry.task == nil else { continue }
			entry.file = nil
			entries.removeValue(forKey: entryID)
		}
	}
}

@MainActor
struct RasheedAssigneeAvatar: View {
	let name: String
	let image: String?
	let target: InboxTarget?
	@ObservedObject var client: RasheedClient
	var size: CGFloat = 32
	let theme: RasheedSupportTheme
	@State private var lease: AssigneeAvatarLease?

	private struct Request: Equatable {
		let key: AssigneeAvatarKey?
		let matches: Bool
		let ready: Bool
	}

	private var publicURL: String? {
		guard let image, let url = URL(string: image), let scheme = url.scheme?.lowercased(),
			["https", "http"].contains(scheme), url.host != nil, url.user == nil, url.password == nil else { return nil }
		return url.absoluteString
	}

	private var key: AssigneeAvatarKey? {
		guard publicURL == nil, let image, !image.isEmpty, let target else { return nil }
		return AssigneeAvatarKey(generation: target.credentialGeneration, conversationId: target.conversationId, image: image)
	}

	var body: some View {
		RasheedAvatar(name: name, imageURL: publicURL, size: size, theme: theme)
			.overlay {
				if let lease, lease.key == key, client.assigneeImage(for: lease.key.target) == lease.key.image {
					AssigneeAvatarImage(lease: lease)
						.frame(width: size, height: size).clipShape(Circle())
				}
			}
			.task(id: Request(key: key, matches: key.map { client.assigneeImage(for: $0.target) == $0.image } ?? false,
				ready: client.snapshot.status == .ready && client.snapshot.profileState == .confirmed
					&& client.snapshot.uncertainIdentity == nil && client.inbox.readState == .confirmed)) {
				guard let key, client.assigneeImage(for: key.target) == key.image else {
					lease?.release()
					lease = nil
					return
				}
				if lease?.key == key, lease?.url != nil { return }
				lease?.release()
				lease = nil
				guard client.snapshot.status == .ready, client.snapshot.profileState == .confirmed,
					client.inbox.readState == .confirmed else { return }
				do {
					let acquired = try await client.assigneeAvatars.acquire(client: client, key: key)
					guard !Task.isCancelled, self.key == key else {
						acquired.release()
						return
					}
					lease = acquired
				} catch {
					if !Task.isCancelled {
						Logger(subsystem: "ai.rasheed.support", category: "avatars")
							.error("Private assignee avatar unavailable: \(error.localizedDescription, privacy: .private)")
					}
				}
			}
			.onDisappear {
				lease?.release()
				lease = nil
			}
			.accessibilityHidden(true)
	}
}

@MainActor
private struct AssigneeAvatarImage: View {
	@ObservedObject var lease: AssigneeAvatarLease
	@State private var image: UIImage?
	@State private var decodedURL: URL?

	var body: some View {
		Group {
			if let image, lease.url != nil, decodedURL == lease.url {
				Image(uiImage: image).resizable().scaledToFill()
			}
		}
		.task(id: lease.url) {
			image = nil
			decodedURL = nil
			guard let url = lease.url, let file = lease.fileLease() else { return }
			defer { withExtendedLifetime(file) {} }
			let decoded = await RasheedMediaImage.decodeThumbnail(at: url, maximumPixelSize: 256)
			guard !Task.isCancelled, lease.url == url else { return }
			image = decoded
			decodedURL = url
		}
	}
}
