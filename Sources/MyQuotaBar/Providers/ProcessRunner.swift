import Foundation

/// 执行外部命令并捕获输出的小工具。
enum ProcessRunner {
    struct Result: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// 运行命令。会自动补充 arkcli 需要的调用标记环境变量。
    static func run(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval = 30
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let op = RunOperation(
                executable: executable,
                arguments: arguments,
                extraEnvironment: extraEnvironment,
                timeout: timeout,
                continuation: continuation
            )
            op.start()
        }
    }

    /// 在常见路径中查找可执行文件。
    static func locate(_ names: [String], extraPaths: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin"]
        dirs.append(contentsOf: extraPaths)
        for dir in dirs {
            for name in names {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }
}

private final class RunOperation: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let extraEnvironment: [String: String]
    private let timeout: TimeInterval
    private let continuation: CheckedContinuation<ProcessRunner.Result, Error>
    private let lock = NSLock()
    private var finished = false
    private var keepAlive: RunOperation?
    private var process: Process?
    private var timeoutItem: DispatchWorkItem?

    init(
        executable: String,
        arguments: [String],
        extraEnvironment: [String: String],
        timeout: TimeInterval,
        continuation: CheckedContinuation<ProcessRunner.Result, Error>
    ) {
        self.executable = executable
        self.arguments = arguments
        self.extraEnvironment = extraEnvironment
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        keepAlive = self
        let process = Process()
        self.process = process
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // GUI 启动的 app PATH 很窄，arkcli 是 node 脚本，需补上 Homebrew 等常见路径，
        // 否则会报 env: node: No such file or directory。
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
        for (k, v) in extraEnvironment { env[k] = v }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outData = DataAccumulator()
        let errData = DataAccumulator()
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { outData.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { errData.append(d) }
        }

        process.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let result = ProcessRunner.Result(
                stdout: outData.string,
                stderr: errData.string,
                exitCode: proc.terminationStatus
            )
            self?.finish(.success(result))
        }

        do {
            try process.run()
        } catch {
            finish(.failure(QuotaError.commandFailed(error.localizedDescription)))
            return
        }

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(QuotaError.commandFailed("请求超时")))
        }
        self.timeoutItem = timeoutItem
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    private func finish(_ result: Result<ProcessRunner.Result, Error>) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()

        timeoutItem?.cancel()   // 已完成则取消超时任务，不再白白占着
        timeoutItem = nil
        if process?.isRunning == true { process?.terminate() }
        continuation.resume(with: result)
        keepAlive = nil
    }
}

private final class DataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
