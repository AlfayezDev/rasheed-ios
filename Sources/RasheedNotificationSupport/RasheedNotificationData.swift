import Foundation

/// Untrusted delivery metadata. Parsing does not establish current-customer authority.
public struct RasheedNotificationData: Sendable {
	public let workspaceID: String
	public let contactId: String
	public let pushEpoch: String
	public let pushSequence: UInt64
	public let conversationId: String?
	public let url: String?
	public let pushId: String?
	public let title: String?
	public let body: String?
	public let image: String?

	public init?(userInfo: [AnyHashable: Any]) {
		guard userInfo["rasheed"] as? String == "true",
			let workspace = Self.identifier(userInfo["workspaceId"]),
			let contact = Self.identifier(userInfo["contactId"]),
			let epoch = Self.identifier(userInfo["pushEpoch"], maximum: 256),
			let rawSequence = Self.text(userInfo["pushSequence"], maximum: 20),
			rawSequence.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
			let sequence = UInt64(rawSequence), String(sequence) == rawSequence
		else { return nil }
		if let value = userInfo["conversationId"], Self.identifier(value) == nil { return nil }
		if let value = userInfo["url"], Self.text(value, maximum: 2_048) == nil { return nil }
		workspaceID = workspace
		contactId = contact
		pushEpoch = epoch
		pushSequence = sequence
		conversationId = Self.identifier(userInfo["conversationId"])
		url = Self.text(userInfo["url"], maximum: 2_048)
		pushId = Self.text(userInfo["gcm.message_id"], maximum: 1_024)
			?? Self.text(userInfo["google.message_id"], maximum: 1_024)
		let alert = (userInfo["aps"] as? [String: Any])?["alert"]
		let fields = alert as? [String: Any]
		title = Self.text(fields?["title"], maximum: 512) ?? Self.text(userInfo["title"], maximum: 512)
		body = Self.text(fields?["body"], maximum: 4_096) ?? Self.text(alert, maximum: 4_096)
			?? Self.text(userInfo["body"], maximum: 4_096)
		image = Self.text(userInfo["image"], maximum: 2_048)
			?? Self.text((userInfo["fcm_options"] as? [String: Any])?["image"], maximum: 2_048)
	}

	private static func text(_ value: Any?, maximum: Int) -> String? {
		guard let value = value as? String, !value.isEmpty, value.utf8.count <= maximum,
			!value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
		return value
	}

	private static func identifier(_ value: Any?, maximum: Int = 128) -> String? {
		guard let value = text(value, maximum: maximum), !value.contains(where: \.isWhitespace) else { return nil }
		return value
	}

	public func belongs(to workspaceID: String?) -> Bool {
		workspaceID != nil && self.workspaceID == workspaceID
	}
}
