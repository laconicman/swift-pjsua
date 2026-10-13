// Scripted TCP registrar: one binary, one scenario per run (pjsip/pjproject#5281).
//
// usage: RegistrarScripted <scenario> <port> <expected-REGISTERs>  (see run-scripted.sh)
//
//   norequire          200 without Require: outbound, always         (WANTED -> NA)
//   active-then-na     200 with Require: outbound to #1, then without (ACTIVE -> NA)
//   failover-439       200 without Require to #1, 439 to #2 whatever it carries
//   initial-439        439 to any REGISTER carrying reg-id, else 200
//   nat-rewrite        200 with Via received=127.0.0.2                (NO_UNREG push)
//   nat-rewrite-401    401 with Via received=127.0.0.2 to #1, then 200 (ALWAYS_UPDATE)

import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

setvbuf(stdout, nil, _IOLBF, 0)

let args = CommandLine.arguments
let scenario = args.count > 1 ? args[1] : "norequire"
let port = UInt16(args.count > 2 ? args[2] : "50070")!
let expected = Int(args.count > 3 ? args[3] : "3")!

func header(_ name: String, in message: String) -> String? {
    message
        .split(separator: "\r\n", omittingEmptySubsequences: false)
        .first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
        .map(String.init)
}

struct Answer {
    var status = "200 OK"
    var require = false
    var received: String? = nil
    var challenge = false
}

func answer(_ n: Int, _ req: String) -> Answer {
    let hasRegId = req.contains("reg-id")
    switch scenario {
    case "norequire":
        return Answer()
    case "active-then-na":
        return Answer(require: n == 1)
    case "failover-439":
        return n == 2 ? Answer(status: "439 First Hop Lacks Outbound Support")
                      : Answer()
    case "initial-439":
        return hasRegId ? Answer(status: "439 First Hop Lacks Outbound Support")
                        : Answer()
    case "nat-rewrite":
        return Answer(received: "127.0.0.2")
    case "nat-rewrite-401":
        return n == 1 ? Answer(status: "401 Unauthorized", received: "127.0.0.2",
                               challenge: true)
                      : Answer(received: "127.0.0.2")
    default:
        fatalError("unknown scenario \(scenario)")
    }
}

func reply(_ a: Answer, to request: String) -> String {
    var lines = ["SIP/2.0 " + a.status]
    if var via = header("Via", in: request) {
        if let r = a.received { via += ";received=" + r }
        lines.append(via)
    }
    for name in ["From", "Call-ID", "CSeq"] {
        if let v = header(name, in: request) { lines.append(v) }
    }
    if let to = header("To", in: request) { lines.append(to + ";tag=scripted") }
    if a.status.hasPrefix("200") {
        // Echo only the live Contacts: an expires=0 one is being removed.
        for c in request.split(separator: "\r\n").map(String.init)
            where c.lowercased().hasPrefix("contact:") && !c.contains("expires=0") {
            lines.append(c)
        }
        lines.append("Expires: 40")
        if a.require { lines.append("Require: outbound") }
    }
    if a.challenge {
        lines.append("WWW-Authenticate: Digest realm=\"test\", nonce=\"abc123\", algorithm=MD5")
    }
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
FileHandle.standardError.write("\(scenario) registrar on 127.0.0.1:\(port)\n".data(using: .utf8)!)

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
            let contacts = req.split(separator: "\r\n").filter {
                $0.lowercased().hasPrefix("contact:")
            }
            print("=========== REGISTER #\(seen) (reg-id: \(req.contains("reg-id"))) ===========")
            for c in contacts { print("  " + c) }
            if let s = header("Supported", in: req) { print("  " + s) }
            let a = answer(seen, req)
            print("--- responding: \(a.status)\(a.require ? " +Require: outbound" : "")\(a.received.map { " received=" + $0 } ?? "") ---\n")
            let out = reply(a, to: req)
            _ = out.withCString { send(client, $0, strlen($0), 0) }
        }
    }
    close(client)
}
close(listener)
print("TOTAL REGISTERs: \(seen)")
