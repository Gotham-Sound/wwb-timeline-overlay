// Timeline.swift: native decoder for WWB Timeline (.tline) files and the show file (.shw).
// Mirrors tline.py and shw.py; the format notes live at the top of tline.py.

import Foundation

enum TLError: Error, LocalizedError {
    case notTline, badIndex, notFound(String)
    var errorDescription: String? {
        switch self {
        case .notTline: return "Not a Wireless Workbench Timeline (.tline) file."
        case .badIndex: return "Frame index does not match the data block."
        case .notFound(let s): return "Not found: \(s)"
        }
    }
}

struct TLChannel {
    let number: Int
    let name: String
    let group: String
    let deviceId: String
    let slot: Int
    var frequencyKHz: Int?
    var txName: String?
    var model: String?
    var band: String?
}

struct TLEvent {
    let startMs: Int64
    let endMs: Int64
    let type: String
    let channelName: String
    let description: String
    let channel: Int
}

struct TLSample {
    let channel: Int
    let rssiA: Double, rssiB: Double, rssiC: Double, rssiD: Double
    let audioDb: Int
    let quality: Int?
    let bars: Int?
    let slot: Int
    let batteryPct: Int?
    let rfBars: Int?
    let showLink: Int?
    var active: Bool { quality != nil }
}

final class Timeline {
    let bytes: [UInt8]
    let intervalMs: Int
    let summaryMs: Int
    let startMs: Int64
    var channels: [TLChannel] = []
    let frameCount: Int
    let frameOffsets: [Int]
    let frameLengths: [Int]
    let events: [TLEvent]
    let eventsByChannel: [Int: [TLEvent]]
    var byNumber: [Int: TLChannel] = [:]

    static let payloadLen = 19
    static let headerLen = 43

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        bytes = [UInt8](data)
        let b = bytes
        guard b.count > Timeline.headerLen, b[0] == 0x7a, b[1] == 0xda, b[2] == 0x03 else { throw TLError.notTline }
        func u64(_ o: Int) -> Int64 {
            var v: UInt64 = 0
            for k in 0..<8 { v |= UInt64(b[o + k]) << (8 * k) }
            return Int64(bitPattern: v)
        }
        func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
        func cstring(_ o: inout Int) -> String {
            var e = o
            while e < b.count && b[e] != 0 { e += 1 }
            let s = String(bytes: b[o..<e], encoding: .isoLatin1) ?? ""
            o = e + 1
            return s
        }
        var offs: [Int] = []
        for i in 0..<5 { offs.append(Int(u64(3 + 8 * i))) }

