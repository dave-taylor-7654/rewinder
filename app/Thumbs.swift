// Rewinder — scrub thumbnails.
//
// Full frames are ~2560px WebP: decoding one takes long enough that dragging
// the scrubber faster than a few frames per second leaves the viewer showing a
// stale image. So every frame also gets a small JPEG proxy that the timeline
// paints while the user is moving, swapping in the real frame once they stop.
//
// Proxies are a derived cache, kept next to the index rather than with the
// history: <REWINDER_HOME>/thumbs.noindex/YYYY-MM-DD/HHMMSS.jpg. Big HFS+
// volumes (the usual home for a frame archive) allocate in 128 KB blocks, so
// a 7 KB thumb parked there would cost 128 KB — 18x its own size, and more
// slack per year than the frames themselves. The internal APFS disk stores
// them for what they weigh. They're sealed with the frame key all the same:
// a plaintext cache would undo at-rest encryption.

import CoreGraphics
import Foundation
import ImageIO

let THUMB_ROOT = REWINDER_HOME + "/thumbs.noindex"
let THUMB_MAX = 320        // long edge, px — 320x200 on a 16:10 display
let THUMB_QUALITY = 0.5

func thumbDayDir(_ day: String) -> String { THUMB_ROOT + "/" + day }
func thumbPath(_ day: String, _ stem: String) -> String { thumbDayDir(day) + "/" + stem + ".jpg" }

// Decodes a frame (already decrypted) and re-encodes it small. ImageIO reads
// WebP on macOS 11+, so this covers both the WebP and JPEG fallback frames.
func renderThumb(_ frame: Data) -> Data? {
    guard let src = CGImageSourceCreateWithData(frame as CFData,
              [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true,
                                 kCGImageSourceThumbnailMaxPixelSize: THUMB_MAX]
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, img,
        [kCGImageDestinationLossyCompressionQuality: THUMB_QUALITY] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

private func writeThumb(_ jpeg: Data, day: String, stem: String) {
    let dir = thumbDayDir(day)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let body = (loadRawConfig()["encrypt"] as? Bool ?? true) ? encryptFrameData(jpeg) : jpeg
    let tmp = dir + "/." + stem + ".tmp"
    guard (try? body.write(to: URL(fileURLWithPath: tmp))) != nil else { return }
    do { try FileManager.default.moveItem(atPath: tmp, toPath: thumbPath(day, stem)) }
    catch { try? FileManager.default.removeItem(atPath: tmp) }
}

// Cached thumb for one frame, rendering (and caching) it on first ask.
// `name` is the frame's file name; nil means the frame itself is missing.
func thumbFor(day: String, name: String) -> Data? {
    guard let stem = shotStem(name) else { return nil }
    let fm = FileManager.default
    if let cached = fm.contents(atPath: thumbPath(day, stem)) { return decryptFrameData(cached) }
    for root in searchRoots() {
        guard let raw = fm.contents(atPath: root + "/" + day + "/" + name) else { continue }
        guard let jpeg = renderThumb(decryptFrameData(raw)) else { return nil }
        writeThumb(jpeg, day: day, stem: stem)
        return jpeg
    }
    return nil
}

// Capture-side entry point: proxy straight from the frame image in memory.
func storeThumb(_ image: CGImage, day: String, stem: String) {
    guard let jpeg = renderThumb(image) else { return }
    writeThumb(jpeg, day: day, stem: stem)
}

// CGImage overload — skips the decode round-trip when the frame is still in hand.
func renderThumb(_ image: CGImage) -> Data? {
    let small = downscale(image, maxDim: CGFloat(THUMB_MAX))
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, small,
        [kCGImageDestinationLossyCompressionQuality: THUMB_QUALITY] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

func removeThumb(day: String, stem: String) {
    try? FileManager.default.removeItem(atPath: thumbPath(day, stem))
    let dir = thumbDayDir(day)
    if let left = try? FileManager.default.contentsOfDirectory(atPath: dir), left.isEmpty {
        try? FileManager.default.removeItem(atPath: dir)
    }
}

// Background sweep so a day that was captured before this feature (or while
// the app was an older build) scrubs smoothly the first time it's opened,
// rather than rendering proxies under the user's finger. Newest day first —
// that's where scrubbing starts — and paced so it stays off the viewer's back.
func thumbBackfill() {
    let fm = FileManager.default
    var made = 0
    for root in searchRoots() {
        guard let days = try? fm.contentsOfDirectory(atPath: root) else { continue }
        for day in days.sorted(by: >) where isDayName(day) {
            guard let names = try? fm.contentsOfDirectory(atPath: root + "/" + day) else { continue }
            for name in names.sorted() {
                guard let stem = shotStem(name) else { continue }
                if fm.fileExists(atPath: thumbPath(day, stem)) { continue }
                guard let raw = fm.contents(atPath: root + "/" + day + "/" + name),
                      let jpeg = renderThumb(decryptFrameData(raw)) else { continue }
                writeThumb(jpeg, day: day, stem: stem)
                made += 1
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
    }
    if made > 0 { slog("built \(made) scrub thumbnails") }
}
