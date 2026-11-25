import SwiftUI

/// Up to two initials of a name, skipping name particles; one letter for an Arabic name.
func rasheedInitials(_ name: String) -> String {
	let words = name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
	guard !words.isEmpty else { return "?" }
	if name.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil {
		let particles: Set<String> = ["ال", "بن", "بنت", "ابن", "أبو", "ابو", "عبد"]
		let first = words.first(where: { !particles.contains($0) }) ?? name
		let stripped = first.replacingOccurrences(of: "^ال", with: "", options: .regularExpression)
		guard let initial = stripped.unicodeScalars.first(where: {
			let value = $0.value
			return !((0x064B...0x065F).contains(value) || value == 0x0670 || value == 0x0640)
		}) else { return "?" }
		return String(initial)
	}

	var parts: [String] = []
	var index = 0
	while index < words.count {
		let word = words[index]
		if ["bin", "ibn", "bint"].contains(word.lowercased()) {
			index += 2
			continue
		}
		if ["al", "el", "the"].contains(word.lowercased()) {
			index += 1
			continue
		}
		parts.append(word.replacingOccurrences(of: "^(al-|el-)", with: "", options: [.regularExpression, .caseInsensitive]))
		index += 1
	}
	let initials = [parts.first?.first, parts.count > 1 ? parts.last?.first : nil]
		.compactMap { $0 }
		.map(String.init)
		.joined()
		.uppercased()
	return initials.isEmpty ? "?" : initials
}

/// A round avatar: the person's picture when there is one, else their initials on a tint taken from their name.
struct RasheedAvatar: View {
	let name: String
	var imageURL: String?
	var size: CGFloat = 32
	let theme: RasheedSupportTheme

	var body: some View {
		let tint = theme.avatarTint(name)
		ZStack {
			tint.background
			Text(rasheedInitials(name))
				.font(RasheedFont.font(size: size * 3 / 7, weight: .medium))
				.foregroundStyle(tint.foreground)
				.minimumScaleFactor(0.7)
				.lineLimit(1)
			if let imageURL, let url = URL(string: imageURL), url.scheme?.hasPrefix("http") == true {
				AsyncImage(url: url) { phase in
					if let image = phase.image { image.resizable().scaledToFill() }
				}
			}
		}
		.frame(width: size, height: size)
		.clipShape(Circle())
		.accessibilityHidden(true)
	}
}

/// A ghost icon control (close, back, more): the bare icon in the muted ink at rest in a 44-point target, a tonal
/// circle of `diameter` only under the finger. The circle is `fill`, else the muted surface. Disabled, it fades to
/// 40%, as on the web.
struct RasheedIconButton: View {
	let systemName: String
	let label: String
	var identifier: String?
	var size: CGFloat = 17
	var weight: Font.Weight = .regular
	var diameter: CGFloat = 36
	var fill: Color?
	let theme: RasheedSupportTheme
	let action: () -> Void
	@Environment(\.isEnabled) private var isEnabled

	var body: some View {
		Button(action: action) {
			Image(systemName: systemName)
				.font(.system(size: size, weight: weight))
				.foregroundStyle(theme.muted)
				.frame(width: 44, height: 44)
				.contentShape(Rectangle())
				.opacity(isEnabled ? 1 : 0.4)
		}
		.buttonStyle(RasheedGhostStyle(fill: fill ?? theme.surfaceMuted, diameter: diameter))
		.accessibilityLabel(label)
		.rasheedIdentifier(identifier)
	}
}

extension View {
	@ViewBuilder func rasheedIdentifier(_ identifier: String?) -> some View {
		if let identifier { accessibilityIdentifier(identifier) } else { self }
	}
}

/// The web's primary button: full width, at least 48 high, its label at the start and, for a step forward, a chevron
/// at the end. Disabled, it takes the muted fill.
struct RasheedPrimaryButton: View {
	let title: String
	var identifier: String?
	var chevron = false
	var disabled = false
	let theme: RasheedSupportTheme
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			HStack(spacing: 12) {
				Text(title)
					.rasheed(.control)
					.frame(maxWidth: .infinity, alignment: .leading)
				if chevron {
					Image(systemName: "chevron.forward")
						.font(.system(size: 17, weight: .regular))
						.accessibilityHidden(true)
				}
			}
			.foregroundStyle(disabled ? theme.muted : theme.onAccent)
			.padding(.horizontal, 16)
			.padding(.vertical, 12)
			.frame(maxWidth: .infinity, minHeight: 48)
			.background(disabled ? theme.surfaceMuted : theme.accent,
				in: RoundedRectangle(cornerRadius: RasheedRadius.control, style: .continuous))
			.contentShape(Rectangle())
		}
		.buttonStyle(RasheedPressStyle(pressedOpacity: 0.9))
		.disabled(disabled)
		.rasheedIdentifier(identifier)
	}
}

/// The web's secondary button: the panel's fill in a hairline border, its label centred.
struct RasheedSecondaryButton: View {
	let title: String
	var identifier: String?
	var destructive = false
	var disabled = false
	let theme: RasheedSupportTheme
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			Text(title)
				.rasheed(.control)
				.foregroundStyle(disabled ? theme.muted : destructive ? theme.danger : theme.ink)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 12)
				.padding(.vertical, 8)
				.frame(maxWidth: .infinity, minHeight: 44)
				.background(disabled ? theme.surfaceMuted : theme.surface,
					in: RoundedRectangle(cornerRadius: RasheedRadius.control, style: .continuous))
				.rasheedBorder(theme.border, radius: RasheedRadius.control)
				.contentShape(Rectangle())
		}
		.buttonStyle(RasheedPressStyle(pressedOpacity: 0.9))
		.disabled(disabled)
		.rasheedIdentifier(identifier)
	}
}

