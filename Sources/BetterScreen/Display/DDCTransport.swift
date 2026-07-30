import CDisplayBridge
import CoreGraphics
import Foundation

/// DDC/CI VCP feature codes.
enum VCP: UInt8 {
    case brightness = 0x10
    case contrast = 0x12
}

/// DDC/CI transport over I2C via `IOAVServiceWriteI2C` / `IOAVServiceReadI2C`.
///
/// Every transaction for *every* display is funnelled through one serial queue.
/// Interleaving I2C transactions across displays corrupts them, so this is not
/// merely defensive.
///
/// Measured behaviour on a DELL P2723QE over DisplayPort-alt-mode USB-C
/// (M3 Pro, macOS 26.5):
///   - writes:  25/25 succeeded, ~3.05 ms each, reliable even back-to-back
///   - reads:   valid reply 24/25, correct value 22/25, avg 2.12 attempts
///
/// Hence the design rule: **writes are trustworthy, reads are not.** In steady
/// state we never read; the app is the source of truth for brightness.
final class DDCTransport {
    static let shared = DDCTransport()

    /// 7-bit DDC/CI slave address. The only value the DCP accepts -- 0x6E (the
    /// 8-bit write form) and 0x51 both fail with 0xE0114000.
    private static let slaveAddress: UInt32 = 0x37

    /// DDC/CI host sub-address, used for writes and folded into the checksum.
    private static let hostAddress: UInt8 = 0x51

    // Timings. Derived from a delay sweep on real hardware, not from folklore.
    private static let preWriteDelay: useconds_t = 10_000   // 10 ms before each write
    private static let replyDelay: useconds_t = 50_000      // 50 ms before reading a reply
    private static let retryDelay: useconds_t = 20_000      // 20 ms between attempts
    private static let requestWriteCycles = 2               // Get requests are sent twice
    private static let maxAttempts = 5

    /// A Set VCP command makes the panel ignore DDC traffic for >= 50 ms. The
    /// sweep was unambiguous: with a 50 ms reply delay, a following read returned
    /// a valid frame 0/6 times at a 40 ms settle and only 3/6 at 50 ms. VESA
    /// DDC/CI 4.4 specifies >= 50 ms after Set VCP.
    private static let postSetSettle: TimeInterval = 0.050

    private let queue = DispatchQueue(label: "com.betterscreen.ddc")
    private var lastSetVCPTime: [CGDirectDisplayID: DispatchTime] = [:]

    private init() {}

    // MARK: - Public API

    /// Sends a Set VCP Feature command. Write-only; no verification read.
    ///
    /// A `kIOReturnSuccess` here means the DCP accepted the transaction, not that
    /// the monitor honoured it. There is no cheap way to know the difference.
    @discardableResult
    func setVCP(
        _ vcp: VCP,
        value: UInt16,
        service: IOAVService,
        displayID: CGDirectDisplayID
    ) -> Bool {
        queue.sync {
            waitForSettle(displayID)
            let packet = Self.buildPacket(payload: [vcp.rawValue, UInt8(value >> 8), UInt8(value & 0xFF)])
            var ok = false
            for attempt in 1 ... Self.maxAttempts {
                usleep(Self.preWriteDelay)
                ok = Self.write(packet, service: service)
                if ok { break }
                if attempt < Self.maxAttempts { usleep(Self.retryDelay) }
            }
            lastSetVCPTime[displayID] = .now()
            return ok
        }
    }

