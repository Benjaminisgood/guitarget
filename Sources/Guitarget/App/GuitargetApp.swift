import SwiftUI
import AppKit
import GuitarCore
import GuitarAudio

@main
struct GuitargetApp: App {
    @NSApplicationDelegateAdaptor(GuitargetAppDelegate.self) private var delegate
    private let audio = AudioService.shared
    @StateObject private var library = ScoreLibraryStore()

    var body: some Scene {
        Window("Guitarget · 学习室", id: "learning") {
            LearningRoom(audio: audio)
                .environmentObject(library)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) { NewScoreCommand() }
            CommandGroup(after: .windowArrangement) { LearningWindowCommand() }
            CommandMenu("声音") {
                Button("停止全部播放") { audio.stop(); library.referenceAudio.stop() }.keyboardShortcut(".", modifiers: .command)
                Button("停止采集") { audio.stopCapture() }
                SettingsLink { Text("声音设置…") }
            }
        }

        DocumentGroup(newDocument: GuitarScoreDocument()) { configuration in
            ScoreEditorView(document: configuration.$document, audio: audio, fileURL: configuration.fileURL)
                .environmentObject(library)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .defaultSize(width: 1380, height: 920)

        Settings {
            AudioSettingsView(audio: audio)
                .frame(width: 540)
                .padding(24)
        }
    }
}

struct NewScoreCommand: View {
    @Environment(\.newDocument) private var newDocument
    var body: some View {
        Button("新建曲谱") { newDocument(GuitarScoreDocument()) }.keyboardShortcut("n",modifiers:.command)
        Button("打开曲谱…") { NSDocumentController.shared.openDocument(nil) }.keyboardShortcut("o",modifiers:.command)
    }
}

struct LearningWindowCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("打开吉他学习室") { openWindow(id: "learning") }
            .keyboardShortcut("1", modifiers: [.command, .shift])
    }
}

final class GuitargetAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let index = CommandLine.arguments.firstIndex(of: "--self-check"), CommandLine.arguments.indices.contains(index+1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index+1])
            Task { @MainActor in
                var result: [String: Any] = ["application": "Guitarget", "kind": "native-editor-self-check"]
                do {
                    var checks = try runScoreEditorChecks()
                    checks.append(try runScoreLibraryChecks())
                    checks.append(try await runScoreEditorDelayedUndoCheck())
                    let audioResult = try AudioDiagnostics.run(outputDirectory: output.deletingLastPathComponent())
                    checks.append(try await runReferenceAudioChecks(sourceURL: output.deletingLastPathComponent().appendingPathComponent("reference-a4.wav")))
                    result["checks"] = checks
                    result["audio"] = audioResult
                    result["passed"] = audioResult["passed"] as? Bool ?? false
                }
                catch { result["passed"] = false; result["error"] = error.localizedDescription }
                do {
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: output, options: .atomic)
                } catch { NSLog("Self-check output failed: %@", error.localizedDescription) }
            }
        }
        // Named values keep NSApplication from mistaking a helper executable
        // inside an .app bundle for a document to open during application startup.
        let arguments = CommandLine.arguments
        let legacyIsolationIndex = arguments.firstIndex(of: "--system-isolation-smoke")
        let isolationDirectory = arguments.first(where: { $0.hasPrefix("--system-isolation-smoke=") }).map { String($0.dropFirst("--system-isolation-smoke=".count)) }
            ?? legacyIsolationIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        let isolationPlayer = arguments.first(where: { $0.hasPrefix("--system-isolation-player=") }).map { String($0.dropFirst("--system-isolation-player=".count)) }
            ?? legacyIsolationIndex.flatMap { arguments.indices.contains($0 + 2) ? arguments[$0 + 2] : nil }
        if let isolationDirectory, let isolationPlayer {
            let directory = URL(fileURLWithPath: isolationDirectory, isDirectory: true)
            let player = URL(fileURLWithPath: isolationPlayer)
            Task { @MainActor in
                let result = await runSystemIsolationSmoke(outputDirectory: directory, playerExecutable: player)
                NSLog("Guitarget system isolation smoke: %@", String(describing: result["passed"]))
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--hardware-smoke"), CommandLine.arguments.indices.contains(index+1) {
            let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
            Task { @MainActor in
                let result = await runAudioHardwareSmoke(outputDirectory:directory)
                NSLog("Guitarget hardware smoke passed: %@",String(describing:result["passed"]))
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--microphone-restart-smoke"), CommandLine.arguments.indices.contains(index+1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index+1], isDirectory: true)
            Task { @MainActor in
                let result = await runMicrophoneRestartSmoke(outputDirectory: directory)
                NSLog("Guitarget microphone restart smoke: %@", String(describing: result["passed"]))
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--guitar-capture"), CommandLine.arguments.indices.contains(index+1) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[index+1], isDirectory: true)
            Task { @MainActor in
                let result = await runGuitarCapture(outputDirectory: directory)
                NSLog("Guitarget guided guitar capture: %@", String(describing: result["status"]))
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
