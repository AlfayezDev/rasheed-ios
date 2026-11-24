import CoreText
import os
import SwiftUI
import UIKit

/// The web widget's palette, with its role names, so a token reads the same on every platform.
struct RasheedSupportTheme {
	let isDark: Bool
	let surface: Color
	let surfaceMuted: Color
	let ink: Color
	let muted: Color
	let border: Color
	/// The label on an accent fill.
	let onAccent: Color
	let danger: Color

	/// The primary fill is the ink, as on the web.
	var accent: Color { ink }
	/// The inset hairline on images: black 10% in light, white 10% in dark, never tinted.
	var imageEdge: Color { isDark ? .white.opacity(0.1) : .black.opacity(0.1) }

	static func resolve(_ scheme: ColorScheme) -> RasheedSupportTheme {
		scheme == .dark ? .dark : .light
	}

	static let dark = RasheedSupportTheme(
		isDark: true,
		surface: Color(hex: 0x141416), surfaceMuted: Color(hex: 0x26262A),
		ink: Color(hex: 0xEDEDEF), muted: Color(oklch: 0.642, 0.013, 286.002), border: Color(hex: 0x2E2E33),
		onAccent: Color(hex: 0x141416), danger: Color(hex: 0xF06A5F)
	)

	static let light = RasheedSupportTheme(
		isDark: false,
		surface: Color(hex: 0xFFFFFF), surfaceMuted: Color(hex: 0xF4F4F5),
		ink: Color(hex: 0x18181B), muted: Color(hex: 0x6F6F79), border: Color(hex: 0xE2E2E6),
		onAccent: Color(hex: 0xFFFFFF), danger: Color(hex: 0xBB2F28)
	)

	/// A name's avatar colours: a hue from its characters, held to a low chroma so a row of avatars reads as one set.
	func avatarTint(_ name: String) -> (background: Color, foreground: Color) {
		let hue = Self.avatarHue(name)
		return isDark
			? (Color(oklch: 0.42, 0.018, hue), Color(oklch: 0.92, 0.01, hue))
			: (Color(oklch: 0.86, 0.015, hue), Color(oklch: 0.34, 0.02, hue))
	}

	/// The web's and Android's hash over UTF-16 code units: `h = (h * 37 + c) % 360`, starting at 7.
	static func avatarHue(_ name: String) -> Double {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		var hue = 7
		for unit in trimmed.utf16 { hue = (hue * 37 + Int(unit)) % 360 }
		return Double(hue)
	}
}

extension RasheedTheme {
	/// The appearance the host app chose, or nil to follow the system's.
	var colorScheme: ColorScheme? {
		switch self {
		case .system: nil
		case .light: .light
		case .dark: .dark
		}
	}
}

extension Color {
	init(hex: UInt32) {
		self.init(
			.sRGB,
			red: Double((hex >> 16) & 0xFF) / 255,
			green: Double((hex >> 8) & 0xFF) / 255,
			blue: Double(hex & 0xFF) / 255
		)
	}

	/// CSS `oklch(L C h)` in sRGB.
	init(oklch lightness: Double, _ chroma: Double, _ hue: Double) {
		let radians = hue * .pi / 180
		let a = chroma * cos(radians)
		let b = chroma * sin(radians)
		let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
		let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
		let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
		func encode(_ linear: Double) -> Double {
			let clamped = min(max(linear, 0), 1)
			return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
		}
		self.init(
			.sRGB,
			red: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
			green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
			blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
		)
	}
}

/// Corner radii, as on the web: 6 the logo and placeholders, 8 controls, 10 cards and file rows, 18 the composer.
enum RasheedRadius {
	static let chip: CGFloat = 6
	static let control: CGFloat = 8
	static let card: CGFloat = 10
	static let composer: CGFloat = 18
}

