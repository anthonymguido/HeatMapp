import Darwin
import Foundation

struct PingStats {
    var sent = 0
    var received = 0
    var rtts: [Double] = []   // milliseconds, in order

    var lossPct: Double { sent > 0 ? Double(sent - received) / Double(sent) * 100 : 0 }

    var median: Double? {
        guard !rtts.isEmpty else { return nil }
        let s = rtts.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Mean difference between consecutive replies (the usual definition of jitter).
    var jitter: Double? {
        guard rtts.count > 1 else { return rtts.isEmpty ? nil : 0 }
        return zip(rtts, rtts.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(rtts.count - 1)
    }
}

enum PingError: LocalizedError {
    case badAddress(String)
    case socket(Int32)
    case blocked
    case noReplies

    var errorDescription: String? {
        switch self {
        case .badAddress(let a): return "\"\(a)\" isn't a valid IPv4 address."
        case .socket(let code): return "Couldn't open a ping socket (\(String(cString: strerror(code))))."
        case .blocked: return "Can't reach the router. Check Settings → Privacy & Security → Local Network → Wi-Fi Heatmap is on."
        case .noReplies: return "The router didn't answer. Check Settings → Privacy & Security → Local Network → Wi-Fi Heatmap is on. (A few routers ignore pings.)"
        }
    }
}

/// ICMP echo ("ping") using an unprivileged datagram socket, which iOS allows.
enum Pinger {
    /// Blocking: call it off the main thread.
    static func ping(_ host: String, count: Int, interval: TimeInterval = 0.05, timeout: TimeInterval = 0.5) throws -> PingStats {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { throw PingError.badAddress(host) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw PingError.socket(errno) }
        defer { close(fd) }

        // Receive in short slices so we can keep checking the per-ping deadline.
        var tv = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let identifier = UInt16.random(in: 1...UInt16.max)
        var stats = PingStats()
        var buffer = [UInt8](repeating: 0, count: 2048)
        var sendFailures = 0

        for seq in 0..<max(1, count) {
            let sequence = UInt16(truncatingIfNeeded: seq)
            let packet = makePacket(identifier: identifier, sequence: sequence)
            let start = DispatchTime.now().uptimeNanoseconds
            stats.sent += 1

            let sent = packet.withUnsafeBytes { raw -> Int in
                withUnsafePointer(to: target) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }

            if sent < 0 {
                sendFailures += 1
            } else {
                let deadline = start + UInt64(timeout * 1_000_000_000)
                while DispatchTime.now().uptimeNanoseconds < deadline {
                    var from = sockaddr_in()
                    var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = buffer.withUnsafeMutableBytes { raw -> Int in
                        withUnsafeMutablePointer(to: &from) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                            }
                        }
                    }
                    guard n > 0 else { continue }   // slice timed out; check the deadline again
                    guard from.sin_addr.s_addr == target.sin_addr.s_addr,
                          replySequence(buffer, count: n) == sequence else { continue }
                    let end = DispatchTime.now().uptimeNanoseconds
                    stats.received += 1
                    stats.rtts.append(Double(end - start) / 1_000_000)
                    break
                }
            }

            // Keep a steady pace between pings.
            let spentNs = DispatchTime.now().uptimeNanoseconds - start
            let waitNs = Int64(interval * 1_000_000_000) - Int64(spentNs)
            if waitNs > 0 { usleep(useconds_t(waitNs / 1000)) }
        }

        if stats.received == 0 {
            throw sendFailures == stats.sent ? PingError.blocked : PingError.noReplies
        }
        return stats
    }

    private static func makePacket(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 8 + 56)
        p[0] = 8   // echo request
        p[1] = 0
        p[4] = UInt8(identifier >> 8); p[5] = UInt8(identifier & 0xFF)
        p[6] = UInt8(sequence >> 8); p[7] = UInt8(sequence & 0xFF)
        for i in 8..<p.count { p[i] = UInt8(truncatingIfNeeded: i) }
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8); p[3] = UInt8(sum & 0xFF)
        return p
    }

    private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += (UInt32(data[i]) << 8) | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// Sequence number of an echo reply, or nil. The kernel may include the IPv4 header; skip it.
    private static func replySequence(_ b: [UInt8], count n: Int) -> UInt16? {
        var offset = 0
        if n >= 20, b[0] >> 4 == 4 { offset = Int(b[0] & 0x0F) * 4 }
        guard n >= offset + 8, b[offset] == 0 else { return nil }   // type 0 = echo reply
        return (UInt16(b[offset + 6]) << 8) | UInt16(b[offset + 7])
    }
}
