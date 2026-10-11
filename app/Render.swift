// Render.swift: native overlay rendering with AVFoundation. ProRes 4444 or HEVC, both with
// alpha, or a PNG sequence; optional burned-in preview MP4 over the program video.
// Also exposes a command-line mode: "WWB Overlay" --render ... (see RenderCLI.usage).

import Cocoa
import AVFoundation
import VideoToolbox
import UniformTypeIdentifiers

enum OverlayCodec: String { case prores, hevc, png }

struct RenderJob {
    var tlineURL: URL
    var shwURL: URL?
    var anchorVideo: Double = 292.2          // seconds into the video
    var anchorWall: String = "18:30:00.0"    // WWB wall-clock of that moment
    var trim: Double = 0
    var start: Double                        // video time to start at
    var duration: Double
    var width = 1920, height = 1080
    var fpsNum: Int32 = 30000, fpsDen: Int32 = 1001
    var codec: OverlayCodec = .prores
    var options = PanelOptions()
    var out: URL
    var burnIn: URL?
    var burnOut: URL?
}

enum RenderError: Error, LocalizedError {
    case cancelled, badAnchor, writer(String), reader(String), noVideoTrack
    var errorDescription: String? {
        switch self {
        case .cancelled: return "Render cancelled."
        case .badAnchor: return "Could not parse the sync anchor."
        case .writer(let s): return "Writer failed: \(s)"
        case .reader(let s): return "Reader failed: \(s)"
        case .noVideoTrack: return "The burn-in video has no video track."
        }
    }
}

final class Renderer {
    /// Fraction done (0...1), called from the render thread.
    var onFraction: ((Double) -> Void)?
    static let rec709: [String: Any] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    var cancelled = false
    private var cachedKey: (Int?, Int64) = (nil, -1)
    private var cachedPanel: CGImage?

    /// Blocking. Call on a background queue; progress is called on that queue.
    func run(_ job: RenderJob, progress: @escaping (String) -> Void) throws {
        // Keep the app out of App Nap and the machine awake: rendering from a background window
        // otherwise runs at a fraction of the speed.
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Rendering overlay")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let tl = try Timeline(url: job.tlineURL)
        if let s = job.shwURL { try tl.applyShow(url: s) }
        guard let anchorWallMs = WallClock.parse(job.anchorWall, dayOf: tl.startMs) else { throw RenderError.badAnchor }
        let panel = PanelRenderer(timeline: tl, outW: job.width, outH: job.height, options: job.options)
        func wallAt(_ t: Double) -> Int64 { anchorWallMs + Int64(((t - job.anchorVideo) + job.trim) * 1000) }

        let nFrames = Int((job.duration * Double(job.fpsNum) / Double(job.fpsDen)).rounded())
        progress("Rendering \(nFrames) frames, wall \(WallClock.format(wallAt(job.start))) to \(WallClock.format(wallAt(job.start + job.duration)))")

        if job.codec == .png {
            try FileManager.default.createDirectory(at: job.out, withIntermediateDirectories: true)
            for n in 0..<nFrames {
                if cancelled { throw RenderError.cancelled }
                let t = job.start + Double(n) * Double(job.fpsDen) / Double(job.fpsNum)
                let wall = wallAt(t)
                let img = try frameImage(panel: panel, tl: tl, wall: wall, width: job.width, height: job.height)
                let url = job.out.appendingPathComponent(String(format: "overlay_%06d.png", n))
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw RenderError.writer("png") }
                CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
                if n % 30 == 0 { progress("\(n + 1)/\(nFrames)  \(WallClock.format(wall))") }
            }
            progress("Wrote \(job.out.path)")
            return
        }

