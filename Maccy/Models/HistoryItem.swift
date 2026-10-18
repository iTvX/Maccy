import AppKit
import Defaults
import ImageIO
import Sauce
import SwiftData
import Vision

@Model
class HistoryItem {
  @MainActor
  static var supportedPins: Set<String> {
    // "a" reserved for select all
    // "q" reserved for quit
    // "v" reserved for paste
    // "w" reserved for close window
    // "z" reserved for undo/redo
    // "," reserved for preferences
    // "`" reserved for cycling through windows
    var keys = Set([
      "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l",
      "m", "n", "o", "p", "r", "s", "t", "u", "x", "y",
      "[", "]", ";", "'", ".", "/", "-", "=", "\\"
    ])

    if let deleteKey = KeyChord.deleteKey,
       let character = Sauce.shared.character(for: Int(deleteKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    if let pinKey = KeyChord.pinKey,
       let character = Sauce.shared.character(for: Int(pinKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }
    if let previewKey = KeyChord.previewKey,
       let character = Sauce.shared.character(for: Int(previewKey.QWERTYKeyCode), modifiers: .cocoa([])) {
      keys.remove(character)
    }

    return keys
  }

  // Letters first, then symbols.
  static func sortedPins(_ pins: some Sequence<String>) -> [String] {
    pins.sorted { lhs, rhs in
      let lhsIsLetter = lhs.first?.isLetter ?? false
      let rhsIsLetter = rhs.first?.isLetter ?? false
      return lhsIsLetter == rhsIsLetter ? lhs < rhs : lhsIsLetter
    }
  }

  @MainActor
  static var availablePins: [String] {
    History.shared.availablePins
  }

  @MainActor
  static func availablePins(in items: [HistoryItem]) -> [String] {
    let assignedPins = Set(items.compactMap(\.pin))
    return Array(supportedPins.subtracting(assignedPins))
  }

  @MainActor
  static var randomAvailablePin: String { availablePins.randomElement() ?? "" }

  private static let transientTypes: [String] = [
    NSPasteboard.PasteboardType.modified.rawValue,
    NSPasteboard.PasteboardType.fromMaccy.rawValue,
    NSPasteboard.PasteboardType.linkPresentationMetadata.rawValue,
    NSPasteboard.PasteboardType.customWebKitPasteboardData.rawValue,
    NSPasteboard.PasteboardType.source.rawValue,
    NSPasteboard.PasteboardType.customChromiumWebData.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceUrl.rawValue,
    NSPasteboard.PasteboardType.chromiumSourceToken.rawValue,
    NSPasteboard.PasteboardType.notesRichText.rawValue
  ]
  private static let imageTypes: [NSPasteboard.PasteboardType] = StorageType.images.types

  var application: String?
  var firstCopiedAt: Date = Date.now
  var lastCopiedAt: Date = Date.now
  var numberOfCopies: Int = 1
  var pin: String?
  var title = ""

  @Relationship(deleteRule: .cascade, inverse: \HistoryItemContent.item)
  var contents: [HistoryItemContent] = []

  @Transient private var cachedDecodedImage: NSImage?
  // OCR started by `generateTitle()` for images.
  @Transient private(set) var titleRecognition: Task<Void, Never>?

  init(contents: [HistoryItemContent] = []) {
    self.firstCopiedAt = firstCopiedAt
    self.lastCopiedAt = lastCopiedAt
    self.contents = contents
  }

  func supersedes(_ item: HistoryItem) -> Bool {
    return item.contents
      .filter { content in
        !Self.transientTypes.contains(content.type)
      }
      .allSatisfy { content in
        contents.contains(where: { $0.type == content.type && $0.hasSameValue(as: content) })
      }
  }

  @MainActor
  func generateTitle() -> String {
    let pasteboardImageData = self.pasteboardImageData
    let universalClipboardImageURL = universalClipboardImage ? fileURLs.first : nil
    guard pasteboardImageData == nil && universalClipboardImageURL == nil else {
      titleRecognition = Task {
        if let recognizedText = await Self.recognizeText(
          imageData: pasteboardImageData,
          fileURL: universalClipboardImageURL
        ), isStored {
          self.title = recognizedText
        }
      }
      return ""
    }

    // 1k characters is trade-off for performance
    var title = previewableText
      .shortened(to: 1_000)
      .removingScalarsUnsafeForTitleLayout()

    if Defaults[.showSpecialSymbols] {
      if let range = title.range(of: "^ +", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      if let range = title.range(of: " +$", options: .regularExpression) {
        title = title.replacingOccurrences(of: " ", with: "·", range: range)
      }
      title = title
        .replacingOccurrences(of: "\n", with: "⏎")
        .replacingOccurrences(of: "\t", with: "⇥")
    } else {
      title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return title
  }

  var previewableText: String {
    if !fileURLs.isEmpty {
      fileURLs
        .compactMap { $0.absoluteString.removingPercentEncoding }
        .joined(separator: "\n")
    } else if let text = text, !text.isEmpty {
      text
    } else if let rtf = rtf, !rtf.string.isEmpty {
      rtf.string
    } else if let html = html, !html.string.isEmpty {
      html.string
    } else {
      title
    }
  }

  var fileURLs: [URL] {
    guard !universalClipboardText else {
      return []
    }

    return allContentData([.fileURL])
      .compactMap { URL(dataRepresentation: $0, relativeTo: nil, isAbsolute: true) }
  }

  var htmlData: Data? { contentData([.html]) }
  var html: NSAttributedString? {
    guard let data = htmlData else {
      return nil
    }

    return NSAttributedString(html: data, documentAttributes: nil)
  }

  // Checks types only, so the image itself isn't loaded.
  var hasImage: Bool {
    imageContent != nil || universalClipboardImage
  }

  // Recorded with the content, so the image isn't loaded to tell its size.
  var imageByteCount: Int? {
    if let byteCount = imageContent?.byteCount {
      return byteCount
    }
    if universalClipboardImage, let url = fileURLs.first {
      return try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    return nil
  }

  @MainActor
  var imageData: Data? {
    var data = pasteboardImageData
    if data == nil, universalClipboardImage, let url = fileURLs.first {
      data = try? Data(contentsOf: url)
    }

    return data
  }

  // Where to read the image from off the main thread, without loading it into this model.
  enum ImageLocation: Sendable {
    case data(Data)
    case content(PersistentIdentifier)
    case file(URL)

    func source(in container: ModelContainer) -> CGImageSource? {
      let options = [kCGImageSourceShouldCache: false] as CFDictionary
      switch self {
      case .data(let data):
        return CGImageSourceCreateWithData(data as CFData, options)
      case .content(let id):
        return Storage.value(of: id, in: container).flatMap { CGImageSourceCreateWithData($0 as CFData, options) }
      case .file(let url):
        return CGImageSourceCreateWithURL(url as CFURL, options)
      }
    }

    func thumbnail(in container: ModelContainer, fitting size: NSSize, scale: CGFloat) -> NSImage.Thumbnail? {
      source(in: container).flatMap { NSImage.thumbnail(of: $0, fitting: size, scale: scale) }
    }
  }

  @MainActor
  var imageLocation: ImageLocation? {
    if let content = imageContent {
      // Unsaved values aren't in the store yet.
      if content.modelContext != nil, !content.hasChanges {
        return .content(content.persistentModelID)
      } else if let value = content.value {
        return .data(value)
      }
    }

    if universalClipboardImage, let url = fileURLs.first {
      return .file(url)
    }

    return nil
  }

  @MainActor
  var image: NSImage? {
    if let img = cachedDecodedImage {
      return img
    }
    guard let data = imageData else {
      return nil
    }

    cachedDecodedImage = NSImage(data: data)
    return cachedDecodedImage
  }

  var rtfData: Data? { contentData([.rtf]) }
  var rtf: NSAttributedString? {
    guard let data = rtfData else {
      return nil
    }

    return NSAttributedString(rtf: data, documentAttributes: nil)
  }

  func clearDecodedImageCache() {
    cachedDecodedImage?.recache()
    cachedDecodedImage = nil
  }

  var text: String? {
    guard let data = contentData([.string]) else {
      return nil
    }

    return String(data: data, encoding: .utf8)
  }

  var modified: Int? {
    guard let data = contentData([.modified]),
          let modified = String(data: data, encoding: .utf8) else {
      return nil
    }

    return Int(modified)
  }

  var fromMaccy: Bool { contentData([.fromMaccy]) != nil }
  var universalClipboard: Bool { contentData([.universalClipboard]) != nil }

  private var universalClipboardImage: Bool { universalClipboard && fileURLs.first?.pathExtension == "jpeg" }
  private var universalClipboardText: Bool {
    universalClipboard && contentData([.html, .tiff, .png, .jpeg, .rtf, .string, .heic]) != nil
  }

  private var imageContent: HistoryItemContent? {
    contents.first { Self.imageTypes.contains(NSPasteboard.PasteboardType($0.type)) }
  }

  @MainActor
  private var pasteboardImageData: Data? {
    imageContent.flatMap(Storage.shared.detachedValue)
  }

  // OCR takes seconds, so the item may have been deleted by the time it finishes.
  // Bulk deletes (clearing the history) leave the item registered in the context,
  // and setting its title there would bring it back on the next fetch.
  @MainActor
  private var isStored: Bool {
    guard let modelContext else {
      return false
    }

    let id = persistentModelID
    let descriptor = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.persistentModelID == id })
    return (try? modelContext.fetchCount(descriptor)) == 1
  }

  private func contentData(_ types: [NSPasteboard.PasteboardType]) -> Data? {
    let content = contents.first(where: { content in
      return types.contains(NSPasteboard.PasteboardType(content.type))
    })

    return content?.value
  }

  private func allContentData(_ types: [NSPasteboard.PasteboardType]) -> [Data] {
    return contents
      .filter { types.contains(NSPasteboard.PasteboardType($0.type)) }
      .compactMap { $0.value }
  }

  /// Runs OCR on the global concurrent executor so the main thread stays free.
  @concurrent
  nonisolated private static func recognizeText(imageData: Data?, fileURL: URL?) async -> String? {
    guard let data = imageData ?? fileURL.flatMap({ try? Data(contentsOf: $0) }) else {
      return nil
    }

    let requestHandler = VNImageRequestHandler(data: data)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
      return nil
    }

    guard let observations = request.results else {
      return nil
    }

    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}