/// IBM Plex Sans Arabic in the web widget's three weights: one face for both scripts, with tabular figures. The faces
/// ship with the SDK under the OFL and register for this process on first use; a face that is unavailable falls back
/// to the system font.
enum RasheedFont {
	private static let logger = Logger(subsystem: "io.rasheed.support", category: "fonts")
	private static let registration: Void = {
		let urls = ["RasheedPlex-Regular", "RasheedPlex-Medium", "RasheedPlex-SemiBold"].compactMap {
			Bundle.module.url(forResource: $0, withExtension: "ttf", subdirectory: "Fonts")
		}
		CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, _ in
			for case let error as NSError in errors as NSArray
			where error.code != CTFontManagerError.alreadyRegistered.rawValue {
				logger.error("A bundled font could not be registered: \(error.localizedDescription, privacy: .public)")
			}
			return true
		}
	}()
	nonisolated(unsafe) private static var faces: [String: UIFont] = [:]
	private static let facesLock = NSLock()

	static func font(size: CGFloat, weight: Font.Weight) -> Font {
		let name = switch weight {
		case .semibold, .bold, .heavy, .black: "RasheedPlex-SemiBold"
		case .medium: "RasheedPlex-Medium"
		default: "RasheedPlex-Regular"
		}
		guard let face = face(name) else { return .system(size: size, weight: weight) }
		return Font(face.withSize(size) as CTFont)
	}

	private static func face(_ name: String) -> UIFont? {
		_ = registration
		facesLock.lock()
		defer { facesLock.unlock() }
		if let face = faces[name] { return face }
		faces[name] = UIFont(name: name, size: 17)
		return faces[name]
	}
}

/// The web widget's type scale. Each role scales with Dynamic Type up to 1.8 times, so a row keeps its shape, and Arabic
/// text never sets under 12 points. Plex sets lines at 1.5 times their size, the web's default line height.
enum RasheedType {
	/// Home's question.
	case hero
	/// A screen's own title: Messages, Support settings.
	case heading
	/// The workspace name in the header.
	case title
	/// Messages, the composer and the open conversation's preview.
	case body
	/// Buttons, tabs and the language toggle.
	case control
	/// Running text: list previews and the profile.
	case sub
	/// Status and error lines, conversation details and authors.
	case meta
	/// Times, the date marker, quotes and file details.
	case caption
	/// The character counter and file names.
	case mono

	var size: CGFloat {
		switch self {
		case .hero: 24
		case .heading: 20
		case .title: 15
		case .body: 16
		case .control, .sub: 14
		case .meta: 13
		case .caption: 12
		case .mono: 11.5
		}
	}

	var weight: Font.Weight {
		switch self {
		case .hero, .heading, .title: .semibold
		case .control: .medium
		default: .regular
		}
	}

	/// The role's font at a Dynamic Type `scale`, for text built from runs.
	func font(scale: CGFloat, weight: Font.Weight? = nil, arabic: Bool = false) -> Font {
		let size = (arabic ? max(size, 12) : size) * min(scale, 1.8)
		if self == .mono { return .system(size: size, weight: weight ?? self.weight, design: .monospaced) }
		return RasheedFont.font(size: size, weight: weight ?? self.weight)
	}
}

private struct RasheedTypeModifier: ViewModifier {
	let role: RasheedType
	let weight: Font.Weight?
	@ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
	@Environment(\.rasheedArabic) private var arabic
	@Environment(\.legibilityWeight) private var legibility

	/// Bold Text steps each bundled face up one weight, as the system font does.
	private var shownWeight: Font.Weight? {
		guard legibility == .bold else { return weight }
		switch weight ?? role.weight {
		case .regular: return .medium
		case .medium: return .semibold
		default: return weight
		}
	}

	func body(content: Content) -> some View {
		content.font(role.font(scale: scale, weight: shownWeight, arabic: arabic))
	}
}

private struct RasheedArabicKey: EnvironmentKey {
	static let defaultValue = false
}

extension EnvironmentValues {
	/// The support UI is in Arabic, so no text sets under 12 points.
	var rasheedArabic: Bool {
		get { self[RasheedArabicKey.self] }
		set { self[RasheedArabicKey.self] = newValue }
	}
}

extension View {
	func rasheed(_ role: RasheedType, weight: Font.Weight? = nil) -> some View {
		modifier(RasheedTypeModifier(role: role, weight: weight))
	}

