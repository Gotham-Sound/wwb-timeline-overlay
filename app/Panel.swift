// Panel.swift: draws the RF dashboard with Core Graphics. Same geometry as player.html and
// render.py; keep the three in step.

import Cocoa

struct PanelOptions {
    var scale = 1.0
    var opacity = 0.85
    var side = "right"
    var showIdle = false
    var history = true
}

final class PanelRenderer {
    let tl: Timeline
    let outW: Int, outH: Int
    let sc: CGFloat
    let opt: PanelOptions
    private let channels: [TLChannel]

    static let green = NSColor(srgbRed: 0x39/255, green: 0xd3/255, blue: 0x53/255, alpha: 1)
    static let yellow = NSColor(srgbRed: 0xf2/255, green: 0xc9/255, blue: 0x4c/255, alpha: 1)
    static let red = NSColor(srgbRed: 1, green: 0x4d/255, blue: 0x4d/255, alpha: 1)
    static let text = NSColor(srgbRed: 0xf2/255, green: 0xf6/255, blue: 0xfa/255, alpha: 1)
    static let subtext = NSColor(srgbRed: 0x8f/255, green: 0xa3/255, blue: 0xb8/255, alpha: 1)
    static let dimtext = NSColor(srgbRed: 0x6b/255, green: 0x7c/255, blue: 0x8f/255, alpha: 1)
    static let value = NSColor(srgbRed: 0xc9/255, green: 0xd6/255, blue: 0xe3/255, alpha: 1)
    static let track = NSColor(white: 1, alpha: 0.10)
    static let stripBg = NSColor(white: 1, alpha: 0.06)
    static let trace = NSColor(srgbRed: 0x9f/255, green: 0xd3/255, blue: 1, alpha: 1)
    static let idleBar = NSColor(white: 0x55/255, alpha: 1)

    init(timeline: Timeline, outW: Int, outH: Int, options: PanelOptions) {
        tl = timeline; self.outW = outW; self.outH = outH; opt = options
        sc = CGFloat(options.scale) * CGFloat(outW) / 1280
        channels = timeline.channels.sorted { $0.number < $1.number }
    }

    static func levelColor(_ dbm: Double) -> NSColor { dbm > -70 ? green : dbm > -85 ? yellow : red }
    static func audioColor(_ db: Int) -> NSColor { db > -6 ? red : db > -18 ? yellow : green }

    /// Size of the panel for a given number of rows.
    func panelSize(rows: Int) -> CGSize {
        let W = 432 * sc, rowH = 38 * sc, pad = 8 * sc, headH = 24 * sc
        return CGSize(width: W, height: headH + pad + CGFloat(max(rows, 1)) * rowH + pad)
    }

