import Darwin
import Foundation

extension CMUXCLI {
    static let piAutoNamingLaunchArgvEnvironmentKey = "CMUX_PI_AUTONAME_LAUNCH_ARGV_B64"

    func trustedPiAutoNamingLaunchCommand(
        from env: [String: String]
    ) -> (executable: String, prefixArguments: [String])? {
        guard let values = decodedPiAutoNamingLaunchArgv(
            env[Self.piAutoNamingLaunchArgvEnvironmentKey]
        ), values.count == 1 || values.count == 2,
           let executable = canonicalAutoNamingFile(values[0], requireExecutable: true)
        else {
            return nil
        }

        if values.count == 1 {
            let executableName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
            guard executableName == "pi" || executableName == "pi-coding-agent" else { return nil }
            return (executable, [])
        }

        let runtimeName = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        guard ["node", "nodejs", "bun", "deno"].contains(runtimeName),
              let script = canonicalAutoNamingFile(values[1], requireExecutable: false),
              piCodingAgentPackageContains(script: script)
        else {
            return nil
        }
        return (executable, [script])
    }

    private func decodedPiAutoNamingLaunchArgv(_ rawValue: String?) -> [String]? {
        guard let rawValue, rawValue.utf8.count <= 64 * 1024,
              let data = Data(base64Encoded: rawValue),
              !data.isEmpty
        else {
            return nil
        }
        var values: [String] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            guard start != index,
                  let value = String(data: data[start..<index], encoding: .utf8)
            else {
                return nil
            }
            values.append(value)
            start = data.index(after: index)
        }
        if start < data.endIndex {
            guard let value = String(data: data[start..<data.endIndex], encoding: .utf8),
                  !value.isEmpty
            else {
                return nil
            }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }

