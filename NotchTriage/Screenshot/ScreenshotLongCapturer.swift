import AppKit

@MainActor
final class ScreenshotLongCapturer {
    struct Progress { var stitched: CGImage; var step: Int }

    /// How often to sample the selection while the user scrolls.
    var pollDelayNs: UInt64 = 280_000_000
    /// Hard cap on captured frames (safety).
    var maxFrames = 80
    private var task: Task<CGImage, Error>?
    private var finishRequested = false

    func cancel() {
        finishRequested = false
        task?.cancel()
        task = nil
    }

    /// User finished scrolling — stitch what we have and return.
    func requestFinish() {
        finishRequested = true
    }

    func capture(
        region: CGRect,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> CGImage {
        cancel()
        finishRequested = false
        let work = Task { @MainActor in
            try await self.run(region: region, onProgress: onProgress)
        }
        task = work
        defer { task = nil }
        return try await work.value
    }

    private func run(
        region: CGRect,
        onProgress: @escaping @MainActor (Progress) -> Void
    ) async throws -> CGImage {
        var frames: [CGImage] = []
        let first = try await ScreenshotDisplayCapture.captureRegion(region)
        frames.append(first)
        onProgress(Progress(stitched: first, step: 0))

        // Wait for the user to scroll manually. We only sample; never inject scroll events.
        while frames.count < maxFrames {
            try Task.checkCancellation()
            if finishRequested { break }

            try await Task.sleep(nanoseconds: pollDelayNs)
            try Task.checkCancellation()
            if finishRequested { break }

            let shot = try await ScreenshotDisplayCapture.captureRegion(region)
            let overlap = findOverlap(prev: frames[frames.count - 1], curr: shot)
            let newH = shot.height - overlap
            guard newH >= 4 else { continue }

            frames.append(shot)
            onProgress(Progress(stitched: try stitch(frames), step: frames.count - 1))
        }

        try Task.checkCancellation()
        return try stitch(frames)
    }

    func findOverlap(prev: CGImage, curr: CGImage) -> Int {
        let w = min(prev.width, curr.width)
        let h = min(prev.height, curr.height)
        let refH = 32
        let sw = min(w, 256)
        let cx = (w - sw) / 2
        guard h > refH * 4 else { return 0 }
        guard let prevCrop = prev.cropping(to: CGRect(x: cx, y: prev.height - refH, width: sw, height: refH)),
              let refCtx = bitmap(sw, refH) else { return 0 }
        refCtx.draw(prevCrop, in: CGRect(x: 0, y: 0, width: sw, height: refH))
        guard let refData = refCtx.data else { return 0 }
        let refBpr = refCtx.bytesPerRow
        guard let currCrop = curr.cropping(to: CGRect(x: cx, y: 0, width: sw, height: h)),
              let slabCtx = bitmap(sw, h) else { return 0 }
        slabCtx.draw(currCrop, in: CGRect(x: 0, y: 0, width: sw, height: h))
        guard let slabData = slabCtx.data else { return 0 }
        let slabBpr = slabCtx.bytesPerRow
        for y in 1...(h - refH) {
            var ok = true
            outer: for k in 0..<refH {
                let refOff = k * refBpr
                let slabOff = (y + k) * slabBpr
                var col = 0
                while col < sw * 4 {
                    let a = refData.load(fromByteOffset: refOff + col, as: UInt8.self)
                    let b = slabData.load(fromByteOffset: slabOff + col, as: UInt8.self)
                    if abs(Int(a) - Int(b)) > 10 { ok = false; break outer }
                    col += 16
                }
            }
            if ok { return h - y }
        }
        return 0
    }

    private func stitch(_ frames: [CGImage]) throws -> CGImage {
        guard let first = frames.first else { throw ScreenshotCaptureError.captureFailed }
        guard frames.count > 1 else { return first }
        let w = first.width
        var strips: [(CGImage, Int)] = [(first, first.height)]
        for i in 1..<frames.count {
            let overlap = findOverlap(prev: frames[i - 1], curr: frames[i])
            let newH = frames[i].height - overlap
            guard newH > 0,
                  let c = frames[i].cropping(to: CGRect(x: 0, y: overlap, width: w, height: newH))
            else { continue }
            strips.append((c, newH))
        }
        let totalH = strips.reduce(0) { $0 + $1.1 }
        guard let ctx = bitmap(w, totalH) else { throw ScreenshotCaptureError.captureFailed }
        ctx.translateBy(x: 0, y: CGFloat(totalH))
        ctx.scaleBy(x: 1, y: -1)
        var y = 0
        for (img, hh) in strips {
            ctx.draw(img, in: CGRect(x: 0, y: y, width: w, height: hh))
            y += hh
        }
        guard let result = ctx.makeImage() else { throw ScreenshotCaptureError.captureFailed }
        return result
    }

    private func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}
