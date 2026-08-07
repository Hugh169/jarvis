import Foundation

/// A one-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
///
/// Bound to loopback on an ephemeral port and torn down the moment it has the
/// code — it exists for the few seconds between opening the browser and Google
/// redirecting back, and nothing off this machine can reach it.
///
/// Plain POSIX sockets rather than Network.framework: every `NWListener`
/// configuration fails here with `EINVAL` before it ever reaches `.ready`,
/// including the bare `NWListener(using: .tcp)`. Verified outside the sandbox
/// too, so it isn't a permissions artefact. `socket`/`bind`/`listen` works
/// first time and is less machinery for what is one request.
///
/// `@unchecked Sendable` with a lock: `accept` blocks, so it runs on its own
/// queue and the result is handed back across that boundary by hand.
final class LoopbackListener: @unchecked Sendable {
    private let handle: Int32
    private let queue = DispatchQueue(label: "net.jarvis.oauth.loopback")
    private let lock = NSLock()

    private var waiter: CheckedContinuation<String, Error>?
    /// The redirect can land before anyone is waiting, so the result is held
    /// until it's collected rather than dropped.
    private var result: Result<String, Error>?
    private var stopped = false

    private(set) var port: UInt16

    /// How long to wait for the user to finish in the browser before giving up.
    private static let patience: Duration = .seconds(300)

    private init() throws {
        // Bound through a local: `self` can't be captured by the pointer
        // closures below until every stored property is initialised.
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw OAuthFlow.FlowError.listenerFailed("socket() errno \(errno)")
        }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // let the kernel choose
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw OAuthFlow.FlowError.listenerFailed("bind() errno \(errno)")
        }
        guard listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw OAuthFlow.FlowError.listenerFailed("listen() errno \(errno)")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }

        handle = descriptor
        port = UInt16(bigEndian: assigned.sin_port)
    }

    static func start() async throws -> LoopbackListener {
        let listener = try LoopbackListener()
        listener.acceptOnce()
        return listener
    }

    private func acceptOnce() {
        queue.async { [weak self] in
            guard let self else { return }
            while true {
                var peer = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.handle, $0, &length)
                    }
                }
                // Negative means the socket was closed by `stop()`, or the
                // listener failed; either way there is nothing left to accept.
                guard client >= 0 else { return }

                // The authorization code is a bearer credential for the length
                // of one exchange. Only the browser on this machine should be
                // handing it over.
                guard peer.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian else {
                    close(client)
                    continue
                }

                let outcome = Self.parse(Self.readRequest(client))
                Self.respond(client, success: (try? outcome.get()) != nil)
                close(client)
                self.deliver(outcome)
                return
            }
        }
    }

    func awaitCode() async throws -> String {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.patience)
            guard !Task.isCancelled else { return }
            self?.deliver(.failure(OAuthFlow.FlowError.cancelled))
        }
        defer { timeout.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending = result {
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    private func deliver(_ outcome: Result<String, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(with: outcome)
    }

    func stop() {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
        // Closing unblocks the pending `accept`.
        close(handle)
    }

    // MARK: HTTP

    private static func readRequest(_ client: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var collected = ""
        while collected.utf8.count < 16_384 {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            collected += String(decoding: buffer[0..<count], as: UTF8.self)
            // The whole request line is in the first packet in practice; the
            // headers only matter for knowing where it ends.
            if collected.contains("\r\n\r\n") { break }
        }
        return collected
    }

    /// Pulls the query out of the request line — `GET /?code=… HTTP/1.1`.
    static func parse(_ request: String) -> Result<String, Error> {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first,
              let target = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            return .failure(OAuthFlow.FlowError.denied("malformed redirect"))
        }
        let items = components.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            return .failure(OAuthFlow.FlowError.denied(error))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return .failure(OAuthFlow.FlowError.denied("no code in redirect"))
        }
        return .success(code)
    }

    private static func respond(_ client: Int32, success: Bool) {
        let title = success ? "JARVIS is connected." : "Sign-in failed."
        let detail = success
            ? "You can close this tab and go back to JARVIS."
            : "Go back to JARVIS and try connecting again."
        let body = """
            <!doctype html><meta charset="utf-8"><title>\(title)</title>
            <body style="font-family:-apple-system,system-ui,sans-serif;background:#0b0f14;\
            color:#e6f1ff;display:grid;place-items:center;height:100vh;margin:0">
            <div style="text-align:center">
            <h1 style="font-weight:600;font-size:20px">\(title)</h1>
            <p style="color:#8ba3bb">\(detail)</p></div>
            """
        let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        let bytes = Array(response.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let written = write(client, base + sent, buffer.count - sent)
                guard written > 0 else { break }
                sent += written
            }
        }
    }
}
