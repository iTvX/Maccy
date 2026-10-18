import AppKit.NSWorkspace
import Defaults
import Foundation
import Observation
import Sauce
import SwiftData

@Observable
class HistoryItemDecorator: Identifiable, Hashable, HasVisibility {
  private static let previewMaxParagraphSize = 10_000

  static func == (lhs: HistoryItemDecorator, rhs: HistoryItemDecorator) -> Bool {
    return lhs.id == rhs.id
  }

  static var previewImageSize: NSSize { NSScreen.forPopup?.visibleFrame.size ?? NSSize(width: 2048, height: 1536) }
  static var thumbnailImageSize: NSSize { NSSize(width: 340, height: Defaults[.imageMaxHeight]) }

  let id = UUID()

  var title: String = ""
  var attributedTitle: AttributedString?

  var isVisible: Bool = true
  var selectionIndex: Int = -1
  var isSelected: Bool {
    return selectionIndex != -1
  }
  var shortcuts: [KeyShortcut] = []

  var application: String? {
    if item.universalClipboard {
      return "iCloud"
    }

    guard let bundle = item.application,
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    else {
      return nil
    }

    return url.deletingPathExtension().lastPathComponent
  }

  var hasImage: Bool { item.hasImage }
  var hasFileURLs: Bool { !item.fileURLs.isEmpty }
  var hasPlainText: Bool { item.text != nil }
  var hasRichText: Bool { item.rtf != nil || item.html != nil }

  var previewImageGenerationTask: Task<(), Error>?
  var thumbnailImageGenerationTask: Task<(), Error>?
  var previewImage: NSImage?
  private(set) var previewText = SizedString("")
  var thumbnailImage: NSImage?
  // Known once a thumbnail or preview is generated.
  private(set) var imagePixelSize: NSSize?
  var applicationImage: ApplicationImage

  var imageSize: String? {
    item.imageByteCount.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
  }

  // 10k characters seems to be more than enough on large displays
  var text: String { previewText.string.shortened(to: 10_000) }

  var isPinned: Bool { item.pin != nil }
  var isUnpinned: Bool { item.pin == nil }

  func hash(into hasher: inout Hasher) {
    // We need to hash title and attributedTitle, so SwiftUI knows it needs to update the view if they chage
    hasher.combine(id)
    hasher.combine(title)
    hasher.combine(attributedTitle)
  }

  private(set) var item: HistoryItem

  var multiSelectionIndex: Int? {
    guard selectionIndex >= 0, AppState.shared.navigator.isMultiSelectInProgress else {
      return nil
    }
    return selectionIndex
  }

  // Describe the complete item independently of its potentially truncated visual content.
  var accessibilityLabel: String {
    var parts: [String] = []
    // Decoding the image here would keep it in memory for every rendered row,
    // even while the popup is hidden.
    if hasImage, let size = imagePixelSize {
      parts.append(
        String(
          format: NSLocalizedString("history_item_image_accessibility_label_no_app", comment: ""),
          Int(size.width),
          Int(size.height)
        )
      )
    } else if hasImage {
      parts.append(NSLocalizedString("history_item_image_accessibility_generic", comment: ""))
    } else {
      parts.append(title)
    }
    if let application = application {
      parts.append(application)
    }
    if isPinned {
      parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
    }
    if let index = multiSelectionIndex {
      parts.append(
        String(
          format: NSLocalizedString("history_item_selected_accessibility_value", comment: ""),
          index + 1,
          AppState.shared.navigator.selection.count
        )
      )
    }
    return parts.joined(separator: ", ")
  }

  init(_ item: HistoryItem, shortcuts: [KeyShortcut] = []) {
    self.item = item
    self.shortcuts = shortcuts
    self.title = item.title
    self.applicationImage = ApplicationImageCache.shared.getImage(item: item)

    synchronizeItemPin()
    synchronizeItemTitle()
    synchronizeItemText()
  }

  @MainActor
  func ensureThumbnailImage() {
    guard thumbnailImage == nil else {
      return
    }
    guard thumbnailImageGenerationTask == nil else {
      return
    }
    guard let location = item.imageLocation else {
      return
    }
    let container = Storage.shared.container
    let size = HistoryItemDecorator.thumbnailImageSize
    let scale = Self.backingScaleFactor
    thumbnailImageGenerationTask = Task { [weak self] in
      let thumbnail = await Self.thumbnailDecoder.thumbnail(location, in: container, fitting: size, scale: scale)
      guard let thumbnail else {
        return
      }
      try Task.checkCancellation()
      self?.imagePixelSize = thumbnail.originalPixelSize
      self?.thumbnailImage = thumbnail.image
    }
  }