    /// Draw the whole frame's overlay into a y-down context of size outW x outH (transparent elsewhere).
    func draw(in ctx: CGContext, frame: Int?, wall: Int64?) {
        let inRange = frame != nil && frame! >= 0 && frame! < tl.frameCount
        var rows: [(TLChannel, TLSample)] = []
        if inRange {
            for s in tl.samples(frame: frame!) where s.active || opt.showIdle {
                if let c = tl.byNumber[s.channel] { rows.append((c, s)) }
            }
            rows.sort { $0.0.number < $1.0.number }
        }
        let size = panelSize(rows: rows.count)
        let margin = 12 * sc
        let x0 = opt.side == "right" ? CGFloat(outW) - size.width - margin : margin
        let y0 = margin
        let pad = 8 * sc, headH = 24 * sc, rowH = 38 * sc

        ctx.saveGState()
        ctx.translateBy(x: x0, y: y0)
        // background
        ctx.setFillColor(NSColor(srgbRed: 0x0b/255, green: 0x0f/255, blue: 0x14/255, alpha: CGFloat(opt.opacity)).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: size.height), cornerWidth: 8 * sc, cornerHeight: 8 * sc, transform: nil))
        ctx.fillPath()
        // header
        text(ctx, "WIRELESS RF", x: pad, baseline: 16 * sc, font: .systemFont(ofSize: 13 * sc, weight: .semibold), color: NSColor(srgbRed: 0xe8/255, green: 0xee/255, blue: 0xf5/255, alpha: 1))
        let clock = wall != nil ? WallClock.format(wall!) : "set anchor"
        text(ctx, clock, x: size.width - pad, baseline: 16 * sc, font: mono(12 * sc), color: NSColor(srgbRed: 0x9f/255, green: 0xb3/255, blue: 0xc8/255, alpha: 1), align: .right)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.12).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: pad, y: headH)); ctx.addLine(to: CGPoint(x: size.width - pad, y: headH)); ctx.strokePath()

        let msgColor = NSColor(srgbRed: 0x88/255, green: 0x99/255, blue: 0xaa/255, alpha: 1)
        if !inRange {
            let msg = wall == nil ? "Anchor not set" : "No telemetry (recording \(WallClock.format(tl.startMs, tenths: false)) to \(WallClock.format(tl.endMs, tenths: false)))"
            text(ctx, msg, x: pad, baseline: headH + pad + 22 * sc, font: .systemFont(ofSize: 12 * sc), color: msgColor)
        } else if rows.isEmpty {
            text(ctx, "No active transmitters", x: pad, baseline: headH + pad + 22 * sc, font: .systemFont(ofSize: 12 * sc), color: msgColor)
        }
        var y = headH + pad
        for (c, s) in rows {
            if s.active {
                drawRow(ctx, c, s, x: pad, y: y, w: size.width - 2 * pad, h: rowH, wall: wall!, frame: frame!)
            } else {
                ctx.saveGState(); ctx.setAlpha(0.45); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                drawRow(ctx, c, s, x: pad, y: y, w: size.width - 2 * pad, h: rowH, wall: wall!, frame: frame!)
                ctx.endTransparencyLayer(); ctx.restoreGState()
            }
            y += rowH
        }
        ctx.restoreGState()
    }

    private func activeDrop(_ ch: Int, _ wall: Int64) -> TLEvent? {
        guard let list = tl.eventsByChannel[ch] else { return nil }
        for e in list.reversed() {
            if e.startMs > wall + 100 { continue }
            if wall <= max(e.endMs, e.startMs) + 600 && e.type == "No RF Connection" { return e }
            if e.startMs < wall - 5000 { break }
        }
        return nil
    }

    private func drawRow(_ ctx: CGContext, _ c: TLChannel, _ s: TLSample, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, wall: Int64, frame: Int) {
        let ev = s.active ? activeDrop(c.number, wall) : nil
        if ev != nil {
            fillRound(ctx, CGRect(x: x - 4 * sc, y: y + 1, width: w + 8 * sc, height: h - 2), r: 4 * sc, color: NSColor(srgbRed: 1, green: 60/255, blue: 60/255, alpha: 0.22))
        }
        text(ctx, c.name, x: x, baseline: y + 14 * sc, font: .systemFont(ofSize: 12.5 * sc, weight: .semibold), color: Self.text)
        var sub: String
        if let f = c.frequencyKHz { sub = String(format: "%.3f", Double(f) / 1000) + (c.txName != nil ? " " + c.txName! : "") }
        else { sub = c.txName ?? c.group }
        if sub.count > 13 { sub = String(sub.prefix(13)) }
        text(ctx, sub, x: x, baseline: y + 27 * sc, font: mono(8.5 * sc), color: Self.subtext)
        // RSSI bars
        let bx = x + 78 * sc, bw = 82 * sc, bh = 6 * sc
        for (label, v, yy) in [("A", s.rssiA, y + 6 * sc), ("B", s.rssiB, y + 19 * sc)] {
            text(ctx, label, x: bx - 9 * sc, baseline: yy + bh, font: mono(9 * sc), color: Self.dimtext)
            fill(ctx, CGRect(x: bx, y: yy, width: bw, height: bh), Self.track)
            let f = max(0, min(1, (v + 120) / 100))
            if f > 0 { fill(ctx, CGRect(x: bx, y: yy, width: bw * CGFloat(f), height: bh), s.active ? Self.levelColor(v) : Self.idleBar) }
            text(ctx, String(format: "%.0f", v), x: bx + bw + 24 * sc, baseline: yy + bh, font: mono(9 * sc), color: Self.value, align: .right)
        }
        // quality pips + battery
        let qx = x + 200 * sc
        for i in 0..<5 {
            let on = s.quality != nil && i < s.quality!
            let col = on ? (s.quality! >= 4 ? Self.green : s.quality! >= 2 ? Self.yellow : Self.red) : NSColor(white: 1, alpha: 0.12)
            fill(ctx, CGRect(x: qx + CGFloat(i) * 7 * sc, y: y + 5 * sc, width: 5 * sc, height: 7 * sc), col)
        }
        fill(ctx, CGRect(x: qx, y: y + 19 * sc, width: 34 * sc, height: 6 * sc), Self.track)
        if let pct = s.batteryPct {
            let col = pct > 30 ? Self.green : pct > 15 ? Self.yellow : Self.red
            fill(ctx, CGRect(x: qx, y: y + 19 * sc, width: 34 * sc * CGFloat(pct) / 100, height: 6 * sc), col)
            text(ctx, "\(pct)%", x: qx + 37 * sc, baseline: y + 25 * sc, font: mono(9 * sc), color: Self.value)
        }
        // RF meter bars (receiver's own 0..5 meter) and ShowLink pips
        let mx = x + 266 * sc
        text(ctx, "RF", x: mx, baseline: y + 12 * sc, font: mono(8.5 * sc), color: Self.dimtext)
        for i in 0..<5 {
            let on = s.rfBars != nil && i < s.rfBars!
            let col = on ? (s.rfBars! >= 4 ? Self.green : s.rfBars! >= 2 ? Self.yellow : Self.red) : NSColor(white: 1, alpha: 0.12)
            fill(ctx, CGRect(x: mx + 14 * sc + CGFloat(i) * 7 * sc, y: y + 5 * sc, width: 5 * sc, height: 7 * sc), col)
        }
        let hasSL = s.showLink != nil
        text(ctx, "SL", x: mx, baseline: y + 25 * sc, font: mono(8.5 * sc), color: hasSL ? Self.dimtext : NSColor(white: 1, alpha: 0.25))
        for i in 0..<5 {
            let on = hasSL && i < s.showLink!
            let col = on ? Self.trace : NSColor(white: 1, alpha: hasSL ? 0.12 : 0.06)
            fill(ctx, CGRect(x: mx + 14 * sc + CGFloat(i) * 7 * sc, y: y + 18 * sc, width: 5 * sc, height: 7 * sc), col)
        }
        // audio meter
        let ax = x + 322 * sc, aw = 44 * sc
        fill(ctx, CGRect(x: ax, y: y + 5 * sc, width: aw, height: 20 * sc), Self.track)
        if s.active {
            let f = max(0, min(1, (Double(s.audioDb) + 60) / 60))
            if f > 0 { fill(ctx, CGRect(x: ax, y: y + 5 * sc, width: aw * CGFloat(f), height: 20 * sc), Self.audioColor(s.audioDb)) }
            text(ctx, "AUD", x: ax + 2 * sc, baseline: y + 32 * sc, font: mono(8.5 * sc), color: Self.dimtext)
        }
        // history strip
        if opt.history {
            let hx = x + 372 * sc, hw = 44 * sc, hy = y + 5 * sc, hh = 20 * sc
            fill(ctx, CGRect(x: hx, y: hy, width: hw, height: hh), Self.stripBg)
            let n = 40, span = 200
            let path = CGMutablePath(); var started = false
            for k in 0...n {
                let fi = frame - span + Int((Double(k) * Double(span) / Double(n)).rounded())
                if fi < 0 { continue }
                guard let v = tl.rssiMax(frame: fi, channel: c.number) else { continue }
                let px = hx + hw * CGFloat(k) / CGFloat(n)
                let py = hy + hh * CGFloat(1 - max(0, min(1, (v + 120) / 100)))
                if started { path.addLine(to: CGPoint(x: px, y: py)) } else { path.move(to: CGPoint(x: px, y: py)); started = true }
            }
            ctx.setStrokeColor((s.active ? Self.trace : Self.idleBar).cgColor)
            ctx.setLineWidth(max(1, 1.2 * sc)); ctx.addPath(path); ctx.strokePath()
            text(ctx, "RF 20s", x: hx + 2 * sc, baseline: y + 32 * sc, font: mono(8.5 * sc), color: Self.dimtext)
            let t0 = wall - 20000
            for e in (tl.eventsByChannel[c.number] ?? []).reversed() {
                if e.startMs < t0 - 2000 { break }
                if e.type != "No RF Connection" || e.startMs > wall { continue }
                let px = hx + hw * CGFloat(e.startMs - t0) / 20000
                let pw = max(1, hw * CGFloat(max(e.endMs - e.startMs, 100)) / 20000)
                fill(ctx, CGRect(x: px, y: hy, width: pw, height: hh), Self.red)
            }
        }
        if ev != nil {
            text(ctx, "RF DROP", x: x + 78 * sc, baseline: y + 35 * sc, font: .systemFont(ofSize: 10 * sc, weight: .bold), color: Self.red)
        }
    }

    // MARK: primitives
    private func mono(_ size: CGFloat) -> NSFont { NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }

    private func fill(_ ctx: CGContext, _ r: CGRect, _ color: NSColor) {
        ctx.setFillColor(color.cgColor); ctx.fill(r)
    }
    private func fillRound(_ ctx: CGContext, _ r: CGRect, r radius: CGFloat, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.fillPath()
    }

    enum Align { case left, right }
    /// Draw text in a y-down context, positioned by baseline.
    private func text(_ ctx: CGContext, _ s: String, x: CGFloat, baseline: CGFloat, font: NSFont, color: NSColor, align: Align = .left) {
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        let px = align == .right ? x - size.width : x
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        attr.draw(at: NSPoint(x: px, y: baseline - font.ascender))
        NSGraphicsContext.restoreGraphicsState()
    }
}
