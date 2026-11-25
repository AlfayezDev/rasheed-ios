import AVKit
import QuickLook
import SwiftUI

/// A downloaded attachment: a thumbnail in the transcript's tile, or the full file in the lightbox. Loading and failure
/// are fills, never outlines: a tile keeps its size and says what failed with one way to try again.
struct RasheedAttachmentView: View {
	let attachment: RasheedSupportAttachment
	@ObservedObject var model: RasheedSupportModel
	let theme: RasheedSupportTheme
	var expanded = false
	/// Bumped by the tile that holds a thumbnail, whose tap retries a failed download.
	var retry = 0
	/// Tells the tile whether the download failed, so its tap retries instead of opening the lightbox.
	var onFailedChange: ((Bool) -> Void)?
	@Binding var isZoomed: Bool
	@State private var file: RasheedAttachmentFile?
	@State private var error: Error?
	@State private var attempt = 0
	@State private var player: AVPlayer?
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	private enum Phase { case loading, failed, ready }

	private var phase: Phase { file != nil ? .ready : error != nil ? .failed : .loading }

	var body: some View {
		ZStack {
			switch phase {
			case .ready:
				if let file { loaded(file).transition(.opacity) }
			case .failed:
				Group { if expanded { lightboxFailure } else { tileFailure } }
					.transition(.opacity)
			case .loading:
				Group {
					if expanded {
						ProgressView().tint(.white.opacity(0.7))
					} else {
						ZStack {
							theme.surfaceMuted
							ProgressView().controlSize(.small).tint(theme.muted)
						}
					}
				}
				.transition(.opacity)
			}
		}
		.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: phase)
		.task(id: "\(model.contentRevision)-\(attempt)-\(retry)") {
			error = nil
			do {
				let downloaded = try await model.download(attachment)
				try Task.checkCancellation()
				file = downloaded
				if expanded && (attachment.kind == .video || attachment.kind == .audio) {
					player = AVPlayer(url: downloaded.url)
				}
			} catch {
				if !Task.isCancelled { self.error = error }
			}
		}
		// A tile recreated while its parent still holds an earlier failure reports its own state from the start.
		.onAppear { onFailedChange?(phase == .failed) }
		.onChange(of: phase == .failed) { failed in onFailedChange?(failed) }
		.onDisappear {
			player?.pause()
			player = nil
			file = nil
		}
	}

	@ViewBuilder private func loaded(_ file: RasheedAttachmentFile) -> some View {
		VStack(spacing: 12) {
			if attachment.kind == .image {
				if expanded { ZoomableImagePage(value: file.url, theme: theme, isZoomed: $isZoomed) }
				else { RasheedMediaImage(value: file.url, theme: theme, maximumPixelSize: 512) }
			} else if let player {
				VideoPlayer(player: player)
			} else if expanded {
				AttachmentDocumentPreview(url: file.url)
			}
			if expanded {
				ShareLink(item: file.url) {
					Label(localized("Save or share", "حفظ أو مشاركة"), systemImage: "square.and.arrow.up")
						.frame(minHeight: 44)
				}
				.foregroundStyle(.white)
			}
		}
		.foregroundStyle(expanded ? .white : theme.ink)
	}

	private var failureSymbol: String {
		attachment.kind == .video ? "video.slash" : "photo.badge.exclamationmark"
	}

	/// A transcript tile that failed: the symbol, what happened and Retry, as much of it as the tile's height holds. The
	/// tile's own tap retries; the capsule shows where.
	private var tileFailure: some View {
		ZStack {
			theme.surfaceMuted
			ViewThatFits(in: .vertical) {
				VStack(spacing: 6) {
					failureIcon
					Text(couldNotLoadText)
						.rasheed(.meta)
						.foregroundStyle(theme.muted)
						.lineLimit(1)
					retryCapsule
				}
				VStack(spacing: 4) {
					failureIcon
					retryCapsule
				}
				retryCapsule
			}
			.padding(6)
		}
		.accessibilityHidden(true)
	}

	private var failureIcon: some View {
		Image(systemName: failureSymbol)
			.font(.system(size: 20, weight: .regular))
			.foregroundStyle(theme.muted)
	}

	/// Retry with its label, or the arrow alone when a narrow tile can't hold the word whole.
	private var retryCapsule: some View {
		ViewThatFits(in: .horizontal) {
			HStack(spacing: 4) {
				Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
				Text(retryText).rasheed(.meta, weight: .medium).lineLimit(1).fixedSize()
			}
			.padding(.horizontal, 10)
			.frame(height: 28)
			.background(theme.surface, in: Capsule())
			Image(systemName: "arrow.clockwise")
				.font(.system(size: 13, weight: .medium))
				.frame(width: 28, height: 28)
				.background(theme.surface, in: Circle())
		}
		.foregroundStyle(theme.ink)
	}

	/// The lightbox's failure on its dark backdrop: what failed, the file, and Try again.
	private var lightboxFailure: some View {
		VStack(spacing: 8) {
			Image(systemName: failureSymbol)
				.font(.system(size: 28, weight: .regular))
				.foregroundStyle(.white.opacity(0.6))
				.padding(.bottom, 4)
				.accessibilityHidden(true)
			Text(couldNotLoadAttachmentText)
				.rasheed(.title)
				.foregroundStyle(.white)
				.multilineTextAlignment(.center)
			Text(attachment.fileName)
				.rasheed(.sub)
				.foregroundStyle(.white.opacity(0.6))
				.lineLimit(1)
				.truncationMode(.middle)
				.environment(\.layoutDirection, .leftToRight)
			Button { attempt += 1 } label: {
				HStack(spacing: 6) {
					Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .medium))
					Text(tryAgainText).rasheed(.control)
				}
				.foregroundStyle(.white)
				.padding(.horizontal, 16)
				.frame(height: 36)
				.background(.white.opacity(0.12), in: Capsule())
				.frame(minHeight: 44)
				.contentShape(Rectangle())
			}
			.buttonStyle(RasheedPressStyle())
			.padding(.top, 8)
		}
		.padding(.horizontal, 32)
	}

	private func localized(_ en: String, _ ar: String) -> String { model.configuration.language == .ar ? ar : en }

	private var couldNotLoadText: String { localized("Couldn’t load", "تعذّر التحميل") }
	private var couldNotLoadAttachmentText: String { localized("Couldn’t load this attachment", "تعذّر تحميل المرفق") }
	private var retryText: String { localized("Retry", "إعادة المحاولة") }
	private var tryAgainText: String { localized("Try again", "إعادة المحاولة") }
}

