import RasheedNotificationSupport

public typealias RasheedNotificationData = RasheedNotificationSupport.RasheedNotificationData
public typealias RasheedNotificationImage = RasheedNotificationSupport.RasheedNotificationImage
public typealias RasheedNotificationImageLoader = RasheedNotificationSupport.RasheedNotificationImageLoader

extension RasheedNotificationData {
	func matches(_ scope: PushScope) -> Bool {
		workspaceID == scope.workspaceId && contactId == scope.contactId
			&& pushEpoch == scope.epoch && pushSequence == scope.sequence
	}
}

@MainActor
public final class RasheedNotificationDedupe {
	private var order: [String] = []
	private var seen: Set<String> = []
	private let limit: Int

	public init(limit: Int = 256) { self.limit = min(max(limit, 1), 256) }

	public func remember(_ id: String) -> Bool {
		guard !seen.contains(id) else { return false }
		seen.insert(id)
		order.append(id)
		if order.count > limit { seen.remove(order.removeFirst()) }
		return true
	}
}
