import AVFoundation

/// macOS owns these controls. Opening them never enables a capture device.
@MainActor
public enum YapSystemMediaEffects {
    public static func showVideoEffects() {
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
    }

    public static func showMicrophoneModes() {
        AVCaptureDevice.showSystemUserInterface(.microphoneModes)
    }
}