private struct AttachmentDocumentPreview: UIViewControllerRepresentable {
	let url: URL
	func makeCoordinator() -> Coordinator { Coordinator(url: url) }
	func makeUIViewController(context: Context) -> QLPreviewController {
		let controller = QLPreviewController()
		controller.dataSource = context.coordinator
		return controller
	}
	func updateUIViewController(_ controller: QLPreviewController, context: Context) {
		context.coordinator.url = url
		controller.reloadData()
	}
	final class Coordinator: NSObject, QLPreviewControllerDataSource {
		var url: URL
		init(url: URL) { self.url = url }
		func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
		func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
	}
}

struct RasheedTranscriptVisibility: Equatable {
	let conversationId: String
	let cursor: RasheedMessageCursor
	let bottom: CGFloat
}

struct RasheedTranscriptVisibilityKey: PreferenceKey {
	static var defaultValue: RasheedTranscriptVisibility? { nil }
	static func reduce(value: inout RasheedTranscriptVisibility?, nextValue: () -> RasheedTranscriptVisibility?) {
		value = nextValue() ?? value
	}
}

struct RasheedTranscriptContentKey: PreferenceKey {
	static var defaultValue: CGRect? { nil }
	static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
		value = nextValue() ?? value
	}
}

/// The web's file row: the type's icon, the name over its type and size, then the row's actions, in a hairline box.
struct RasheedFileRow<Actions: View>: View {
	let name: String
	let kind: RasheedSupportAttachment.Kind
	let meta: String
	var failed = false
	let theme: RasheedSupportTheme
	@ViewBuilder var actions: Actions