	/// A border drawn inside the shape, so the stroke does not grow the layout.
	func rasheedBorder(_ color: Color, radius: CGFloat, width: CGFloat = 1) -> some View {
		overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(color, lineWidth: width))
	}

	func rasheedClip(_ radius: CGFloat) -> some View {
		clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
	}

	/// The field keeps the panel's fill and one contained border, which darkens while it has focus.
	func rasheedField(focused: Bool, radius: CGFloat, theme: RasheedSupportTheme) -> some View {
		background(theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
			.rasheedBorder(focused ? theme.muted : theme.border, radius: radius)
	}
}

/// Two contained tones keep keyboard focus visible on both primary fills and arbitrary image pixels.
private struct RasheedKeyboardFocus: ViewModifier {
	let radius: CGFloat
	@Environment(\.isFocused) private var focused
	@Environment(\.isEnabled) private var enabled
	@Environment(\.colorScheme) private var colorScheme
	@Environment(\.colorSchemeContrast) private var contrast

	func body(content: Content) -> some View {
		let theme = RasheedSupportTheme.resolve(colorScheme)
		let width: CGFloat = contrast == .increased ? 3 : 2
		content.overlay {
			if focused && enabled {
				ZStack {
					RoundedRectangle(cornerRadius: radius, style: .continuous)
						.strokeBorder(theme.surface, lineWidth: width * 2)
					RoundedRectangle(cornerRadius: radius, style: .continuous)
						.inset(by: width / 2)
						.strokeBorder(theme.ink, lineWidth: width)
				}
				.allowsHitTesting(false)
				.accessibilityHidden(true)
			}
		}
	}
}

/// A ghost control: nothing behind the icon at rest; under the finger a circle of `fill` fades in for 120 ms. Reduced
/// motion keeps the feedback in the icon's opacity and draws no fill.
struct RasheedGhostStyle: ButtonStyle {
	let fill: Color
	var diameter: CGFloat = 30
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background {
				Circle()
					.fill(fill)
					.frame(width: diameter, height: diameter)
					.opacity(configuration.isPressed && !reduceMotion ? 1 : 0)
			}
			.opacity(configuration.isPressed && reduceMotion ? 0.6 : 1)
			.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
			.modifier(RasheedKeyboardFocus(radius: RasheedRadius.control))
	}
}

/// Controls respond in opacity; media can opt into a scale, disabled by Reduced Motion.
struct RasheedPressStyle: ButtonStyle {
	var scale: CGFloat = 1
	var radius: CGFloat = RasheedRadius.control
	var pressedOpacity: Double = 0.7
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
			.opacity(configuration.isPressed ? pressedOpacity : 1)
			.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
			.modifier(RasheedKeyboardFocus(radius: radius))
	}
}

/// A list row or text control, as on the web: under the finger and around keyboard focus, the muted fill in a
/// rounded surface that reaches `outset` past the label on each side and stays `inset` inside its top and bottom.
struct RasheedRowStyle: ButtonStyle {
	let theme: RasheedSupportTheme
	var radius: CGFloat = RasheedRadius.card
	var outset: CGFloat = 8
	var inset: CGFloat = 4
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background {
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.fill(theme.surfaceMuted.opacity(configuration.isPressed ? 1 : 0))
					.padding(.horizontal, -outset)
					.padding(.vertical, inset)
			}
			.overlay {
				Color.clear
					.padding(.horizontal, -outset)
					.padding(.vertical, inset)
					.modifier(RasheedKeyboardFocus(radius: radius))
			}
			.animation(configuration.isPressed || reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
	}
}

/// A card or row that takes the tonal fill under the finger.
struct RasheedCardStyle: ButtonStyle {
	let theme: RasheedSupportTheme
	let radius: CGFloat
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.overlay(
				RoundedRectangle(cornerRadius: radius, style: .continuous)
					.fill(theme.ink.opacity(configuration.isPressed ? 0.05 : 0))
			)
			.animation(configuration.isPressed || reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
			.modifier(RasheedKeyboardFocus(radius: radius))
	}
}
