// UDP registrar that answers EVERY REGISTER with 439, whether or not the
// request advertised SIP outbound.
//
// A UDP account never emits reg-id (update_regc_contact() bails on the
// transport check), so per RFC 5626 section 6 a 439 here is non-conformant.
// pjsua must therefore NOT treat it as an outbound rejection: expect exactly
// one REGISTER and no retry.

import Foundation

// Line-buffer stdout so output survives being killed mid-run.
setvbuf(stdout, nil, _IOLBF, 0)

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let port: UInt16 = 50070
let runSeconds: Double = 100

func header(_ name: String, in message: String) -> String? {
    message
        .split(separator: "\r\n", omittingEmptySubsequences: false)
        .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
        .map(String.init)
}

let sock = socket(AF_INET, SOCK_DGRAM, 0)
guard sock >= 0 else { fatalError("socket() failed") }
var yes: Int32 = 1
setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")

let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
guard bound == 0 else { fatalError("bind() failed: \(errno)") }

// Don't block past the run window.
var tv = timeval(tv_sec: 2, tv_usec: 0)
setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

FileHandle.standardError.write("udp registrar listening on 127.0.0.1:\(port)\n".data(using: .utf8)!)

let deadline = Date().addingTimeInterval(runSeconds)
var seen = 0
var buffer = [UInt8](repeating: 0, count: 8192)

while Date() < deadline {
    var from = sockaddr_in()
    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let n = withUnsafeMutablePointer(to: &from) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { fp in
            recvfrom(sock, &buffer, buffer.count, 0, fp, &fromLen)
        }
    }
    if n <= 0 { continue }

    let request = String(decoding: buffer[0..<n], as: UTF8.self)
    guard request.hasPrefix("REGISTER") else { continue }

    seen += 1
    print("=========== REGISTER #\(seen) ===========")
    print(request)
    print("--- advertises outbound (reg-id)? \(request.contains("reg-id")) ---")

    var lines = ["SIP/2.0 439 First Hop Lacks Outbound Support"]
    for name in ["Via", "From", "Call-ID", "CSeq"] {
        if let v = header(name, in: request) { lines.append(v) }
    }
    if let to = header("To", in: request) { lines.append(to + ";tag=439udp") }
    lines.append("Content-Length: 0")
    let reply = lines.joined(separator: "\r\n") + "\r\n\r\n"

    _ = reply.withCString { cs in
        withUnsafePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { fp in
                sendto(sock, cs, strlen(cs), 0, fp, fromLen)
            }
        }
    }
    print("--- responded 439 ---\n")
}

close(sock)
print("TOTAL REGISTERs received: \(seen)")
