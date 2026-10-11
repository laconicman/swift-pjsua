import Foundation

/// A UDP registrar on loopback that records each request and answers it by script — enough SIP
/// to hold a REGISTER in flight, or challenge it, at a moment the test chooses.
///
/// It parses only what a REGISTER needs echoed and accepts any `Authorization` without checking
/// it. Retransmissions (same Call-ID and CSeq) are neither recorded nor answered again.
final class ScriptedRegistrar: @unchecked Sendable {

    struct Request: Sendable {
        let callID: String
        let cseq: String
        let contact: String?
        let expires: Int?
        let authorized: Bool

        /// An un-REGISTER: `Expires: 0`.
        var isUnregister: Bool { expires == 0 }

        func carries(_ parameters: String) -> Bool { contact?.contains(parameters) ?? false }
    }

    enum Answer: Sendable {
        /// 200, listing the request's own Contact as the binding.
        case ok
        /// 200, listing `binding` instead: a registrar that did not keep what it was sent.
        case okListing(String)
        /// 401 with a fresh digest challenge.
        case challenge
        /// A final failure with this status code.
        case reject(Int)
        /// No answer at all.
        case silence
    }

    /// Decides the answer to a request and how long to sit on it. `index` is its position among
    /// the requests recorded so far.
    typealias Script = @Sendable (_ request: Request, _ index: Int) -> (Answer, after: Duration)

    let port: UInt16

    private let socket: Int32
    private let script: Script
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var seen: Set<String> = []
    private var stopped = false
    private let finished = DispatchSemaphore(value: 0)

    init(script: @escaping Script) throws {
        self.script = script
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        socket = fd
        port = UInt16(bigEndian: address.sin_port)

        // Wake up regularly so `stop()` is noticed.
        var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        Thread.detachNewThread { [self] in receiveLoop() }
    }

    /// Every request so far, retransmissions excluded, in arrival order.
    var requests: [Request] {
        lock.withLock { recorded }
    }

    func stop() {
        lock.withLock { stopped = true }
        finished.wait()
        // Under the lock, so a delayed answer cannot write to a closed (or reused) descriptor.
        lock.withLock { _ = close(socket) }
    }

    // MARK: Wire

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while !lock.withLock({ stopped }) {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socket, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            guard count > 0 else { continue }
            let message = String(decoding: buffer[..<count], as: UTF8.self)
            handle(message, from: from)
        }
        finished.signal()
    }

    private func handle(_ message: String, from peer: sockaddr_in) {
        let lines = message.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, requestLine.hasPrefix("REGISTER ") else { return }
        let headers = lines.dropFirst().prefix { !$0.isEmpty }
        func values(_ name: String) -> [String] {
            headers.compactMap { line in
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces)
                          .caseInsensitiveCompare(name) == .orderedSame
                else { return nil }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let callID = values("Call-ID").first, let cseq = values("CSeq").first else { return }

        let request = Request(callID: callID,
                              cseq: cseq,
                              contact: values("Contact").first,
                              expires: values("Expires").first.flatMap { Int($0) },
                              authorized: !values("Authorization").isEmpty)
        let index: Int? = lock.withLock {
            guard seen.insert(callID + " " + cseq).inserted else { return nil }
            recorded.append(request)
            return recorded.count - 1
        }
        guard let index else { return }

        let (answer, delay) = script(request, index)
        let echoed = values("Via").map { "Via: \($0)" }
            + ["From: " + (values("From").first ?? "")]
            + ["To: " + withTag(values("To").first ?? ""), "Call-ID: \(callID)", "CSeq: \(cseq)"]
        let response: String
        switch answer {
        case .silence:
            return
        case .challenge:
            response = (["SIP/2.0 401 Unauthorized"] + echoed
                + [#"WWW-Authenticate: Digest realm="scripted", nonce="\#(UUID().uuidString)", algorithm=MD5"#])
                .joined(separator: "\r\n")
        case .ok:
            let binding = request.isUnregister ? [] : request.contact.map { contact in
                ["Contact: \(contact);expires=\(request.expires ?? 300)"]
            } ?? []
            response = (["SIP/2.0 200 OK"] + echoed + binding).joined(separator: "\r\n")
        case .okListing(let binding):
            response = (["SIP/2.0 200 OK"] + echoed
                + ["Contact: <\(binding)>;expires=\(request.expires ?? 300)"])
                .joined(separator: "\r\n")
        case .reject(let code):
            response = (["SIP/2.0 \(code) Rejected"] + echoed).joined(separator: "\r\n")
        }
        let datagram = Array((response + "\r\nContent-Length: 0\r\n\r\n").utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay.timeInterval) { [self] in
            send(datagram, to: peer)
        }
    }

    private func send(_ datagram: [UInt8], to peer: sockaddr_in) {
        lock.withLock {
            guard !stopped else { return }
            var peer = peer
            _ = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket, datagram, datagram.count, 0, $0,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func withTag(_ to: String) -> String {
        to.contains(";tag=") ? to : to + ";tag=scripted"
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
