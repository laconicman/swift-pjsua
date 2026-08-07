// Registrar that answers every REGISTER with 200 OK and never sends
// "Require: outbound" -- the normal reply from a registrar without SIP
// outbound support.
//
// pjsua's update_rfc5626_status() sets rfc5626_status = OUTBOUND_NA on that
// reply and strips reg-id/+sip.instance from acc->reg_contact. The question
// this answers is whether the *refresh* REGISTER actually drops them.
//
// Before pjsip/pjproject#5159 is fixed: refresh #2 still carries reg-id.
// After: it does not, while the Contact URI (with ";ob") is unchanged, so the
// binding is updated in place.

import Foundation

// Line-buffer stdout so output survives being killed mid-run.
setvbuf(stdout, nil, _IOLBF, 0)

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

let port: UInt16 = 50070
let expected = 2

func header(_ name: String, in message: String) -> String? {
    message
        .split(separator: "\r\n", omittingEmptySubsequences: false)
        .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
        .map(String.init)
}

func reply(_ statusLine: String, to request: String, contact: Bool) -> String {
    var lines = [statusLine]
    for name in ["Via", "From", "Call-ID", "CSeq"] {
        if let v = header(name, in: request) { lines.append(v) }
    }
    if let to = header("To", in: request) { lines.append(to + ";tag=failover") }
    if contact, let c = header("Contact", in: request) { lines.append(c) }
    if contact { lines.append("Expires: 40") }
    lines.append("Content-Length: 0")
    return lines.joined(separator: "\r\n") + "\r\n\r\n"
}

let listener = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = port.bigEndian
addr.sin_addr.s_addr = inet_addr("127.0.0.1")
_ = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
listen(listener, 8)
FileHandle.standardError.write("no-Require registrar on 127.0.0.1:\(port)\n".data(using: .utf8)!)

var seen = 0
while seen < expected {
    let client = accept(listener, nil, nil)
    if client < 0 { continue }
    var pending = ""
    var buf = [UInt8](repeating: 0, count: 4096)
    while seen < expected {
        let n = recv(client, &buf, buf.count, 0)
        if n <= 0 { break }
        pending += String(decoding: buf[0..<n], as: UTF8.self)
        while let end = pending.range(of: "\r\n\r\n") {
            let req = String(pending[pending.startIndex..<end.upperBound])
            pending = String(pending[end.upperBound...])
            guard req.hasPrefix("REGISTER") else { continue }

            seen += 1
            let hasRegId = req.contains("reg-id")
            print("=========== REGISTER #\(seen) (reg-id: \(hasRegId)) ===========")
            print(req)

            // Always 200 OK, always without Require: outbound.
            let out = reply("SIP/2.0 200 OK", to: req, contact: true)
            print("--- responding: \(out.split(separator: "\r\n")[0]) ---\n")
            _ = out.withCString { send(client, $0, strlen($0), 0) }
        }
    }
    close(client)
}
close(listener)
print("TOTAL REGISTERs: \(seen)")
