import ImageIO
import os
import SwiftUI
import UIKit

private let logger = Logger(subsystem: "io.rasheed.support", category: "branding")
private let logoByteLimit = 5 * 1024 * 1024
private let logoCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 16
    cache.totalCostLimit = 8 * 1024 * 1024
    return cache
}()

private enum WorkspaceLogoError: Error {
    case unavailable(Int), tooLarge, undecodable
}

/// The workspace's logo in the header, as on the web: 26 points at radius 6, clear until it loads, then faded in with an
/// inset hairline. A logo that fails to load leaves no space behind.
@MainActor
struct WorkspaceLogo: View {
    private let url: URL
    private let theme: RasheedSupportTheme
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL, theme: RasheedSupportTheme) {
        self.url = url
        self.theme = theme
        _image = State(initialValue: logoCache.object(forKey: url.absoluteString as NSString))
    }

    var body: some View {
        if !failed {
            let shape = RoundedRectangle(cornerRadius: RasheedRadius.chip, style: .continuous)
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .overlay { shape.strokeBorder(theme.ink.opacity(0.1), lineWidth: 1) }
                        .transition(.opacity)
                }
            }
            .frame(width: 26, height: 26)
            .clipShape(shape)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: image != nil)
            .accessibilityHidden(true)
            .task(id: url) { await load() }
        }
    }

    private func load() async {
        let key = url.absoluteString as NSString
        if let cached = logoCache.object(forKey: key) {
            image = cached
            return
        }
        do {
            let (loaded, cost) = try await fetchWorkspaceLogo(url)
            logoCache.setObject(loaded, forKey: key, cost: cost)
            if !Task.isCancelled { image = loaded }
        } catch is CancellationError {
        } catch {
            logger.warning("Workspace logo could not be loaded: \(String(describing: error), privacy: .public)")
            if !Task.isCancelled { failed = true }
        }
    }
}

private func fetchWorkspaceLogo(_ url: URL) async throws -> (UIImage, Int) {
    let session = URLSession(configuration: .ephemeral, delegate: WorkspaceLogoNoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (bytes, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 15))
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        throw WorkspaceLogoError.unavailable((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    guard http.expectedContentLength <= Int64(logoByteLimit) else { throw WorkspaceLogoError.tooLarge }
    var data = Data(capacity: Int(max(http.expectedContentLength, 0)))
    for try await byte in bytes {
        data.append(byte)
        guard data.count <= logoByteLimit else { throw WorkspaceLogoError.tooLarge }
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCache: false,
        kCGImageSourceThumbnailMaxPixelSize: 256,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw WorkspaceLogoError.undecodable
    }
    return (UIImage(cgImage: thumbnail), thumbnail.bytesPerRow * thumbnail.height)
}

private final class WorkspaceLogoNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
