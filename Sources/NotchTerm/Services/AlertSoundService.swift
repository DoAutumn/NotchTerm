import AppKit
import Foundation

/// Plays the bundled short chime for completion / awaiting-user states.
enum AlertSoundService {
    private static var cached: NSSound?
    /// Retain clones until playback ends — ARC would otherwise stop the sound mid-play.
    private static var playing: [NSSound] = []
    private static let finishHandler = FinishHandler()

    private final class FinishHandler: NSObject, NSSoundDelegate {
        func sound(_ sound: NSSound, didFinishPlaying _: Bool) {
            AlertSoundService.playing.removeAll { $0 === sound }
        }
    }

    static func play() {
        if cached == nil {
            cached = loadBundled()
        }
        guard let sound = cached else { return }
        // Clone so overlapping alerts can each play (NSSound is one-shot per instance).
        guard let clone = sound.copy() as? NSSound else {
            _ = sound.play()
            return
        }
        clone.delegate = finishHandler
        playing.append(clone)
        if !clone.play() {
            playing.removeAll { $0 === clone }
        }
    }

    private static func loadBundled() -> NSSound? {
        let urls: [URL?] = [
            Bundle.main.url(forResource: "alert-chime", withExtension: "wav"),
            Bundle.main.resourceURL?
                .appendingPathComponent("NotchTerm_NotchTerm.bundle")
                .appendingPathComponent("alert-chime.wav")
        ]
        for case let url? in urls {
            if let sound = NSSound(contentsOf: url, byReference: true) {
                return sound
            }
        }
        return nil
    }
}
