import AppKit.NSImage
import ImageIO

extension NSImage {
  struct Thumbnail: Sendable {
    let image: NSImage
    // Lets the size be shown without decoding the original image.
    let originalPixelSize: NSSize
  }

  // Decodes a copy of the image that fits `maxSize` (in points) with enough pixels for
  // `scale`, without decoding the full-size image first. Unlike drawing an NSImage into
  // a smaller one, it can run off the main thread and doesn't keep the original alive.
  nonisolated static func thumbnail(of source: CGImageSource, fitting maxSize: NSSize, scale: CGFloat) -> Thumbnail? {
    let properties = (0..<CGImageSourceGetCount(source)).map { index in
      CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    }
    func property(_ key: CFString, at index: Int = 0) -> Double? {
      (properties[index][key] as? NSNumber)?.doubleValue
    }

    guard !properties.isEmpty,
          let pixelWidth = property(kCGImagePropertyPixelWidth),
          let pixelHeight = property(kCGImagePropertyPixelHeight),
          pixelWidth > 0, pixelHeight > 0 else {
      return nil
    }

    // Same size as NSImage(data:) gives the image: its first image at its resolution.
    var size = NSSize(
      width: pixelWidth * 72 / (property(kCGImagePropertyDPIWidth) ?? 72),
      height: pixelHeight * 72 / (property(kCGImagePropertyDPIHeight) ?? 72)
    )
    var originalPixelSize = NSSize(width: pixelWidth, height: pixelHeight)
    // EXIF orientations 5-8 are rotated by 90°.
    if let orientation = property(kCGImagePropertyOrientation), (5...8).contains(orientation) {
      size = NSSize(width: size.height, height: size.width)
      originalPixelSize = NSSize(width: pixelHeight, height: pixelWidth)
    }

    // Don't size up.
    let ratio = min(maxSize.width / size.width, maxSize.height / size.height, 1)
    let thumbnailSize = NSSize(width: size.width * ratio, height: size.height * ratio)

    // TIFFs can hold several resolutions of the same image (e.g. 1x and 2x), so use the largest.
    let index = properties.indices
      .filter { index in
        guard let width = property(kCGImagePropertyPixelWidth, at: index),
              let height = property(kCGImagePropertyPixelHeight, at: index), height > 0 else {
          return false
        }
        return abs(width / height - pixelWidth / pixelHeight) < 0.01
      }
      .max { (property(kCGImagePropertyPixelWidth, at: $0) ?? 0) < (property(kCGImagePropertyPixelWidth, at: $1) ?? 0) }
      ?? 0

    let maxPixelSize = (max(thumbnailSize.width, thumbnailSize.height) * scale).rounded(.up)
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      // Decode now rather than when the image is first drawn on the main thread.
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize))
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
      return nil
    }

    return Thumbnail(image: NSImage(cgImage: image, size: thumbnailSize), originalPixelSize: originalPixelSize)
  }
}