  @MainActor
  func ensurePreviewImage() {
    guard previewImage == nil else {
      return
    }
    guard previewImageGenerationTask == nil else {
      return
    }
    guard let location = item.imageLocation else {
      return
    }
    let container = Storage.shared.container
    let size = HistoryItemDecorator.previewImageSize
    let scale = Self.backingScaleFactor
    previewImageGenerationTask = Task { [weak self] in
      // Not queued behind thumbnails, since only one preview is shown at a time.
      guard let preview = await Self.decode(location, in: container, fitting: size, scale: scale) else {
        return
      }
      try Task.checkCancellation()
      self?.imagePixelSize = preview.originalPixelSize
      self?.previewImage = preview.image
    }
  }

  @MainActor
  func asyncGetPreviewImage() async -> NSImage? {
    if let image = previewImage {
      return image
    }
    ensurePreviewImage()
    _ = await previewImageGenerationTask?.result
    return previewImage
  }

  @MainActor
  func cleanupImages() {
    thumbnailImageGenerationTask?.cancel()
    previewImageGenerationTask?.cancel()
    thumbnailImageGenerationTask = nil
    previewImageGenerationTask = nil
    thumbnailImage = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  // Only the thumbnail is needed while the popup is closed.
  @MainActor
  func releaseLargeImages() {
    previewImageGenerationTask?.cancel()
    previewImageGenerationTask = nil
    previewImage = nil
    item.clearDecodedImageCache()
  }

  @MainActor
  func sizeImages() async {
    ensurePreviewImage()
    ensureThumbnailImage()
    _ = await previewImageGenerationTask?.result
    _ = await thumbnailImageGenerationTask?.result
  }

  // Images are read and decoded off the main thread, which only gets the small result.
  private static let thumbnailDecoder = ThumbnailDecoder()

  @MainActor
  private static var backingScaleFactor: CGFloat {
    NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
  }

  @concurrent
  nonisolated private static func decode(
    _ location: HistoryItem.ImageLocation,
    in container: ModelContainer,
    fitting size: NSSize,
    scale: CGFloat
  ) async -> NSImage.Thumbnail? {
    location.thumbnail(in: container, fitting: size, scale: scale)
  }

  func highlight(_ query: String, _ ranges: [Range<String.Index>]) {
    guard !query.isEmpty, !title.isEmpty else {
      attributedTitle = nil
      return
    }

    var attributedString = AttributedString(title.shortened(to: 500))
    for range in ranges {
      if let lowerBound = AttributedString.Index(range.lowerBound, within: attributedString),
         let upperBound = AttributedString.Index(range.upperBound, within: attributedString) {
        switch Defaults[.highlightMatch] {
        case .bold:
          attributedString[lowerBound..<upperBound].font = .bold(.body)()
        case .italic:
          attributedString[lowerBound..<upperBound].font = .italic(.body)()
        case .underline:
          attributedString[lowerBound..<upperBound].underlineStyle = .single
        default:
          attributedString[lowerBound..<upperBound].backgroundColor = .findHighlightColor
          attributedString[lowerBound..<upperBound].foregroundColor = .black
        }
      }
    }

    attributedTitle = attributedString
  }

  private func synchronizeItemPin() {
    _ = withObservationTracking {
      item.pin
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if let pin = self.item.pin {
          self.shortcuts = KeyShortcut.create(character: pin)
        }
        // History assigns numeric shortcuts when unpinning. Preserve them when
        // this observation callback runs after the history has been updated.
        self.synchronizeItemPin()
      }
    }
  }

  private func synchronizeItemTitle() {
    _ = withObservationTracking {
      item.title
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        self.title = self.item.title
        self.synchronizeItemTitle()
      }
    }
  }

  private func synchronizeItemText() {
    previewText = withObservationTracking {
      SizedString(item.previewableText, maxParagraphBytes: Self.previewMaxParagraphSize)
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        self?.synchronizeItemText()
      }
    }
  }
}

// Decodes thumbnails one at a time. Every concurrent ImageIO decode leaves about 10 MB
// in the allocator afterwards, so decoding a screen of screenshots in parallel would
// add ~100 MB to the footprint.
private actor ThumbnailDecoder {
  func thumbnail(
    _ location: HistoryItem.ImageLocation,
    in container: ModelContainer,
    fitting size: NSSize,
    scale: CGFloat
  ) -> NSImage.Thumbnail? {
    location.thumbnail(in: container, fitting: size, scale: scale)
  }
}