        // section 0: info + channel table
        let s0 = offs[0]
        intervalMs = Int(b[s0 + 1])
        summaryMs = u16(s0 + 2)
        startMs = u64(s0 + 4)
        let text = String(bytes: b[s0..<offs[1]], encoding: .isoLatin1) ?? ""
        let pattern = "([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\\x00([\\s\\S])([\\s\\S])([^\\x00]*)\\x00(\\[[^\\x00]*\\])\\x00"
        let re = try NSRegularExpression(pattern: pattern, options: [])
        let ns = text as NSString
        var chans: [TLChannel] = []
        for m in re.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) {
            let slotStr = ns.substring(with: m.range(at: 2)), numStr = ns.substring(with: m.range(at: 3))
            chans.append(TLChannel(number: Int(numStr.unicodeScalars.first!.value),
                                   name: ns.substring(with: m.range(at: 4)),
                                   group: ns.substring(with: m.range(at: 5)),
                                   deviceId: ns.substring(with: m.range(at: 1)),
                                   slot: Int(slotStr.unicodeScalars.first!.value)))
        }
        channels = chans

        // section 1: frame index
        let n = Int(u64(offs[1]))
        var lens: [Int] = []; lens.reserveCapacity(n)
        var foffs: [Int] = []; foffs.reserveCapacity(n + 1)
        var o = Timeline.headerLen
        for i in 0..<n {
            foffs.append(o)
            let L = u16(offs[1] + 8 + 2 * i)
            lens.append(L)
            o += L
        }
        foffs.append(o)
        guard o == offs[0] else { throw TLError.badIndex }
        frameCount = n; frameLengths = lens; frameOffsets = foffs

        // section 3: events
        var pos = offs[3]
        let ne = u16(pos); pos += 2
        var evs: [TLEvent] = []
        for _ in 0..<ne {
            let t0 = u64(pos), t1 = u64(pos + 8); pos += 16
            let type = cstring(&pos), chName = cstring(&pos), desc = cstring(&pos)
            let ch = Int(b[pos + 6]); pos += 7
            evs.append(TLEvent(startMs: t0, endMs: t1 == 0 ? t0 : t1, type: type, channelName: chName, description: desc, channel: ch))
        }
        evs.sort { $0.startMs < $1.startMs }
        events = evs
        var byCh: [Int: [TLEvent]] = [:]
        for e in evs { byCh[e.channel, default: []].append(e) }
        eventsByChannel = byCh
        for c in channels { byNumber[c.number] = c }
    }

    var endMs: Int64 { startMs + Int64(frameCount * intervalMs) }

    func frameIndex(atMs ms: Int64) -> Int? {
        let i = (ms - startMs) / Int64(intervalMs)
        return (ms >= startMs && i < Int64(frameCount)) ? Int(i) : nil
    }

    private func i16(_ o: Int) -> Int {
        Int(Int16(bitPattern: UInt16(bytes[o]) | (UInt16(bytes[o + 1]) << 8)))
    }

    /// Decode frame i (current values only).
    func samples(frame i: Int) -> [TLSample] {
        let off = frameOffsets[i], len = frameLengths[i]
        let n = Int(bytes[off])
        guard n > 0 else { return [] }
        let per = (len - 1) / n
        var out: [TLSample] = []; out.reserveCapacity(n)
        var pos = off + 1
        for _ in 0..<n {
            let ch = Int(bytes[pos]), p = pos + 1
            let q = Int(bytes[p + 10]), pct = Int(bytes[p + 13]), b16 = Int(bytes[p + 16])
            let active = q != 255
            out.append(TLSample(channel: ch,
                                rssiA: Double(i16(p)) / 10, rssiB: Double(i16(p + 2)) / 10,
                                rssiC: Double(i16(p + 4)) / 10, rssiD: Double(i16(p + 6)) / 10,
                                audioDb: i16(p + 8),
                                quality: active ? q : nil,
                                bars: active ? Int(bytes[p + 11]) : nil,
                                slot: Int(bytes[p + 12]),
                                batteryPct: pct == 255 ? nil : pct,
                                rfBars: (b16 >> 2) & 7 == 7 ? nil : (b16 >> 2) & 7,
                                showLink: (b16 >> 5) == 7 ? nil : b16 >> 5))
            pos += per
        }
        return out
    }

    /// max(A, B) RSSI in dBm for one channel at frame i.
    func rssiMax(frame i: Int, channel: Int) -> Double? {
        let off = frameOffsets[i], len = frameLengths[i]
        let n = Int(bytes[off])
        guard n > 0 else { return nil }
        let per = (len - 1) / n
        var pos = off + 1
        for _ in 0..<n {
            if Int(bytes[pos]) == channel {
                return Double(max(i16(pos + 1), i16(pos + 3))) / 10
            }
            pos += per
        }
        return nil
    }

    // MARK: show file enrichment (.shw is XML)
    func applyShow(url: URL) throws {
        let doc = try XMLDocument(contentsOf: url, options: [])
        guard let devices = try doc.nodes(forXPath: "/show/inventory/device") as? [XMLElement] else { return }
        var byId: [String: XMLElement] = [:]
        for d in devices {
            if let id = d.elements(forName: "id").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
                byId[id] = d
            }
        }
        for (k, var c) in byNumber {
            guard let dev = byId[c.deviceId] else { continue }
            c.model = dev.elements(forName: "model").first?.stringValue?.trimmingCharacters(in: .whitespaces)
            c.band = dev.elements(forName: "band").first?.stringValue?.trimmingCharacters(in: .whitespaces)
            for ch in dev.elements(forName: "channel") {
                guard let numS = ch.attribute(forName: "number")?.stringValue, Int(numS) == c.slot + 1 else { continue }
                let txt = { (tag: String) -> String in ch.elements(forName: tag).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                c.frequencyKHz = Int(txt("frequency"))
                let linked = txt("child3_id").lowercased()
                for r in 1...8 where !linked.isEmpty && txt("regtx\(r)_id").lowercased() == linked {
                    let name = txt("regtx\(r)_name")
                    if !name.isEmpty { c.txName = name }
                }
            }
            byNumber[k] = c
        }
        channels = channels.map { byNumber[$0.number] ?? $0 }
    }
}

// MARK: - wall-clock helpers (pseudo-UTC ms, see tline.py)

enum WallClock {
    static func format(_ ms: Int64, tenths: Bool = true) -> String {
        let s = Double(ms) / 1000
        let day = floor(s / 86400), r = s - day * 86400
        let h = Int(r / 3600), m = Int(r.truncatingRemainder(dividingBy: 3600) / 60)
        let sec = r.truncatingRemainder(dividingBy: 60)
        return tenths ? String(format: "%02d:%02d:%04.1f", h, m, floor(sec * 10) / 10)
                      : String(format: "%02d:%02d:%02d", h, m, Int(sec))
    }

    /// "HH:MM:SS[.f]" on the recording's day -> pseudo-UTC ms
    static func parse(_ text: String, dayOf startMs: Int64) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var sec = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; sec = sec * 60 + v }
        let midnight = startMs - (startMs % 86_400_000)
        return midnight + Int64(sec * 1000)
    }

    /// "m:ss.s" or "h:mm:ss" -> seconds
    static func parseVideoTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var sec = 0.0
        for p in parts { guard let v = Double(p) else { return nil }; sec = sec * 60 + v }
        return sec
    }
}
