import CoreGraphics

/// Decides when the transcript scrolls. The transcript reports what happens to it: the scroll phase, whether its
/// end is in view, a new newest message, and the reader's own requests. It carries out `request`, the one scroll
/// asked for last, and never scrolls on its own.
///
/// Following is explicit: the reader stops it only by moving the transcript away from its end with a finger, and
/// resumes it by moving back to the end or asking for the latest message. While the reader is away, only their own
/// message moves the transcript.
struct RasheedFollow: Equatable {
	enum Phase: Equatable {
		/// Nothing moves the transcript.
		case idle
		/// A finger rests on the transcript without moving it.
		case touching
		/// A finger moves the transcript.
		case dragging
		/// The transcript still moves after the finger lifted, or under an animated scroll.
		case settling
	}

	enum Anchor: Equatable {
		case top, center, bottom
	}

	enum Target: Equatable {
		/// The true end of the transcript, its bottom edge below the newest row.
		case end
		/// A message the reader asked for, such as a quoted question.
		case message(String, anchor: Anchor)
	}

	struct Request: Equatable {
		/// Tells one request from the next one to the same target.
		let serial: Int
		let target: Target
		let animated: Bool
	}

	/// How near its end the transcript counts as at the end, in points.
	static let endTolerance: CGFloat = 1
	/// Scrolls to the end that one change may ask for: an arrival, an appearance, the reader's request.
	static let scrollsPerChange = 2

	private(set) var following = true
	private(set) var request: Request?
	private(set) var phase = Phase.idle
	private(set) var atEnd = true
	private var budget = scrollsPerChange
	/// A scroll to the end waits for the finger to lift and the transcript to come to rest.
	private var waiting = false
	/// The movement under way began with the reader's finger.
	private var readerMoved = false

	/// Whether a transcript `distance` points above its end counts as at the end.
	static func isAtEnd(distance: CGFloat) -> Bool {
		distance <= endTolerance
	}

	/// The transcript appeared, starting at its end, or came back from older history.
	mutating func appear() {
		following = true
		atEnd = true
		budget = Self.scrollsPerChange
		scrollToEnd(animated: false)
	}

	/// The reader asked for the latest message.
	mutating func showLatest(animated: Bool) {
		following = true
		budget = Self.scrollsPerChange
		scrollToEnd(animated: animated)
	}

	/// A new newest message. `own` is the contact's own message, the only one that moves a reader who is away.
	mutating func arrival(own: Bool) {
		budget = Self.scrollsPerChange
		if own {
			following = true
		} else if !following { return }
		scrollToEnd(animated: false)
	}

	/// The reader went to an older part of the transcript: a quoted message or older history.
	mutating func leave(to target: Target? = nil, animated: Bool = false) {
		following = false
		waiting = false
		if let target { issue(target, animated: animated) }
	}

	/// The scroll phase changed.
	mutating func phaseChanged(to phase: Phase) {
		self.phase = phase
		switch phase {
		case .dragging:
			readerMoved = true
		case .touching, .settling:
			break
		case .idle:
			if readerMoved {
				readerMoved = false
				budget = Self.scrollsPerChange
				setFollowing(atEnd)
			}
			if following && (waiting || !atEnd) {
				waiting = false
				scrollToEnd(animated: false)
			}
		}
	}

	/// The end of the transcript came into view or left it. Only a finger that moves the transcript decides that the
	/// reader left the end; a finger resting on it while a message arrives doesn't.
	mutating func endChanged(atEnd: Bool) {
		self.atEnd = atEnd
		if readerMoved {
			setFollowing(atEnd)
		} else if atEnd {
			setFollowing(true)
		} else if following {
			scrollToEnd(animated: false)
		}
	}

	/// iOS 16 and 17 report no scroll phase. There a move off the end is corrected within the budget, and once the
	/// budget is spent a move that no size change explains is taken as the reader's own.
	mutating func endChangedWithoutPhase(atEnd: Bool, resized: Bool) {
		self.atEnd = atEnd
		if atEnd {
			setFollowing(true)
		} else if following && budget > 0 {
			scrollToEnd(animated: false)
		} else if !resized {
			setFollowing(false)
		}
	}

	/// The viewport changed size, as when the keyboard, the composer or a banner comes or goes: a change of its own.
	mutating func viewportChanged() {
		if following { budget = Self.scrollsPerChange }
	}

	private mutating func setFollowing(_ following: Bool) {
		self.following = following
		if !following { waiting = false }
	}

	/// Asks for the end, never while a finger is down or the transcript moves, and at most `scrollsPerChange` times
	/// for one change, so size estimates that keep moving the end can't keep the transcript scrolling.
	private mutating func scrollToEnd(animated: Bool) {
		guard phase == .idle else {
			waiting = true
			return
		}
		guard budget > 0 else { return }
		budget -= 1
		issue(.end, animated: animated)
	}

	private mutating func issue(_ target: Target, animated: Bool) {
		request = Request(serial: (request?.serial ?? 0) + 1, target: target, animated: animated)
	}
}
