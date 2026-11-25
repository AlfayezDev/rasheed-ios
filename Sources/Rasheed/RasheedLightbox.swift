import SwiftUI

/// Who sent a media attachment and when, for the lightbox's top bar.
struct RasheedMediaSource: Equatable {
	let author: String
	let createdAt: Int
}

struct RasheedMediaViewerContext {
	let attachments: [RasheedSupportAttachment]
	let index: Int
	var sources: [String: RasheedMediaSource] = [:]
}

struct RasheedLightbox: View {
	let context: RasheedMediaViewerContext
	let language: RasheedLanguage
	let onClose: () -> Void
	let model: RasheedSupportModel

	@State private var index: Int
	@State private var backdrop: Double = 0
	@State private var dragOffset: CGFloat = 0
	@State private var isZoomed = false
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	/// The lightbox is dark in both themes, so it takes the dark palette.
	private var palette: RasheedSupportTheme { .dark }

	init(
		context: RasheedMediaViewerContext,
		language: RasheedLanguage,
		model: RasheedSupportModel,
		onClose: @escaping () -> Void
	) {
		self.context = context
		self.language = language
		self.model = model
		self.onClose = onClose
		_index = State(initialValue: context.index)
	}

	private var current: RasheedSupportAttachment {
		context.attachments[min(index, context.attachments.count - 1)]
	}

	var body: some View {
		ZStack {
			Color(red: 8 / 255, green: 6 / 255, blue: 5 / 255)
				.opacity(0.92 * backdrop)
				.ignoresSafeArea()
				.onTapGesture {
					if !isZoomed { close() }
				}

			TabView(selection: $index) {
				ForEach(Array(context.attachments.enumerated()), id: \.element.id) { offset, attachment in
					Group {
						if index == offset { page(attachment) }
						else { Color.clear }
					}
						.tag(offset)
				}
			}
			.tabViewStyle(.page(indexDisplayMode: .never))
			// Leaves the strip clear of the page's own controls.
			.padding(.top, 56)
			.padding(.bottom, context.attachments.count > 1 ? 72 : 0)
			.onChange(of: index) { _ in isZoomed = false }
			.offset(y: dragOffset)
			.scaleEffect(0.94 + 0.06 * CGFloat(backdrop))
			.opacity(backdrop)
			.gesture(dismissDrag)
			.accessibilityElement(children: .contain)
			.accessibilityLabel(pageAccessibilityLabel)

			VStack(spacing: 0) {
				topBar
				Spacer()
				if context.attachments.count > 1 {
					strip
				}
			}
			.opacity(isZoomed ? 0 : 1)
			.animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isZoomed)
		}
		.accessibilityAddTraits(.isModal)
		.onAppear {
			withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
				backdrop = 1
			}
		}
	}

	/// The sender, the file and the position, with the close control at the end.
	private var topBar: some View {
		HStack(spacing: 10) {
			if let source = context.sources[current.id] {
				RasheedAvatar(name: source.author, size: 28, theme: palette)
				VStack(alignment: .leading, spacing: 0) {
					Text(source.author)
						.rasheed(.control)
						.foregroundStyle(palette.ink)
						.lineLimit(1)
					Text(RasheedClock.short(source.createdAt, language: language, now: model.client.serverNow))
						.rasheed(.caption)
						.monospacedDigit()
						.foregroundStyle(palette.muted)
				}
			}
			Spacer(minLength: 8)
			if context.attachments.count > 1 {
				Text(pageCount)
					.rasheed(.caption)
					.monospacedDigit()
					.foregroundStyle(palette.muted)
					// Right-to-left would swap the two numbers around the slash.
					.environment(\.layoutDirection, .leftToRight)
			}
			RasheedIconButton(systemName: "xmark", label: language == .ar ? "إغلاق" : "Close", size: 15, weight: .medium,
				diameter: 30, fill: .white.opacity(0.12),
				theme: palette, action: close)
		}
		.padding(.horizontal, 14)
		.padding(.top, 6)
	}

	/// One tile per attachment; the current one is full strength with a primary border.
	private var strip: some View {
		ScrollViewReader { proxy in
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(Array(context.attachments.enumerated()), id: \.element.id) { offset, attachment in
						let selected = offset == index
						Button {
							withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { index = offset }
						} label: {
							ZStack {
								palette.surfaceMuted
								if attachment.hasLiveThumbnail {
									// The same authenticated thumbnail the transcript tile shows.
									RasheedAttachmentView(attachment: attachment, model: model, theme: palette, isZoomed: .constant(false))
										.allowsHitTesting(false)
								} else {
									Image(systemName: attachment.kind.symbol)
										.font(.system(size: 14))
										.foregroundStyle(palette.muted)
								}
							}
							.frame(width: 56, height: 40)
							.rasheedClip(7)
							.rasheedBorder(selected ? palette.accent : .clear, radius: 7, width: 2)
							.opacity(selected ? 1 : 0.5)
							.padding(.vertical, 2)
							.frame(minHeight: 44)
							.contentShape(Rectangle())
						}
						.buttonStyle(RasheedPressStyle())
						.id(offset)
						.accessibilityLabel(stripLabel(offset))
						.accessibilityAddTraits(selected ? .isSelected : [])
					}
				}
				.padding(.horizontal, 14)
			}
			.onChange(of: index) { value in
				withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo(value, anchor: .center) }
			}
		}
		.padding(.bottom, 10)
	}

	private func page(_ attachment: RasheedSupportAttachment) -> some View {
		RasheedAttachmentView(attachment: attachment, model: model, theme: palette, expanded: true, isZoomed: $isZoomed)
	}

	private var dismissDrag: some Gesture {
		DragGesture()
			.onChanged { value in
				guard !isZoomed else { return }
				let dy = value.translation.height
				let dx = value.translation.width
				guard dy > 0, dy > abs(dx) else { return }
				dragOffset = dy
			}
			.onEnded { value in
				guard !isZoomed else { return }
				// Only a downward drag dismisses: a quick sideways page turn can carry a large predicted height.
				let downward = value.translation.height > abs(value.translation.width)
				if downward && (dragOffset > 140 || value.predictedEndTranslation.height > 320) {
					close()
				} else {
					withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
						dragOffset = 0
					}
				}
			}
	}

	private func close() {
		onClose()
	}

	private var pageCount: String {
		let current = min(index, context.attachments.count - 1) + 1
		return "\(current) / \(context.attachments.count)"
	}

	private var separator: String { language == .ar ? "، " : ", " }

	private func stripLabel(_ offset: Int) -> String {
		let attachment = context.attachments[offset]
		return "\(attachment.fileName)\(separator)\(offset + 1) / \(context.attachments.count)"
	}

	private var pageAccessibilityLabel: String {
		"\(current.fileName)\(separator)\(pageCount)"
	}
}

