import Foundation

public typealias RasheedLanguage = Language

public enum RasheedTheme: String, CaseIterable, Sendable {
	case system, light, dark
}

/// `automatic` fills the screen on iPhone, as the web widget does on phones, and is a sheet on iPad.
public enum RasheedSupportPresentation: String, Sendable {
	case automatic, fullScreen, sheet
}

public enum RasheedSupportSpace: Equatable, Sendable {
	case home, messages
}

public enum RasheedSupportError: LocalizedError, Sendable, Equatable {
	case notConfigured, invalidRequest, attachmentLimit
	case unavailable(String)

	public var errorDescription: String? {
		switch self {
		case .notConfigured: "Supply the app's retained RasheedClient before presenting support."
		case .invalidRequest: "Invalid local attachment."
		case .attachmentLimit: "Choose up to 10 files, 50 MiB in total."
		case .unavailable(let message): message
		}
	}
}

public struct RasheedSupportConfiguration: Sendable, Equatable {
	public var language: Language
	public var theme: RasheedTheme
	public var presentation: RasheedSupportPresentation
	public var trustedImageHosts: Set<String>

	public init(language: Language, theme: RasheedTheme = .system,
		presentation: RasheedSupportPresentation = .automatic, trustedImageHosts: Set<String> = []) {
		self.language = language
		self.theme = theme
		self.presentation = presentation
		self.trustedImageHosts = trustedImageHosts
	}
}
