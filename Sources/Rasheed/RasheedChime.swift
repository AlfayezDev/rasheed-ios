import AVFoundation
import os

/// The web widget's reply chime. It plays through AVAudioPlayer in the ambient session, so it mixes with other audio
/// and stays silent with the ringer switched off, and at most once every 600 ms.
@MainActor
enum RasheedChime {
	private static var player: AVAudioPlayer?
	private static var lastPlayed: ContinuousClock.Instant?

	static func play() {
		let now = ContinuousClock.now
		if let lastPlayed, now - lastPlayed < .milliseconds(600) { return }
		lastPlayed = now
		guard let player = loaded() else { return }
		// Only the default session changes: a host that chose its own audio category keeps it.
		let session = AVAudioSession.sharedInstance()
		if session.category == .soloAmbient {
			do { try session.setCategory(.ambient) }
			catch { logger.error("Chime session unavailable: \(error.localizedDescription, privacy: .public)") }
		}
		player.currentTime = 0
		player.play()
	}

	private static let logger = Logger(subsystem: "io.rasheed.support", category: "sound")

	private static func loaded() -> AVAudioPlayer? {
		if let player { return player }
		guard let url = Bundle.module.url(forResource: "rasheed-chime", withExtension: "wav", subdirectory: "Sounds")
		else { return nil }
		do {
			let loaded = try AVAudioPlayer(contentsOf: url)
			loaded.prepareToPlay()
			player = loaded
		} catch {
			logger.error("Chime unavailable: \(error.localizedDescription, privacy: .public)")
		}
		return player
	}
}