struct ZoomableImagePage: View {
	let value: URL
	let theme: RasheedSupportTheme
	@Binding var isZoomed: Bool

	@State private var scale: CGFloat = 1
	@State private var baseScale: CGFloat = 1
	@State private var offset: CGSize = .zero
	@State private var baseOffset: CGSize = .zero
	@Environment(\.accessibilityReduceMotion) private var reduceMotion

	var body: some View {
		GeometryReader { geometry in
			RasheedMediaImage(value: value, theme: theme, contentMode: .fit)
				.frame(width: geometry.size.width, height: geometry.size.height)
				.scaleEffect(scale)
				.offset(offset)
				.gesture(zoom.simultaneously(with: pan))
				.onTapGesture(count: 2) {
					toggleZoom()
				}
				.onChange(of: scale) { value in
					isZoomed = value > 1.01
				}
		}
	}

	private var zoom: some Gesture {
		MagnificationGesture()
			.onChanged { value in
				scale = min(max(baseScale * value, 1), 4)
			}
			.onEnded { _ in
				baseScale = scale
				if scale <= 1.01 {
					withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
						scale = 1
						offset = .zero
						baseOffset = .zero
					}
				}
			}
	}

	private var pan: some Gesture {
		DragGesture()
			.onChanged { value in
				guard scale > 1.01 else { return }
				offset = CGSize(
					width: baseOffset.width + value.translation.width,
					height: baseOffset.height + value.translation.height
				)
			}
			.onEnded { _ in
				guard scale > 1.01 else { return }
				baseOffset = offset
			}
	}

	private func toggleZoom() {
		withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
			if scale > 1.01 {
				scale = 1
				baseScale = 1
				offset = .zero
				baseOffset = .zero
			} else {
				scale = 2.5
				baseScale = 2.5
			}
		}
	}
}