    /// Sends a Get VCP Feature request and parses the reply.
    ///
    /// Only used at startup, or when the user explicitly asks to read the
    /// display's current state -- see the reliability figures above.
    func getVCP(
        _ vcp: VCP,
        service: IOAVService,
        displayID: CGDirectDisplayID
    ) -> (current: UInt16, max: UInt16)? {
        queue.sync {
            waitForSettle(displayID)
            let request = Self.buildPacket(payload: [vcp.rawValue])

            for attempt in 1 ... Self.maxAttempts {
                // Sending the request twice is not just redundancy: the second
                // write buys another ~10 ms of settle, which measurably improves
                // the odds of a valid reply.
                for _ in 0 ..< Self.requestWriteCycles {
                    usleep(Self.preWriteDelay)
                    _ = Self.write(request, service: service)
                }

                usleep(Self.replyDelay)

                var reply = [UInt8](repeating: 0, count: 11)
                let result = reply.withUnsafeMutableBytes { buffer in
                    IOAVServiceReadI2C(
                        service,
                        Self.slaveAddress,
                        0, // the offset argument is ignored by the DCP for DDC reads
                        buffer.baseAddress!,
                        UInt32(buffer.count)
                    )
                }

                if result == kIOReturnSuccess, let parsed = Self.parseReply(reply, expecting: vcp) {
                    return parsed
                }

                if attempt < Self.maxAttempts { usleep(Self.retryDelay) }
            }
            return nil
        }
    }

    // MARK: - Wire format

    /// Builds a DDC/CI packet: length header, payload, trailing XOR checksum.
    ///
    ///   Set VCP: 84 03 <vcp> <hi> <lo> <chk>
    ///   Get VCP: 82 01 <vcp> <chk>
    ///
    /// The checksum seed is asymmetric, which is the easiest thing here to get
    /// wrong: writes seed with `0x6E ^ 0x51`, reads seed with `0x6E` alone.
    private static func buildPacket(payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)]
        packet.append(contentsOf: payload)
        packet.append(0)

        let seed: UInt8 = payload.count == 1
            ? UInt8(slaveAddress) << 1                 // Get: 0x6E
            : (UInt8(slaveAddress) << 1) ^ hostAddress // Set: 0x6E ^ 0x51 = 0x3F

        packet[packet.count - 1] = checksum(seed: seed, bytes: packet, upTo: packet.count - 2)
        return packet
    }

    private static func checksum(seed: UInt8, bytes: [UInt8], upTo lastIndex: Int) -> UInt8 {
        var value = seed
        for index in 0 ... lastIndex { value ^= bytes[index] }
        return value
    }

    private static func write(_ packet: [UInt8], service: IOAVService) -> Bool {
        var mutable = packet
        return mutable.withUnsafeMutableBytes { buffer in
            IOAVServiceWriteI2C(
                service,
                slaveAddress,
                UInt32(hostAddress),
                buffer.baseAddress!,
                UInt32(buffer.count)
            ) == kIOReturnSuccess
        }
    }

    /// Validates and decodes an 11-byte Get VCP Feature Reply.
    ///
    ///   6E 88 02 00 10 00 <max hi> <max lo> <cur hi> <cur lo> <chk>
    ///
    /// Read exactly 11 bytes. Requesting 12 and checksumming 0...10 against
    /// reply[11] yields a permanent spurious mismatch.
    private static func parseReply(_ reply: [UInt8], expecting vcp: VCP) -> (current: UInt16, max: UInt16)? {
        guard reply.count == 11 else { return nil }

        // Checksum seed for replies is 0x50, over bytes 0...9.
        guard checksum(seed: 0x50, bytes: reply, upTo: 9) == reply[10] else { return nil }

        // Cold-start reads frequently return the repeating pattern
        // 6E 80 BE 6E 80 BE ... which passes no validation but, if parsed blind,
        // decodes as max = 0x6E80 = 28288. Structural checks below reject it.
        guard reply[2] == 0x02 else { return nil }          // Get VCP Feature Reply
        guard reply[3] == 0x00 else { return nil }          // result code: no error
        guard reply[4] == vcp.rawValue else { return nil }  // echoed opcode must match

        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard maxValue > 0 else { return nil }
        return (current, maxValue)
    }

    // MARK: - Settle enforcement

    /// Blocks until at least `postSetSettle` has elapsed since the last Set VCP
    /// on this display. Must be called on `queue`.
    private func waitForSettle(_ displayID: CGDirectDisplayID) {
        guard let last = lastSetVCPTime[displayID] else { return }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000_000
        let remaining = Self.postSetSettle - elapsed
        if remaining > 0 {
            usleep(useconds_t(remaining * 1_000_000))
        }
    }
}
