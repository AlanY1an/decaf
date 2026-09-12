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
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        filter.includeMenuBar = true
        let config = SCStreamConfiguration()
        guard let stage = content.windows.first(where: {
            $0.owningApplication?.processID == app.processID && $0.title == "Decaf · live demonstration"
        }) else { fatalError("Demo stage window is missing") }
        // Record only the right-aligned stage and the menu above it; exclude all other apps.
        let region = CGRect(x: stage.frame.minX, y: 0, width: stage.frame.width, height: stage.frame.maxY)
        config.width = Int(region.width)
        config.height = Int(region.height)
        config.sourceRect = region
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
