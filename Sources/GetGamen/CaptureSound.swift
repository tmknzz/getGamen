import AppKit

@MainActor
final class CaptureSound {
    private let sound: NSSound?

    init(bundle: Bundle = .main) {
        sound = bundle.url(forResource: "Shutter", withExtension: "wav")
            .flatMap { NSSound(contentsOf: $0, byReference: false) }
    }

    func play() {
        sound?.stop()
        sound?.play()
    }
}
