import ScreenCaptureKit

/// Shared defaults for the Sonoma capture API. No screen access occurs here.
public enum PlatformSupport {
    public static func captureConfiguration(showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = showsCursor
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        return configuration
    }
}