/// Times and dates as the web shows them. Digits stay Latin in Arabic, as on the platform.
enum RasheedClock {
	static func locale(_ language: RasheedLanguage) -> Locale {
		Locale(identifier: language == .ar ? "ar@numbers=latn" : "en@numbers=latn")
	}

	/// Two-digit hours and minutes.
	static func time(_ milliseconds: Int, language: RasheedLanguage) -> String {
		formatter("hhmm", language: language).string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
	}

	/// The day and short month: lists, the open conversation and the transcript's date marker.
	static func date(_ milliseconds: Int, language: RasheedLanguage) -> String {
		formatter("MMMd", language: language).string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
	}

	/// The time for today, else the day and month.
	static func short(_ milliseconds: Int, language: RasheedLanguage, now: Date = Date()) -> String {
		let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
		if Calendar.current.isDate(date, inSameDayAs: now) { return time(milliseconds, language: language) }
		return formatter("MMMd", language: language).string(from: date)
	}

	/// As on the web: within a day "Now", "2 min. ago", "3 hr. ago"; then "Yesterday"; then the day and month. A
	/// standalone list item, so it starts with a capital.
	static func relative(_ milliseconds: Int, language: RasheedLanguage, now: Date = Date()) -> String {
		let date = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
		let elapsed = max(0, now.timeIntervalSince(date))
		let components: DateComponents
		if elapsed < 60 { components = DateComponents(second: 0) }
		else if elapsed < 3_600 { components = DateComponents(minute: -Int(elapsed / 60)) }
		else if elapsed < 86_400 { components = DateComponents(hour: -Int(elapsed / 3_600)) }
		else if let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now),
			Calendar.current.isDate(date, inSameDayAs: yesterday) { components = DateComponents(day: -1) }
		else { return self.date(milliseconds, language: language) }
		let text = relativeFormatter(language).localizedString(from: components)
		return text.prefix(1).uppercased(with: locale(language)) + text.dropFirst()
	}

	nonisolated(unsafe) private static var relativeFormatters: [RasheedLanguage: RelativeDateTimeFormatter] = [:]

	private static func relativeFormatter(_ language: RasheedLanguage) -> RelativeDateTimeFormatter {
		formattersLock.lock()
		defer { formattersLock.unlock() }
		if let cached = relativeFormatters[language] { return cached }
		let formatter = RelativeDateTimeFormatter()
		formatter.locale = locale(language)
		formatter.dateTimeStyle = .named
		formatter.unitsStyle = .short
		relativeFormatters[language] = formatter
		return formatter
	}

	/// One formatter per template and language: a list or a transcript asks for the same format on every update.
	nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
	private static let formattersLock = NSLock()

	private static func formatter(_ template: String, language: RasheedLanguage) -> DateFormatter {
		formattersLock.lock()
		defer { formattersLock.unlock() }
		let key = "\(template)|\(locale(language).identifier)"
		if let cached = formatters[key] { return cached }
		let formatter = DateFormatter()
		formatter.locale = locale(language)
		formatter.setLocalizedDateFormatFromTemplate(template)
		formatters[key] = formatter
		return formatter
	}
}

/// The web catalog's counted phrases, picked by CLDR plural category. Arabic uses all six categories and spells out
/// zero, one and two; the count keeps Latin digits.
enum RasheedCount {
	case newReplies, launcherUnread

	func text(_ count: Int, language: RasheedLanguage) -> String {
		let forms = language == .ar ? arabic : english
		let category: Int
		if language == .ar {
			let hundreds = count % 100
			category = count == 0 ? 0 : count == 1 ? 1 : count == 2 ? 2
				: (3...10).contains(hundreds) ? 3 : (11...99).contains(hundreds) ? 4 : 5
		} else {
			category = count == 1 ? 1 : 5
		}
		let number = count.formatted(.number.locale(RasheedClock.locale(language)))
		return forms[category].replacingOccurrences(of: "{n}", with: number)
	}

	/// zero, one, two, few, many, other.
	private var english: [String] {
		switch self {
		case .newReplies: ["{n} new replies", "1 new reply", "{n} new replies", "{n} new replies", "{n} new replies", "{n} new replies"]
		case .launcherUnread: ["Support, {n} new replies", "Support, 1 new reply", "Support, {n} new replies",
			"Support, {n} new replies", "Support, {n} new replies", "Support, {n} new replies"]
		}
	}

	private var arabic: [String] {
		switch self {
		case .newReplies: ["لا توجد ردود جديدة", "رد جديد واحد", "ردان جديدان", "{n} ردود جديدة", "{n} ردًا جديدًا", "{n} رد جديد"]
		case .launcherUnread: ["الدعم، لا توجد ردود جديدة", "الدعم، رد جديد واحد", "الدعم، ردان جديدان",
			"الدعم، {n} ردود جديدة", "الدعم، {n} ردًا جديدًا", "الدعم، {n} رد جديد"]
		}
	}
}
