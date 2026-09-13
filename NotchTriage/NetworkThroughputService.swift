import Darwin
import Foundation

@MainActor
final class NetworkThroughputService {
    private let onSnapshot: (NetworkSnapshot) -> Void
    private let onHealth: (ServiceHealth) -> Void

    private var previousInbound: UInt64?
    private var previousOutbound: UInt64?
    private var previousSampleAt: TimeInterval?

    init(
        onSnapshot: @escaping (NetworkSnapshot) -> Void,
        onHealth: @escaping (ServiceHealth) -> Void
    ) {
        self.onSnapshot = onSnapshot
        self.onHealth = onHealth
    }

    func start() {
        refresh()
    }

    func stop() {
        previousInbound = nil
        previousOutbound = nil
        previousSampleAt = nil
    }

    func refresh() {
        let sample = InterfaceByteCounters.read()
        let now = ProcessInfo.processInfo.systemUptime

        defer {
            previousInbound = sample.inbound
            previousOutbound = sample.outbound
            previousSampleAt = now
        }

        guard let previousInbound,
              let previousOutbound,
              let previousSampleAt else {
            onSnapshot(.idle)
            onHealth(.ready("网络接口计数器已就绪"))
            return
        }

        let elapsed = now - previousSampleAt
        guard elapsed > 0.05 else { return }

        // Counter reset / wrap (sleep, interface rebuild).
        guard sample.inbound >= previousInbound,
              sample.outbound >= previousOutbound else {
            onSnapshot(.idle)
            onHealth(.ready("网络计数器已重置，正在重新采样"))
            return
        }

        let downloadBps = Double(sample.inbound - previousInbound) / elapsed
        let uploadBps = Double(sample.outbound - previousOutbound) / elapsed
        onSnapshot(
            NetworkSnapshot(
                downloadBytesPerSecond: max(0, downloadBps),
                uploadBytesPerSecond: max(0, uploadBps),
                primaryInterface: sample.primaryInterface,
                updatedAt: Date()
            )
        )
        onHealth(.ready("实时网速可用"))
    }
}

private struct InterfaceByteCounters {
    let inbound: UInt64
    let outbound: UInt64
    let primaryInterface: String?

    static let zero = InterfaceByteCounters(
        inbound: 0,
        outbound: 0,
        primaryInterface: nil
    )

    static func read() -> InterfaceByteCounters {
        var ifaddrHead: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrHead) == 0, let first = ifaddrHead else {
            return .zero
        }
        defer { freeifaddrs(ifaddrHead) }

        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        var bestName: String?
        var bestBytes: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            defer { cursor = pointer.pointee.ifa_next }

            guard let addr = pointer.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }

            let flags = UInt32(pointer.pointee.ifa_flags)
            guard (flags & UInt32(IFF_UP)) != 0,
                  (flags & UInt32(IFF_LOOPBACK)) == 0 else {
                continue
            }

            let name = String(cString: pointer.pointee.ifa_name)
            guard shouldInclude(interface: name),
                  let data = pointer.pointee.ifa_data else {
                continue
            }

            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            let inBytes = UInt64(stats.ifi_ibytes)
            let outBytes = UInt64(stats.ifi_obytes)
            inbound &+= inBytes
            outbound &+= outBytes

            let total = inBytes &+ outBytes
            if total >= bestBytes {
                bestBytes = total
                bestName = name
            }
        }

        return InterfaceByteCounters(
            inbound: inbound,
            outbound: outbound,
            primaryInterface: bestName
        )
    }

    private static func shouldInclude(interface name: String) -> Bool {
        // Skip loopback / peer Wi-Fi / tunnels that double-count bridged traffic.
        let skippedPrefixes = ["lo", "awdl", "llw", "gif", "stf", "ap", "bridge"]
        return !skippedPrefixes.contains { name == $0 || name.hasPrefix($0) }
    }
}
