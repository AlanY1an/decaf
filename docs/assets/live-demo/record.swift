// Capture the demonstration stage and native menu bar. Bring the stage forward before recording.
// Requires existing macOS Screen Recording permission. No microphone or system audio.
import Foundation
import ScreenCaptureKit
import AVFoundation

@available(macOS 15.0, *)
final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) { print("Recording started \(Date().timeIntervalSince1970)"); fflush(stdout) }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) { fputs("Recording failed: \(error)\n", stderr); exit(1) }
    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { print("Recording finished"); fflush(stdout) }
}
@main
struct Capture {
    @MainActor static func main() async throws {
        guard #available(macOS 15.0, *) else { fatalError("Recording requires macOS 15+") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let stop = CommandLine.arguments[2]
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let app = content.applications.first(where: { $0.bundleIdentifier == "io.github.alany1an.decaf.live-demo" }),
              let display = content.displays.first else { fatalError("Open the isolated Decaf Demo app first") }
        let excluded = content.applications.filter { $0.processID != app.processID && !$0.bundleIdentifier.hasPrefix("com.apple.") }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        filter.includeMenuBar = true
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height - 85
        config.sourceRect = CGRect(x: 0, y: 0, width: display.width, height: display.height - 85)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = false
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showMouseClicks = true
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let settings = SCRecordingOutputConfiguration()
        settings.outputURL = output
        settings.outputFileType = .mp4
        settings.videoCodecType = .h264
        let delegate = RecordingDelegate()
        let recording = SCRecordingOutput(configuration: settings, delegate: delegate)
        try stream.addRecordingOutput(recording)
        try await stream.startCapture()
        let deadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: stop) && Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        try await stream.stopCapture()
        try await Task.sleep(for: .seconds(1))
    }
}
