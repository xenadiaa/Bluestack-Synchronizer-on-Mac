import AppKit
import ApplicationServices
import Foundation
import SwiftUI

private let bundledHelperFlag = "--run-bundled-helper"

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
    private static let maxLogCharacters = 20000
    private static let logScrollThrottleSeconds = 0.15

    @Published var candidates: [ProcessCandidate] = []
    @Published var sourcePID: pid_t?
    @Published var targetPID: pid_t?
    @Published var verbose = true
    @Published var isRunning = false
    @Published var statusText = "未启动"
    @Published var logText = ""
    @Published var logScrollVersion = 0

    private var process: Process?
    private var stdoutObserver: NSObjectProtocol?
    private var stderrObserver: NSObjectProtocol?
    private var pendingLogScrollWorkItem: DispatchWorkItem?
    private var permissionMonitorTimer: Timer?

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
        let previousSourcePID = sourcePID
        let previousTargetPID = targetPID
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

        let selectionChanged = previousSourcePID != sourcePID || previousTargetPID != targetPID
        let selectionInvalid = sourcePID == nil || targetPID == nil
        if isRunning && (selectionChanged || selectionInvalid) {
            stop()
            statusText = "实例已刷新，请重新连接"
            appendLog("检测到实例列表变化，已自动断开当前同步，请重新选择源和目标实例后再连接。")
        }
    }

    func start() {
        guard !isRunning else { return }
        guard let sourcePID, let targetPID else {
            statusText = "请先选择源和目标实例"
            appendLog("缺少源或目标 BlueStacks 实例。")
            return
        }
        guard requestAccessibilityPermissionIfNeeded() else {
            statusText = "缺少辅助功能权限"
            appendLog("请在系统设置中为 BlueStacks Synchronizer 开启辅助功能和输入监控，然后完全退出并重新打开 App。")
            return
        }

        let process = Process()
        guard let executableURL = Bundle.main.executableURL else {
            statusText = "启动失败"
            appendLog("无法定位 App 主可执行文件。")
            return
        }
        process.executableURL = executableURL
        process.arguments = [bundledHelperFlag] + buildSynchronizerArguments(sourcePID: sourcePID, targetPID: targetPID)

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
            startPermissionMonitor()
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
        stopPermissionMonitor()
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

    private func startPermissionMonitor() {
        stopPermissionMonitor()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            guard self.hasRuntimePermissions() else {
                self.appendLog("检测到辅助功能或输入监控权限失效，已自动停止同步。")
                self.stop()
                self.statusText = "权限失效，已停止"
                return
            }
        }
        permissionMonitorTimer = timer
    }

    private func stopPermissionMonitor() {
        permissionMonitorTimer?.invalidate()
        permissionMonitorTimer = nil
    }

    private func appendLog(_ message: String) {
        let normalized = message.hasSuffix("\n") ? message : message + "\n"
        logText += normalized
        if logText.count > Self.maxLogCharacters {
            let overflow = logText.count - Self.maxLogCharacters
            let trimIndex = logText.index(logText.startIndex, offsetBy: overflow)
            if let nextLineBreak = logText[trimIndex...].firstIndex(of: "\n") {
                logText = String(logText[logText.index(after: nextLineBreak)...])
            } else {
                logText = String(logText.suffix(Self.maxLogCharacters))
            }
        }
        scheduleLogScroll()
    }

    private func scheduleLogScroll() {
        pendingLogScrollWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.logScrollVersion += 1
        }
        pendingLogScrollWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.logScrollThrottleSeconds, execute: workItem)
    }

    private func requestAccessibilityPermissionIfNeeded() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        return AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }

    private func hasRuntimePermissions() -> Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    private func buildSynchronizerArguments(sourcePID: pid_t, targetPID: pid_t) -> [String] {
        var arguments = ["--source-pid", String(sourcePID), "--target-pid", String(targetPID)]
        if verbose {
            arguments.append("--verbose")
        }
        return arguments
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
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logText.isEmpty ? "暂无日志" : model.logText)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                        Color.clear
                            .frame(height: 1)
                            .id("log-bottom")
                    }
                    .frame(minHeight: 320)
                    .border(Color.secondary.opacity(0.3))
                    .onChange(of: model.logScrollVersion) { _ in
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                    .onAppear {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
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
    init() {
        if CommandLine.arguments.contains(bundledHelperFlag) {
            let args = Array(CommandLine.arguments.dropFirst()).filter { $0 != bundledHelperFlag }
            runBundledSynchronizer(with: args)
        }
    }

    var body: some Scene {
        WindowGroup("BlueStacks Synchronizer") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

func discoverCandidates(preferredAppName: String = "BlueStacks") -> [ProcessCandidate] {
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

func preferredWindowTitle(for pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?

    let attributes = [kAXFocusedWindowAttribute, kAXMainWindowAttribute]
    for attribute in attributes {
        value = nil
        let result = AXUIElementCopyAttributeValue(appElement, attribute as CFString, &value)
        if result == .success,
           let window = value,
           CFGetTypeID(window) == AXUIElementGetTypeID(),
           let title = windowTitle(from: window as! AXUIElement) {
            return title
        }
    }
    return nil
}

func windowTitle(from window: AXUIElement) -> String? {
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
