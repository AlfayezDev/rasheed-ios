import SwiftUI
import UIKit
import ImageIO

struct RasheedMediaImage: View {
	let value: URL?
	let theme: RasheedSupportTheme
	var contentMode: ContentMode = .fill
	var maximumPixelSize = 2048

	@State private var localImage: UIImage?

	var body: some View {
		Group {
			if let localImage {
				Image(uiImage: localImage).resizable().aspectRatio(contentMode: contentMode)
			} else {
				theme.surfaceMuted
			}
		}
		.task(id: decodeKey) { await decodeLocalImage() }
	}

	private var decodeKey: String? {
		value.map { "\($0.absoluteString)#\(maximumPixelSize)" }
	}

	private func decodeLocalImage() async {
		guard let value else {
			localImage = nil
			return
		}
		localImage = nil
		let decoded = await Self.decodeThumbnail(at: value, maximumPixelSize: maximumPixelSize)
		guard !Task.isCancelled else { return }
		localImage = decoded
	}

	nonisolated static func decodeThumbnail(at url: URL, maximumPixelSize: Int) async -> UIImage? {
		guard url.isFileURL, let lease = RasheedAttachmentFile.lease(path: url.path) else { return nil }
		let decode = Task.detached(priority: .utility) { [lease] () -> UIImage? in
			withExtendedLifetime(lease) {
				guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(lease.url as CFURL, nil),
					let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
						kCGImageSourceCreateThumbnailFromImageAlways: true,
						kCGImageSourceCreateThumbnailWithTransform: true,
						kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
					] as CFDictionary)
				else { return nil }
				return Task.isCancelled ? nil : UIImage(cgImage: image)
			}
		}
		return await withTaskCancellationHandler {
			await decode.value
		} onCancel: { decode.cancel() }
	}
}

extension RasheedSupportAttachment {
	/// A downloaded image small enough to show as a thumbnail, in the transcript's tile and the lightbox's strip alike.
	var hasLiveThumbnail: Bool { kind == .image && byteLength <= 5 * 1024 * 1024 }
}

extension RasheedSupportAttachment.Kind {
	/// The kind as a symbol, for a tile or badge with no picture or file extension to show.
	var symbol: String {
		switch self {
		case .image: "photo"
		case .video: "play.fill"
		case .audio: "waveform"
		case .document: "doc"
		}
	}
}