        // movie with alpha
        try? FileManager.default.removeItem(at: job.out)
        let writer = try AVAssetWriter(outputURL: job.out, fileType: .mov)
        var settings: [String: Any] = [AVVideoWidthKey: job.width, AVVideoHeightKey: job.height, AVVideoColorPropertiesKey: Renderer.rec709]
        switch job.codec {
        case .prores: settings[AVVideoCodecKey] = AVVideoCodecType.proRes4444
        case .hevc:
            settings[AVVideoCodecKey] = AVVideoCodecType.hevcWithAlpha
            settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.8]
        case .png: break
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: job.width, kCVPixelBufferHeightKey as String: job.height])
        guard writer.canAdd(input) else { throw RenderError.writer("cannot add video input") }
        writer.add(input)
        guard writer.startWriting() else { throw RenderError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        for n in 0..<nFrames {
            if cancelled { writer.cancelWriting(); throw RenderError.cancelled }
            while !input.isReadyForMoreMediaData { usleep(2000) }
            let t = job.start + Double(n) * Double(job.fpsDen) / Double(job.fpsNum)
            let wall = wallAt(t)
            let pb = try makeBuffer(adaptor)
            try drawInto(pb) { ctx in
                ctx.clear(CGRect(x: 0, y: 0, width: job.width, height: job.height))
                self.drawPanel(ctx, panel: panel, tl: tl, wall: wall, width: job.width, height: job.height)
            }
            let pts = CMTime(value: Int64(n) * Int64(job.fpsDen), timescale: job.fpsNum)
            guard adaptor.append(pb, withPresentationTime: pts) else {
                throw RenderError.writer(writer.error?.localizedDescription ?? "append")
            }
            if n % 30 == 0 {
                progress("\(n + 1)/\(nFrames)  \(WallClock.format(wall))")
                onFraction?(Double(n + 1) / Double(nFrames) * (job.burnIn != nil ? 0.5 : 1.0))
            }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw RenderError.writer(writer.error?.localizedDescription ?? "finish") }
        progress("Wrote \(job.out.lastPathComponent)")

        if let video = job.burnIn {
            let out = job.burnOut ?? job.out.deletingPathExtension().appendingPathExtension("preview.mp4")
            try burn(job: job, video: video, out: out, panel: panel, tl: tl, wallAt: wallAt, progress: progress)
        }
    }

    // MARK: burned-in preview
    private func burn(job: RenderJob, video: URL, out: URL, panel: PanelRenderer, tl: Timeline,
                      wallAt: @escaping (Double) -> Int64, progress: @escaping (String) -> Void) throws {
        let asset = AVURLAsset(url: video)
        guard let vtrack = asset.tracks(withMediaType: .video).first else { throw RenderError.noVideoTrack }
        let atrack = asset.tracks(withMediaType: .audio).first
        let reader = try AVAssetReader(asset: asset)
        let range = CMTimeRange(start: CMTime(seconds: job.start, preferredTimescale: 600),
                                duration: CMTime(seconds: job.duration, preferredTimescale: 600))
        reader.timeRange = range
        let vout = AVAssetReaderTrackOutput(track: vtrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vout.alwaysCopiesSampleData = false
        reader.add(vout)
        var aout: AVAssetReaderTrackOutput?
        if let a = atrack { let o = AVAssetReaderTrackOutput(track: a, outputSettings: nil); if reader.canAdd(o) { reader.add(o); aout = o } }

        try? FileManager.default.removeItem(at: out)
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: job.width, AVVideoHeightKey: job.height,
            AVVideoColorPropertiesKey: Renderer.rec709,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]])
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: job.width, kCVPixelBufferHeightKey as String: job.height])
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if aout != nil, let a = atrack, let hint = (a.formatDescriptions as? [CMFormatDescription])?.first {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)   // passthrough
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) { writer.add(i); ain = i } else { NSLog("audio passthrough not possible for this source; preview will be silent") }
        }
        guard reader.startReading() else { throw RenderError.reader(reader.error?.localizedDescription ?? "start") }
        guard writer.startWriting() else { throw RenderError.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: range.start)

        let group = DispatchGroup()
        var failure: Error?
        var frames = 0
        let total = job.duration
        // video: composite each source frame
        group.enter()
        let vq = DispatchQueue(label: "burn.video")
        vin.requestMediaDataWhenReady(on: vq) { [weak self] in
            guard let self = self else { return }
            while vin.isReadyForMoreMediaData {
                if self.cancelled { failure = RenderError.cancelled; vin.markAsFinished(); group.leave(); return }
                guard let sb = vout.copyNextSampleBuffer(), let src = CMSampleBufferGetImageBuffer(sb) else {
                    vin.markAsFinished(); group.leave(); return
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                let t = pts.seconds
                do {
                    let pb = try self.makeBuffer(adaptor)
                    try self.drawInto(pb) { ctx in
                        if let img = Renderer.image(from: src) {
                            ctx.saveGState()
                            ctx.translateBy(x: 0, y: CGFloat(job.height)); ctx.scaleBy(x: 1, y: -1)   // CG images draw y-up
                            ctx.interpolationQuality = .high
                            ctx.draw(img, in: CGRect(x: 0, y: 0, width: job.width, height: job.height))
                            ctx.restoreGState()
                        }
                        self.drawPanel(ctx, panel: panel, tl: tl, wall: wallAt(t), width: job.width, height: job.height)
                    }
                    if !adaptor.append(pb, withPresentationTime: pts) { failure = RenderError.writer(writer.error?.localizedDescription ?? "append") }
                } catch { failure = error }
                if failure != nil { vin.markAsFinished(); group.leave(); return }
                frames += 1
                if frames % 30 == 0 {
                    progress(String(format: "Preview %.0f%%  %@", 100 * (t - job.start) / total, WallClock.format(wallAt(t))))
                    self.onFraction?(0.5 + 0.5 * min(1, (t - job.start) / total))
                }
            }
        }
        if let ain = ain, let aout = aout {
            group.enter()
            let aq = DispatchQueue(label: "burn.audio")
            ain.requestMediaDataWhenReady(on: aq) {
                while ain.isReadyForMoreMediaData {
                    guard let sb = aout.copyNextSampleBuffer() else { ain.markAsFinished(); group.leave(); return }
                    if !ain.append(sb) { ain.markAsFinished(); group.leave(); return }
                }
            }
        }
        group.wait()
        if let f = failure { writer.cancelWriting(); reader.cancelReading(); throw f }
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        if writer.status != .completed { throw RenderError.writer(writer.error?.localizedDescription ?? "finish") }
        progress("Wrote \(out.lastPathComponent)")
    }

    // MARK: pixel helpers
    private func makeBuffer(_ adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw RenderError.writer("no pixel buffer pool") }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        guard let buf = pb else { throw RenderError.writer("pixel buffer") }
        return buf
    }

    /// Run `body` with a y-down CGContext over the buffer's pixels.
    private func drawInto(_ pb: CVPixelBuffer, _ body: (CGContext) -> Void) throws {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw RenderError.writer("context")
        }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)   // y-down like the canvas
        body(ctx)
    }

    private func drawPanel(_ ctx: CGContext, panel: PanelRenderer, tl: Timeline, wall: Int64, width: Int, height: Int) {
        let frame = tl.frameIndex(atMs: wall)
        let key: (Int?, Int64) = (frame, wall / 100)
        if cachedPanel == nil || cachedKey.0 != key.0 || cachedKey.1 != key.1 {
            // render the panel once per telemetry frame into a transparent full-size image
            guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
            panel.draw(in: c, frame: frame, wall: wall)
            cachedPanel = c.makeImage(); cachedKey = key
        }
        if let img = cachedPanel {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            ctx.restoreGState()
        }
    }

    private func frameImage(panel: PanelRenderer, tl: Timeline, wall: Int64, width: Int, height: Int) throws -> CGImage {
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let _ = Optional(c.translateBy(x: 0, y: CGFloat(height))) else { throw RenderError.writer("context") }
        c.scaleBy(x: 1, y: -1)
        panel.draw(in: c, frame: tl.frameIndex(atMs: wall), wall: wall)
        guard let img = c.makeImage() else { throw RenderError.writer("image") }
        return img
    }

    static func image(from pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - command line mode

enum RenderCLI {
    static let usage = """
    Usage: "WWB Overlay" --render --tline FILE [--shw FILE] --start m:ss.s --duration SECONDS --out FILE
           [--anchor-video 4:52.2] [--anchor-wall 18:30:00.0] [--trim 0] [--size 1920x1080] [--fps 29.97]
           [--codec prores|hevc|png] [--scale 1] [--opacity 0.85] [--side right|left] [--show-idle] [--no-history]
           [--burn-in VIDEO [--burn-out FILE.mp4]]
    """

    static func fps(_ s: String) -> (Int32, Int32) {
        switch s {
        case "23.976", "23.98": return (24000, 1001)
        case "29.97": return (30000, 1001)
        case "59.94": return (60000, 1001)
        default:
            if let v = Double(s) { return (Int32((v * 1000).rounded()), 1000) }
            return (30000, 1001)
        }
    }

    static func main(_ argv: [String]) -> Int32 {
        var a: [String: String] = [:]
        var flags = Set<String>()
        var i = 1
        while i < argv.count {
            let k = argv[i]
            if k.hasPrefix("--") {
                if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") { a[k] = argv[i + 1]; i += 2 } else { flags.insert(k); i += 1 }
            } else { i += 1 }
        }
        guard let tline = a["--tline"], let start = a["--start"], let dur = a["--duration"], let out = a["--out"] else {
            FileHandle.standardError.write((usage + "\n").data(using: .utf8)!); return 2
        }
        var job = RenderJob(tlineURL: URL(fileURLWithPath: tline), start: WallClock.parseVideoTime(start) ?? 0,
                            duration: Double(dur) ?? 60, out: URL(fileURLWithPath: out))
        if let s = a["--shw"] { job.shwURL = URL(fileURLWithPath: s) }
        if let v = a["--anchor-video"] { job.anchorVideo = WallClock.parseVideoTime(v) ?? job.anchorVideo }
        if let w = a["--anchor-wall"] { job.anchorWall = w }
        if let t = a["--trim"] { job.trim = Double(t) ?? 0 }
        if let s = a["--size"] { let p = s.lowercased().split(separator: "x"); if p.count == 2, let w = Int(p[0]), let h = Int(p[1]) { job.width = w; job.height = h } }
        if let f = a["--fps"] { (job.fpsNum, job.fpsDen) = fps(f) }
        if let c = a["--codec"], let codec = OverlayCodec(rawValue: c) { job.codec = codec }
        if let s = a["--scale"] { job.options.scale = Double(s) ?? 1 }
        if let o = a["--opacity"] { job.options.opacity = Double(o) ?? 0.85 }
        if let s = a["--side"] { job.options.side = s }
        job.options.showIdle = flags.contains("--show-idle")
        job.options.history = !flags.contains("--no-history")
        if let b = a["--burn-in"] { job.burnIn = URL(fileURLWithPath: b) }
        if let b = a["--burn-out"] { job.burnOut = URL(fileURLWithPath: b) }
        do {
            let t0 = Date()
            try Renderer().run(job) { msg in print(msg) }
            print(String(format: "done in %.1f s", Date().timeIntervalSince(t0)))
            return 0
        } catch {
            FileHandle.standardError.write(("error: \(error.localizedDescription)\n").data(using: .utf8)!)
            return 1
        }
    }
}
