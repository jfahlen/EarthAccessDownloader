//
//  HelperClient.swift
//  EarthAccessDownloader
//
//  Runs earthaccess_helper.py in a login shell (so the user's PATH, pyenv, conda, etc.
//  apply) and decodes its JSON-lines output.
//

import Foundation

struct HelperError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum HelperEvent {
    case granules([Granule], truncated: Bool)
    case progress(index: Int, total: Int, name: String)
    case fileError(name: String, message: String)
    case file(path: String)
    case done
    case ok
    /// The helper reported an error. Only produced when reading a remote job's log.
    case failure(String)
    /// A remote job's wrapper finished; nonzero means the helper itself crashed.
    case exit(status: Int)
}

/// A Linux machine reached over ssh (key or agent auth; password prompts are not possible).
struct RemoteConfig {
    var host: String  // user@host or an ~/.ssh/config alias
    var python: String
}

struct HelperClient {
    var pythonPath: String
    /// When set, the helper runs on this machine instead of locally.
    var remote: RemoteConfig?

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `command` and yields each event. Throws `HelperError` if the helper reports one.
    func run(_ command: String, request: [String: Any]) -> AsyncThrowingStream<HelperEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let script = Bundle.main.path(forResource: "earthaccess_helper", ofType: "py") else {
                continuation.finish(throwing: HelperError(message: "earthaccess_helper.py is missing from the app bundle."))
                return
            }
            let process = Process()
            var env = ProcessInfo.processInfo.environment
            if let remote {
                // Ship the script inside the command line so nothing needs installing remotely.
                guard let source = try? Data(contentsOf: URL(fileURLWithPath: script)) else {
                    continuation.finish(throwing: HelperError(message: "Could not read earthaccess_helper.py."))
                    return
                }
                let python = remote.python.isEmpty ? "python3" : remote.python
                let inner = "exec \(python) -c 'import base64;exec(base64.b64decode(\"\(source.base64EncodedString())\").decode())' \(command)"
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                                     remote.host, "bash -l -c " + Self.shellQuote(inner)]
            } else {
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", "exec \"$EAD_PYTHON\" \"$EAD_SCRIPT\" \"$EAD_COMMAND\""]
                env["EAD_PYTHON"] = pythonPath.isEmpty ? "python3" : pythonPath
                env["EAD_SCRIPT"] = script
                env["EAD_COMMAND"] = command
            }
            env["PYTHONUNBUFFERED"] = "1"
            process.environment = env

            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            Task.detached {
                do {
                    try process.run()
                    let body = try JSONSerialization.data(withJSONObject: request)
                    stdin.fileHandleForWriting.write(body)
                    try stdin.fileHandleForWriting.close()

                    var failure: HelperError?
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        guard let event = try Self.decode(line) else { continue }
                        continuation.yield(event)
                    }
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        failure = HelperError(message: err.isEmpty ? "Helper exited with status \(process.terminationStatus)." : err)
                    }
                    continuation.finish(throwing: failure)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Detached remote downloads

    /// Starts a download on the remote machine that keeps running on its own, and returns
    /// immediately with the remote job folder. The helper's output goes to `events.jsonl` there,
    /// to be read back with `readRemoteFile`; the ssh connection is not needed once this returns.
    func launchDownload(request: [String: Any]) async throws -> String {
        guard let remote else { throw HelperError(message: "No remote machine is configured.") }
        guard let script = Bundle.main.path(forResource: "earthaccess_helper", ofType: "py"),
              let source = try? Data(contentsOf: URL(fileURLWithPath: script)) else {
            throw HelperError(message: "Could not read earthaccess_helper.py.")
        }
        let body = try JSONSerialization.data(withJSONObject: request)
        let runner = """
            #!/bin/bash
            cd "$(dirname "$0")"
            "$EAD_PY" helper.py download < request.json > events.jsonl 2> stderr.log
            echo "{\"type\":\"exit\",\"status\":$?}" >> events.jsonl
            """ + "\n"
        let stamp = ISO8601DateFormatter().string(from: .now).filter(\.isNumber)
        let id = stamp + "-" + String(UInt16.random(in: 0...UInt16.max), radix: 16)
        let python = remote.python.isEmpty ? "python3" : remote.python
        let command = """
            set -e
            d="$HOME/.earthaccess_downloader/jobs/\(id)"
            mkdir -p "$d"
            echo '\(source.base64EncodedString())' | base64 -d > "$d/helper.py"
            echo '\(body.base64EncodedString())' | base64 -d > "$d/request.json"
            echo '\(Data(runner.utf8).base64EncodedString())' | base64 -d > "$d/runner.sh"
            if command -v setsid >/dev/null 2>&1; then S=setsid; else S=; fi
            EAD_PY=\(Self.shellQuote(python)) nohup $S bash "$d/runner.sh" > /dev/null 2>&1 < /dev/null &
            echo "$d"
            """
        let output = try await remoteShell(command)
        guard let dir = output.split(separator: "\n").last.map(String.init), dir.hasPrefix("/") else {
            throw HelperError(message: "The remote machine did not start the download.")
        }
        return dir
    }

    /// Reads `name` from the remote job folder `dir`. An empty string means it doesn't exist yet.
    func readRemoteFile(_ name: String, in dir: String) async throws -> String {
        try await remoteShell("cat \(Self.shellQuote(dir + "/" + name)) 2>/dev/null || true")
    }

    /// Runs `command` on the remote machine over a short-lived ssh connection and returns its output.
    private func remoteShell(_ command: String) async throws -> String {
        guard let remote else { throw HelperError(message: "No remote machine is configured.") }
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                                 remote.host, "bash -l -c " + Self.shellQuote(command)]
            let stdout = Pipe(), stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: err, encoding: .utf8) ?? ""
                throw HelperError(message: message.isEmpty ? "ssh exited with status \(process.terminationStatus)." : message)
            }
            return String(data: out, encoding: .utf8) ?? ""
        }.value
    }

    /// Decodes a whole `events.jsonl` log. Unlike `run`, an error line becomes a `.failure` event.
    nonisolated static func decodeLog(_ text: String) -> [HelperEvent] {
        text.split(separator: "\n").compactMap { line in
            let line = String(line)
            if line.hasPrefix("{"), let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if obj["type"] as? String == "error" { return .failure(obj["message"] as? String ?? "Unknown helper error") }
                if obj["type"] as? String == "exit" { return .exit(status: obj["status"] as? Int ?? -1) }
            }
            return (try? decode(line)) ?? nil
        }
    }

    private nonisolated static func decode(_ line: String) throws -> HelperEvent? {
        // Ignore anything that isn't a JSON object, e.g. a login banner printed by ssh.
        guard line.hasPrefix("{"), let data = line.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return nil }
        switch type {
        case "granules":
            let raw = try JSONSerialization.data(withJSONObject: obj["granules"] ?? [])
            return .granules(try JSONDecoder().decode([Granule].self, from: raw),
                             truncated: obj["truncated"] as? Bool ?? false)
        case "progress":
            return .progress(index: obj["index"] as? Int ?? 0, total: obj["total"] as? Int ?? 0,
                             name: obj["name"] as? String ?? "")
        case "file_error":
            return .fileError(name: obj["name"] as? String ?? "", message: obj["message"] as? String ?? "")
        case "file": return .file(path: obj["path"] as? String ?? "")
        case "done": return .done
        case "ok": return .ok
        case "error": throw HelperError(message: obj["message"] as? String ?? "Unknown helper error")
        default: return nil
        }
    }
}
