import Foundation
import CoreTransferable
import UniformTypeIdentifiers
public final class RasheedAttachmentFile: Sendable {
	/// One message carries up to ten files and 50 MiB in all, and a single file may use the whole allowance.
	public static let maximumBytes = 50 * 1024 * 1024
	public static let maximumCount = 10
	public let url: URL
	public let fileName: String
	public let mimeType: String
	public let byteLength: Int
	private let token: UUID

	convenience init(directory: URL, url: URL, fileName: String, mimeType: String, byteLength: Int) {
		let metadata = InboxFilePool.Metadata(directory: directory, url: url, name: fileName,
			mimeType: mimeType, byteLength: byteLength)
		self.init(metadata: metadata, token: InboxFilePool.shared.register(metadata))
	}

	init(metadata: InboxFilePool.Metadata, token: UUID) {
		url = metadata.url
		fileName = metadata.name
		mimeType = metadata.mimeType
		byteLength = metadata.byteLength
		self.token = token
	}

	deinit { InboxFilePool.shared.release(url: url, token: token) }

	static func lease(path: String) -> RasheedAttachmentFile? {
		InboxFilePool.shared.lease(path: path)
	}

	static func makeDirectory() throws -> URL {
		let root = try privateRoot()
		let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
			attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
		return directory
	}

	private static func privateRoot() throws -> URL {
		try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
			appropriateFor: nil, create: true).appendingPathComponent("ai.rasheed.support.media", isDirectory: true)
	}

	static func restored(path: String, attachment: RasheedSupportAttachment) throws -> RasheedAttachmentFile? {
		let url = URL(fileURLWithPath: path).standardizedFileURL
		let directory = url.deletingLastPathComponent()
		guard directory.deletingLastPathComponent() == (try privateRoot()).standardizedFileURL,
			UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
		return RasheedAttachmentFile(directory: directory, url: url, fileName: attachment.fileName,
			mimeType: attachment.mimeType, byteLength: attachment.byteLength)
	}

	static func safeName(_ name: String) -> String {
		let cleaned = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\\"".unicodeScalars.contains($0) }
		let result = String(String.UnicodeScalarView(cleaned)).prefix(180)
		return result.isEmpty || result == "." || result == ".." ? "attachment" : String(result)
	}

	static func copy(from source: URL, named override: String? = nil, mimeType overrideMime: String? = nil, maximumBytes: Int = RasheedAttachmentFile.maximumBytes) throws -> RasheedAttachmentFile {
		guard source.isFileURL, maximumBytes > 0 else { throw RasheedSupportError.invalidRequest }
		let scoped = source.startAccessingSecurityScopedResource()
		defer { if scoped { source.stopAccessingSecurityScopedResource() } }
		let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentTypeKey])
		guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RasheedSupportError.invalidRequest }
		guard let size = values.fileSize, size > 0, size <= maximumBytes else { throw RasheedSupportError.attachmentLimit }
		let name = safeName(override ?? source.lastPathComponent)
		let mime = overrideMime ?? (values.contentType ?? UTType(filenameExtension: source.pathExtension))?.preferredMIMEType ?? "application/octet-stream"
		let directory = try makeDirectory()
		let target = directory.appendingPathComponent(name)
		let file = RasheedAttachmentFile(directory: directory, url: target, fileName: name, mimeType: mime, byteLength: size)
		defer { withExtendedLifetime(file) {} }
		guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
		let input = try FileHandle(forReadingFrom: source)
		defer {
			do { try input.close() }
			catch { InboxFilePool.shared.recordFailure(url: target, error: error) }
		}
		let output = try FileHandle(forWritingTo: target)
		defer {
			do { try output.close() }
			catch { InboxFilePool.shared.recordFailure(url: target, error: error) }
		}
		var count = 0
		while let data = try input.read(upToCount: 65_536), !data.isEmpty {
			try Task.checkCancellation()
			count += data.count
			guard count <= maximumBytes else { throw RasheedSupportError.attachmentLimit }
			try output.write(contentsOf: data)
		}
		guard count == size else { throw RasheedSupportError.invalidRequest }
		try output.synchronize()
		return file
	}
}

struct RasheedPickedFile: Transferable {
	let file: RasheedAttachmentFile
	static var transferRepresentation: some TransferRepresentation {
		FileRepresentation(importedContentType: .data) { received in
			RasheedPickedFile(file: try RasheedAttachmentFile.copy(from: received.file))
		}
	}
}

public struct RasheedPendingAttachment: Identifiable, Sendable {
	public let id: String
	public let file: RasheedSupportAttachment
	public let ready: Bool
	public let uploading: Bool
	public let failed: Bool
}