    private func canonicalAutoNamingFile(_ rawPath: String, requireExecutable: Bool) -> String? {
        guard rawPath.hasPrefix("/") else { return nil }
        let resolvedPath = URL(fileURLWithPath: rawPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              !requireExecutable || FileManager.default.isExecutableFile(atPath: resolvedPath)
        else {
            return nil
        }
        return resolvedPath
    }

    private func piCodingAgentPackageContains(script: String) -> Bool {
        let packageNames: Set<String> = [
            "@earendil-works/pi-coding-agent",
            "@mariozechner/pi-coding-agent"
        ]
        var directory = URL(fileURLWithPath: script).deletingLastPathComponent()
        for _ in 0..<8 {
            let packageURL = directory.appendingPathComponent("package.json", isDirectory: false)
            if let data = try? Data(contentsOf: packageURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = object["name"] as? String,
               packageNames.contains(name) {
                return true
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return false
    }

    func runAutoNamingSummarizer(
        def: AgentHookDef,
        prompt: String,
        env: [String: String],
        timeout: TimeInterval,
        telemetry: CLISocketSentryTelemetry
    ) -> String? {
        let policy = AutoNamingEnvironmentPolicy()
        // Generic agents (grok/opencode/pi/omp) need their OWN provider/cloud
        // credentials to authenticate, so — unlike Codex's tight allowlist — we
        // use the broad scrubbed env here. Exposure is bounded by running the
        // summarizer with tools and network disabled (see the per-agent argv:
        // --pure / --no-tools / --disable-web-search / --no-subagents), so the
        // untrusted transcript text has no channel to exfiltrate those vars.
        var summarizerEnv = policy.summarizerEnvironment(from: env)
        summarizerEnv[def.disableEnvVar] = "1"

        func executable(_ name: String = def.binaryName) -> String? {
            resolveExecutableInSearchPath(name, searchPath: env["PATH"])
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-autoname-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        func promptFile() -> String? {
            let url = tempRoot.appendingPathComponent("prompt.txt", isDirectory: false)
            guard let data = prompt.data(using: .utf8) else { return nil }
            guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [
                .posixPermissions: NSNumber(value: Int16(0o600))
            ]) else { return nil }
            return url.path
        }

        let executablePath: String?
        let arguments: [String]
        let stdinPrompt: String
        switch def.name {
        case "opencode":
            guard let promptPath = promptFile() else { return nil }
            executablePath = executable("opencode")
            arguments = [
                "run",
                "--pure",
                "--format", "default",
                "--dir", tempRoot.path,
                "--file", promptPath,
                "Generate a 2-5 word title from the attached conversation excerpt. Output only the title."
            ]
            stdinPrompt = ""
        case "grok":
            guard let promptPath = promptFile() else { return nil }
            executablePath = executable("grok")
            arguments = [
                "--prompt-file", promptPath,
                "--output-format", "plain",
                "--tools", "",
                "--disable-web-search",
                "--no-subagents",
                "--no-memory",
                "--verbatim"
            ]
            stdinPrompt = ""
        case "pi":
            guard let promptPath = promptFile() else { return nil }
            guard let command = trustedPiAutoNamingLaunchCommand(from: env) else {
                telemetry.breadcrumb("pi-hook.auto-name.no-trusted-binary")
                return nil
            }
            executablePath = command.executable
            arguments = command.prefixArguments + [
                "--print",
                "--no-tools",
                "--no-session",
                "--no-extensions",
                "--no-skills",
                "--no-prompt-templates",
                "--no-context-files",
                "@\(promptPath)",
                "Generate a 2-5 word title from the attached conversation excerpt. Output only the title."
            ]
            stdinPrompt = ""
        case "omp":
            guard let promptPath = promptFile() else { return nil }
            executablePath = executable()
            arguments = [
                "--print",
                "--no-tools",
                "--no-session",
                "--no-extensions",
                "--no-skills",
                "--no-prompt-templates",
                "--no-context-files",
                "@\(promptPath)",
                "Generate a 2-5 word title from the attached conversation excerpt. Output only the title."
            ]
            stdinPrompt = ""
        default:
            return nil
        }

        guard let executablePath else {
            telemetry.breadcrumb("\(def.name)-hook.auto-name.no-binary")
            return nil
        }
        return runAutoNamingSummarizer(
            executable: executablePath,
            arguments: arguments,
            prompt: stdinPrompt,
            environment: summarizerEnv,
            timeout: timeout
        )
    }

    /// Returns a cheap monotonic progress metric for file-backed transcripts.
    /// File size preserves growth and compaction/shrink signals without
    /// streaming the whole transcript on every naming pass.
    func textFileGrowthMetric(path: String, fallbackLineCount: Int) -> Int {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath),
              let size = attributes[.size] as? NSNumber else {
            return fallbackLineCount
        }
        return max(fallbackLineCount, size.intValue / 128)
    }

    /// Runs the summarizer subprocess with the prompt on stdin and a hard
    /// deadline, returning captured stdout (nil on failure, timeout, or
    /// non-zero exit).
    func runAutoNamingSummarizer(
        executable: String,
        arguments: [String],
        prompt: String,
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdinPipe = Pipe()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-autoname-stdout-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let stdoutHandle = try? FileHandle(forWritingTo: outputURL) else {
            return nil
        }
        defer {
            try? stdoutHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutHandle
        process.standardError = FileHandle.nullDevice

        do {
            try cliRunProcess(process)
        } catch {
            return nil
        }
        if let promptData = prompt.data(using: .utf8) {
            _ = cliWrite(promptData, to: stdinPipe.fileHandleForWriting, onBrokenPipe: .ignore)
        }
        try? stdinPipe.fileHandleForWriting.close()

        let exited = (try? waitForProcessExit(process, timeout: timeout)) ?? false
        if !exited {
            process.terminate()
            if ((try? waitForProcessExit(process, timeout: 2)) ?? false) == false {
                kill(process.processIdentifier, SIGKILL)
                _ = try? waitForProcessExit(process, timeout: 1)
            }
            return nil
        }
        try? stdoutHandle.close()
        guard process.terminationStatus == 0,
              let output = try? Data(contentsOf: outputURL) else {
            return nil
        }
        return String(data: output, encoding: .utf8)
    }
}
