// Minimal TCP SIP registrar for verifying the 439 outbound fallback.
//
// Answers any REGISTER that advertises SIP outbound (a reg-id Contact param)
// with 439 First Hop Lacks Outbound Support, exactly as RFC 5626 section 6
// requires of a registrar whose first hop is not outbound-aware. Any REGISTER
// without outbound is accepted with 200 OK.
//
// Each REGISTER is printed so the retry can be inspected on the wire. The
// retry arrives on a fresh TCP connection (pjsua tears the old one down), so
// this accepts connections sequentially in a loop.

import Foundation

// Line-buffer stdout so output survives being killed mid-run.
setvbuf(stdout, nil, _IOLBF, 0)

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let port: UInt16 = 50070
let expectedRegisters = 2

func header(_ name: String, in message: String) -> String? {
    message
        .split(separator: "\r\n", omittingEmptySubsequences: false)
        .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
        .map(String.init)
}

func response(to request: String) -> String {
    let usesOutbound = request.contains("reg-id")
    let statusLine = usesOutbound
        ? "SIP/2.0 439 First Hop Lacks Outbound Support"
        : "SIP/2.0 200 OK"

    var lines = [statusLine]
    for name in ["Via", "From", "Call-ID", "CSeq"] {
        if let value = header(name, in: request) { lines.append(value) }
    }
    if let to = header("To", in: request) { lines.append(to + ";tag=439test") }
    if !usesOutbound {
        if let contact = header("Contact", in: request) { lines.append(contact) }
        lines.append("Expires: 300")
    }
    lines.append("Content-Length: 0")
    return lines.joined(separator: "\r\n") + "\r\n\r\n"
}

let listener = socket(AF_INET, SOCK_STREAM, 0)
guard listener >= 0 else { fatalError("socket() failed") }
var yes: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")

let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bound == 0 else { fatalError("bind() failed: \(errno)") }
guard listen(listener, 8) == 0 else { fatalError("listen() failed") }

FileHandle.standardError.write("registrar listening on 127.0.0.1:\(port)\n".data(using: .utf8)!)

var seen = 0
while seen < expectedRegisters {
    let client = accept(listener, nil, nil)
    if client < 0 { continue }

    // One connection may carry more than one request; read until it closes
    // or we have answered everything we expect.
    var pending = ""
    var buffer = [UInt8](repeating: 0, count: 4096)
    while seen < expectedRegisters {
        let n = recv(client, &buffer, buffer.count, 0)
        if n <= 0 { break }
        pending += String(decoding: buffer[0..<n], as: UTF8.self)

        while let end = pending.range(of: "\r\n\r\n") {
            let request = String(pending[pending.startIndex..<end.upperBound])
            pending = String(pending[end.upperBound...])
            guard request.hasPrefix("REGISTER") else { continue }

            seen += 1
            print("=========== REGISTER #\(seen) ===========")
            print(request)

            let reply = response(to: request)
            print("--- responding: \(reply.split(separator: "\r\n")[0]) ---\n")
            _ = reply.withCString { send(client, $0, strlen($0), 0) }
        }
    }
    close(client)
}

close(listener)
print("received \(seen) REGISTER(s)")
