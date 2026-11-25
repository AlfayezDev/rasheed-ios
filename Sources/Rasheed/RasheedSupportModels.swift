import RasheedCore
import Foundation

/// Messages order by `(createdAt, id)` in the transcript's visibility checks; ids compare by UTF-16 code unit.
public struct RasheedMessageCursor: Sendable, Equatable, Comparable {
	public let at: Int
	public let id: String

	public init(at: Int, id: String) {
		self.at = at
		self.id = id
	}

	public static func < (left: Self, right: Self) -> Bool {
		if left.at != right.at { return left.at < right.at }
		return left.id.utf16.lexicographicallyPrecedes(right.id.utf16)
	}
}

public struct RasheedSupportAssignee: Sendable, Equatable {
	public let name: String
	public let image: String?
}

public struct RasheedSupportConversation: Sendable, Equatable, Identifiable {
	public let conversationId: String
	public let conversationStatus: String
	public let lastMessageAt: Int?
	public let lastMessageAuthorKind: String?
	public let lastMessagePreview: String?
	public let createdAt: Int
	/// The teammate the conversation is assigned to, or nil while it has none.
	public let assignee: RasheedSupportAssignee?
	/// Replies the customer hasn't seen yet.
	public let unread: Int
	/// The name of the latest message's author, when one is known.
	public let lastAuthorName: String?
	public var id: String { conversationId }
}

public struct RasheedSupportAttachment: Sendable, Equatable, Identifiable {
	public enum Kind: String, Sendable {
		case image, video, audio, document
	}

	public let id: String
	public let fileName: String
	public let mimeType: String
	public let byteLength: Int
	public var name: String? { fileName }
	public var kind: Kind {
		if mimeType.hasPrefix("image/") { return .image }
		if mimeType.hasPrefix("video/") { return .video }
		if mimeType.hasPrefix("audio/") { return .audio }
		return .document
	}

	init(_ wire: RasheedCore.InboxAttachment) {
		id = wire.id
		fileName = wire.name
		mimeType = wire.mimeType
		byteLength = Int(wire.byteLength)
	}
}

public struct RasheedSupportMessage: Sendable, Equatable {
	public let id: String
	public let conversationId: String
	/// `contact`, `member` or `automation`.
	public let authorKind: String
	public let authorMemberId: String
	public let authorDisplayName: String?
	public let body: String
	/// Milliseconds since 1970.
	public let createdAt: Int
	/// The database's order within the conversation; 0 for a message it has not stored.
	public var seq = 0
	public var replyTo: RasheedSupportReply?
	public var attachments: [RasheedSupportAttachment] = []
	public var cursor: RasheedMessageCursor { RasheedMessageCursor(at: createdAt, id: id) }

	init(id: String, conversationId: String, authorKind: String, authorMemberId: String,
		authorDisplayName: String?, body: String, createdAt: Int, seq: Int = 0, replyTo: RasheedSupportReply? = nil,
		attachments: [RasheedSupportAttachment] = []) {
		self.id = id
		self.conversationId = conversationId
		self.authorKind = authorKind
		self.authorMemberId = authorMemberId
		self.authorDisplayName = authorDisplayName
		self.body = body
		self.createdAt = createdAt
		self.seq = seq
		self.replyTo = replyTo
		self.attachments = attachments
	}
}

public struct RasheedSupportReply: Sendable, Equatable {
	public let id: String
	public let createdAt: Int
	public let authorKind: String
	public let authorDisplayName: String?
	public let body: String
}

extension RasheedSupportReply {
	init(_ message: RasheedSupportMessage) {
		self.init(id: message.id, createdAt: message.createdAt, authorKind: message.authorKind,
			authorDisplayName: message.authorDisplayName, body: String(message.body.prefix(240)))
	}
}

extension RasheedCore.InboxAuthor {
	/// The kinds the transcript tells apart; the database's system notices read as automated messages.
	var sdkValue: String {
		switch self {
		case .contact: "contact"
		case .member: "member"
		case .system: "automation"
		}
	}
}

func microsToMillis(_ stamp: Int64) -> Int {
	Int(stamp / 1_000)
}