	var body: some View {
		HStack(spacing: 10) {
			Image(systemName: kind.rowSymbol)
				.font(.system(size: 15, weight: .regular))
				.foregroundStyle(theme.muted)
				.frame(width: 34, height: 34)
				.background(theme.surfaceMuted, in: RoundedRectangle(cornerRadius: RasheedRadius.chip, style: .continuous))
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 0) {
				Text(name)
					.rasheed(.sub, weight: .medium)
					.foregroundStyle(theme.ink)
					.lineLimit(1)
					.truncationMode(.tail)
				Text(meta)
					.rasheed(.caption)
					.foregroundStyle(failed ? theme.danger : theme.muted)
					.fixedSize(horizontal: false, vertical: true)
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.accessibilityElement(children: .combine)
			HStack(spacing: 2) { actions }
		}
		.padding(.vertical, 3)
		.padding(.leading, 8)
		.padding(.trailing, 3)
		.frame(minHeight: 50)
		.background(theme.surface, in: RoundedRectangle(cornerRadius: RasheedRadius.card, style: .continuous))
		.rasheedBorder(theme.border, radius: RasheedRadius.card)
	}
}

extension RasheedSupportAttachment.Kind {
	var rowSymbol: String {
		switch self {
		case .image: "photo"
		case .video: "video"
		case .audio: "music.note"
		case .document: "doc"
		}
	}
}

/// "JPG · 2.3 MB" as the web writes it: kilobytes or megabytes, one decimal under ten. Both parts are isolated so
/// right-to-left text keeps the number next to its unit.
func rasheedFileMeta(name: String, byteLength: Int, language: RasheedLanguage) -> String {
	let mega = byteLength >= 1_048_576
	let value = max(1, Double(byteLength) / (mega ? 1_048_576 : 1_024))
	let number = value.formatted(.number.precision(.fractionLength(0...(value < 10 ? 1 : 0)))
		.rounded(rule: .toNearestOrAwayFromZero).locale(RasheedClock.locale(language)))
	let unit = language == .ar ? (mega ? "ميغابايت" : "كيلوبايت") : (mega ? "MB" : "kB")
	guard let range = name.range(of: "\\.[A-Za-z0-9]{1,5}$", options: .regularExpression) else { return "\(number) \(unit)" }
	return "\u{2068}\(name[range].dropFirst().uppercased())\u{2069} · \u{2068}\(number) \(unit)\u{2069}"
}

/// An image's thumbnail above its row, as on the web: 180 high at the picture's own proportions. Its private download
/// starts once it scrolls into view.
struct RasheedThumbnail: View {
	let attachment: RasheedSupportAttachment
	@ObservedObject var model: RasheedSupportModel
	let theme: RasheedSupportTheme
	let onFailure: () -> Void
	@State private var visible = false
	@State private var image: UIImage?

	var body: some View {
		let shape = RoundedRectangle(cornerRadius: RasheedRadius.card, style: .continuous)
		Group {
			if let image {
				Image(uiImage: image)
					.resizable()
					.scaledToFill()
					.frame(minWidth: 96, maxWidth: 180 * image.size.width / max(image.size.height, 1), minHeight: 180, maxHeight: 180)
			} else {
				theme.surfaceMuted.frame(maxWidth: 240).frame(height: 180)
			}
		}
		.clipShape(shape)
		.overlay { shape.strokeBorder(theme.ink.opacity(0.08), lineWidth: 1) }
		// Near view, as on the web: within 240 points of the visible transcript.
		.background {
			Color.clear.padding(.vertical, -240)
				.onScrollVisibilityChange(threshold: 0.001) { if $0 { visible = true } }
		}
		.task(id: visible) {
			guard visible, image == nil else { return }
			do {
				let file = try await model.download(attachment)
				defer { withExtendedLifetime(file) {} }
				let decoded = await RasheedMediaImage.decodeThumbnail(at: file.url, maximumPixelSize: 720)
				guard !Task.isCancelled else { return }
				if let decoded { image = decoded } else { onFailure() }
			} catch {
				if !Task.isCancelled { onFailure() }
			}
		}
	}
}

/// A downloaded attachment handed to the system share sheet, to save to Files or Photos or open elsewhere.
struct RasheedSharedFile: Identifiable {
	let id = UUID()
	let file: RasheedAttachmentFile
}

struct RasheedShareSheet: UIViewControllerRepresentable {
	let shared: RasheedSharedFile

	func makeUIViewController(context: Context) -> UIActivityViewController {
		UIActivityViewController(activityItems: [shared.file.url], applicationActivities: nil)
	}

	func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
