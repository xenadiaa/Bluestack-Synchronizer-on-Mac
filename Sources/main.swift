import AppKit
import ApplicationServices
import Foundation
import SwiftUI

private let synchronizerScriptPath = "/Users/xenadia/Documents/Playground/tools/Synchronizer/window_sync.swift"

struct ProcessCandidate: Identifiable, Hashable {
    let pid: pid_t
    let name: String
    let bundleID: String
    let windowTitle: String?

    var id: pid_t { pid }

    var displayName: String {
        if let windowTitle, !windowTitle.isEmpty {
            return "\(name) - \(windowTitle)"
        }
        return name
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var candidates: [ProcessCandidate] = []
    @Published var sourcePID: pid_t?
    @Published var targetPID: pid_t?
    @Published var verbose = true
    @Published var isRunning = false
    @Published var statusText = "未启动"
    @Published var logText = ""

    private var process: Process?
    private var stdoutObserver: NSObjectProtocol?
    private var stderrObserver: NSObjectProtocol?

    init() {
        refreshProcesses()
    }

    var sourceCandidates: [ProcessCandidate] {
        candidates
    }

    var targetCandidates: [ProcessCandidate] {
        candidates.filter { $0.pid != sourcePID }
    }

    func refreshProcesses() {
        let discovered = discoverCandidates()
        candidates = discovered

        if let sourcePID, !discovered.contains(where: { $0.pid == sourcePID }) {
            self.sourcePID = nil
        }
        if let targetPID, !discovered.contains(where: { $0.pid == targetPID }) {
            self.targetPID = nil
        }
        if let sourcePID, sourcePID == targetPID {
            self.targetPID = nil
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let sourcePID, let targetPID else {
            statusText = "请先选择源和目标实例"
            appendLog("缺少源或目标 BlueStacks 实例。")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        var arguments = ["swift", synchronizerScriptPath, "--source-pid", String(sourcePID), "--target-pid", String(targetPID)]
        if verbose {
            arguments.append("--verbose")
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        environment["SWIFT_MODULECACHE_PATH"] = "/tmp/swift-module-cache"
        environment["CLANG_MODULE_CACHE_PATH"] = "/tmp/clang-module-cache"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutObserver = NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: stdoutPipe.fileHandleForReading,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.consume(pipe: stdoutPipe, prefix: "")
            }
        }

        stderrObserver = NotificationCenter.default.addObserver(
            forName: .NSFileHandleDataAvailable,
            object: stderrPipe.fileHandleForReading,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.consume(pipe: stderrPipe, prefix: "[stderr] ")
            }
        }

        stdoutPipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
        stderrPipe.fileHandleForReading.waitForDataInBackgroundAndNotify()

        process.terminationHandler = { [weak self] task in
            DispatchQueue.main.async {
                self?.isRunning = false
                self?.statusText = task.terminationStatus == 0 ? "已停止" : "已退出（\(task.terminationStatus)）"
                self?.appendLog("同步器进程已结束，退出码 \(task.terminationStatus)。")
                self?.cleanupObservers()
                self?.process = nil
            }
        }

        do {
            try process.run()
            self.process = process
            isRunning = true
            statusText = "运行中"
            appendLog("已启动同步器：source=\(sourcePID) target=\(targetPID)")
        } catch {
            statusText = "启动失败"
            appendLog("启动失败：\(error.localizedDescription)")
            cleanupObservers()
        }
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        isRunning = false
        statusText = "已停止"
        cleanupObservers()
    }

    private func consume(pipe: Pipe, prefix: String) {
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            appendLog(prefix + text)
        }
        pipe.fileHandleForReading.waitForDataInBackgroundAndNotify()
    }

    private func cleanupObservers() {
        if let stdoutObserver {
            NotificationCenter.default.removeObserver(stdoutObserver)
            self.stdoutObserver = nil
        }
        if let stderrObserver {
            NotificationCenter.default.removeObserver(stderrObserver)
            self.stderrObserver = nil
        }
    }

    private func appendLog(_ message: String) {
        let normalized = message.hasSuffix("\n") ? message : message + "\n"
        logText += normalized
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BlueStacks 同步器")
                        .font(.system(size: 24, weight: .semibold))
                    Text("图形界面包装器，复用现有 ADB 同步脚本")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.statusText)
                    .font(.headline)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("源实例")
                        .font(.headline)
                    Picker("源实例", selection: $model.sourcePID) {
                        Text("请选择").tag(Optional<pid_t>.none)
                        ForEach(model.sourceCandidates) { candidate in
                            Text(candidate.displayName + "  PID=\(candidate.pid)")
                                .tag(Optional(candidate.pid))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("目标实例")
                        .font(.headline)
                    Picker("目标实例", selection: $model.targetPID) {
                        Text("请选择").tag(Optional<pid_t>.none)
                        ForEach(model.targetCandidates) { candidate in
                            Text(candidate.displayName + "  PID=\(candidate.pid)")
                                .tag(Optional(candidate.pid))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                Toggle("详细日志", isOn: $model.verbose)
                    .toggleStyle(.switch)

                Button("刷新实例") {
                    model.refreshProcesses()
                }

                Button("开始同步") {
                    model.start()
                }
                .disabled(model.isRunning)

                Button("停止") {
                    model.stop()
                }
                .disabled(!model.isRunning)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("运行日志")
                    .font(.headline)
                TextEditor(text: $model.logText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 320)
                    .border(Color.secondary.opacity(0.3))
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: model.sourcePID) { newValue in
            if model.targetPID == newValue {
                model.targetPID = nil
            }
        }
    }
}

@main
struct SynchronizerAppMain: App {
    var body: some Scene {
        WindowGroup("BlueStacks Synchronizer") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

private func discoverCandidates(preferredAppName: String = "BlueStacks") -> [ProcessCandidate] {
    let workspace = NSWorkspace.shared
    let runningApps = workspace.runningApplications.filter { app in
        app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && !app.isTerminated
            && app.activationPolicy == .regular
    }

    return runningApps.compactMap { app -> ProcessCandidate? in
        guard let name = app.localizedName, !name.isEmpty else { return nil }
        let bundleID = app.bundleIdentifier ?? "-"
        if bundleID.localizedCaseInsensitiveContains("bluestacksmim") {
            return nil
        }
        let candidate = ProcessCandidate(
            pid: app.processIdentifier,
            name: name,
            bundleID: bundleID,
            windowTitle: preferredWindowTitle(for: app.processIdentifier)
        )
        let matches = candidate.name.localizedCaseInsensitiveContains(preferredAppName)
            || candidate.bundleID.localizedCaseInsensitiveContains("bluestacks")
            || (candidate.windowTitle?.localizedCaseInsensitiveContains(preferredAppName) ?? false)
        return matches ? candidate : nil
    }
    .sorted {
        if $0.name == $1.name {
            return $0.pid < $1.pid
        }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
}

private func preferredWindowTitle(for pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?

    let attributes = [kAXFocusedWindowAttribute, kAXMainWindowAttribute]
    for attribute in attributes {
        value = nil
        let result = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value)
        if result == .success,
           let window = value,
           let title = windowTitle(from: unsafeBitCast(window, to: AXUIElement.self)) {
            return title
        }
    }
    return nil
}

private func windowTitle(from window: AXUIElement) -> String? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
    guard result == .success,
          let rawTitle = value,
          CFGetTypeID(rawTitle) == CFStringGetTypeID() else {
        return nil
    }

    let title = rawTitle as! String
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}
