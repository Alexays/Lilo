import AppKit

extension BrowserContext {
    func togglePerfRecording() {
        if PerfRecorder.isRecording {
            Task { await stopPerfRecording() }
            return
        }
        PerfRecorder.start(
            processes: { [weak self] in self?.perfProcesses() ?? [] },
            context: perfContext(),
            onLimit: { [weak self] in Task { await self?.stopPerfRecording() } }
        )
        broadcastPerfRecording()
    }

    private func stopPerfRecording() async {
        let url = await PerfRecorder.stop(writingTo: BuildIdentity.defaultDownloadsDirectory)
        broadcastPerfRecording()
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        windows.activeWindow?.bridgeRouter.sendActionCompleted(
            "settingsActionCompleted",
            action: "togglePerfRecording",
            message: (url == nil ? "Unable to save the performance recording" : "Performance recording saved to Downloads").localized,
            level: url == nil ? "error" : "info"
        )
    }

    func broadcastPerfRecording() {
        let data: [String: Any] = ["startedAt": PerfRecorder.startedAt.map { $0.timeIntervalSince1970 * 1000 } as Any]
        windows.windows.forEach { $0.bridgeRouter.send(event: "perfRecordingChanged", data: data) }
    }

    /// Every WebKit process Lilo runs, by role. A process serving several roles keeps the first.
    private func perfProcesses() -> [PerfRecorder.Process] {
        var processes: [PerfRecorder.Process] = []
        var seen: Set<Int> = []
        func add(_ pid: Int?, _ role: String) {
            guard let pid, pid > 0, seen.insert(pid).inserted else { return }
            processes.append(PerfRecorder.Process(pid: Int32(pid), role: role))
        }
        for window in windows.windows {
            add(WebViewPrivateAccessors(window.chromeWebView).pid("_webProcessIdentifier"), "chrome")
        }
        let pidsOnly = { (engine: WKWebViewTab) in
            let accessors = WebViewPrivateAccessors(engine.wkWebView)
            return WebViewProcessDiagnostics(
                webProcessIdentifier: accessors.pid("_webProcessIdentifier"),
                networkProcessIdentifier: accessors.pid("_networkProcessIdentifier"),
                gpuProcessIdentifier: accessors.pid("_gpuProcessIdentifier"),
                modelProcessIdentifier: accessors.pid("_modelProcessIdentifier")
            )
        }
        for process in browserState.processSnapshot(diagnosticsProvider: pidsOnly) {
            switch process.kind {
            case .webContent, .provisionalWebContent: add(process.pid, "tab")
            case .network: add(process.pid, "network")
            case .gpu: add(process.pid, "gpu")
            case .model: add(process.pid, "model")
            }
        }
        for profile in profileContexts.allContexts {
            for context in profile.extensions.controller.extensionContexts {
                add(BackgroundSupervisor.backgroundWebView(of: context).flatMap { WebViewPrivateAccessors($0).pid("_webProcessIdentifier") }, "extension")
            }
        }
        return processes
    }

    /// The Mac and the session's size at the start of a recording: counts only, no names.
    private func perfContext() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return [
            "liloVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "liloBuild": info["CFBundleVersion"] as? String ?? "",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "macModel": String(cString: model),
            "cores": ProcessInfo.processInfo.activeProcessorCount,
            "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
            "thermalStateAtStart": ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "windows": windows.windows.count,
            "spaces": spaceManager?.spaces.count ?? 0,
            "tabs": browserState.allTabIds().count,
            "liveTabs": browserState.liveEngineCount,
            "extensions": profileContexts.allContexts.reduce(0) { $0 + $1.extensions.controller.extensionContexts.count },
            "lifecyclePreset": settingsStore?.lifecyclePreset.rawValue ?? ""
        ]
    }
}
