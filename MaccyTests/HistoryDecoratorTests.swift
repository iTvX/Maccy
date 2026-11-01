import AppKit
import Testing
import Defaults
import ImageIO
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryItemDecoratorTests {
    let savedHighlightMatch = Defaults[.highlightMatch]
    let savedImageMaxHeight = Defaults[.imageMaxHeight]

    var firstCopiedAt: Date! {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
      return formatter.date(from: "2020/07/10 12:31:34")
    }

    var lastCopiedAt: Date! {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
      return formatter.date(from: "2020/07/10 12:41:34")
    }

    init() {
      Defaults[.highlightMatch] = .bold
      Defaults[.imageMaxHeight] = 40
    }

    deinit {
      Defaults[.imageMaxHeight] = savedImageMaxHeight
      Defaults[.highlightMatch] = savedHighlightMatch
    }

    @Test("String")
    func string() {
      let title = "foo"
      let itemDecorator = historyItemDecorator(title)
      #expect(itemDecorator.title == title)
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("RTF")
    func rtf() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      let itemDecorator = historyItemDecorator(rtf, .rtf)
      #expect(itemDecorator.title == "foo")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("HTML")
    func html() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      let itemDecorator = historyItemDecorator(html, .html)
      #expect(itemDecorator.title == "foo")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Has rich text")
    func hasRichText() {
      #expect(historyItemDecorator("<a href='#'>foo</a>".data(using: .utf8), .html).hasRichText)
      #expect(!historyItemDecorator("foo").hasRichText)
    }

    @Test("Text follows content changes")
    func textFollowsContentChanges() async throws {
      let itemDecorator = historyItemDecorator("foo")
      #expect(itemDecorator.text == "foo")

      try await confirmation("Text change is observed") { observed in
        withObservationTracking {
          _ = itemDecorator.previewText
        } onChange: {
          observed()
        }
        itemDecorator.item.contents[0].setValue("bar".data(using: .utf8))
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(itemDecorator.text == "bar")
    }

    @Test("Image")
    func image() async throws {
      let image = try #require(NSImage(named: "StatusBarMenuImage"))
      let itemDecorator = historyItemDecorator(image)
      await itemDecorator.sizeImages()
      #expect(itemDecorator.title == "")
      #expect(try #require(itemDecorator.previewImage).size == image.size)
      #expect(try #require(itemDecorator.thumbnailImage).size == image.size)
    }

    // We also need to add test for image with width bigger than max width.
    @Test("Image with height bigger than max height")
    func imageWithHeightBiggerThanMaxHeight() async throws {
      let image = try #require(NSImage(named: "NSApplicationIcon"))
      let itemDecorator = historyItemDecorator(image)
      await itemDecorator.sizeImages()
      #expect(try #require(itemDecorator.thumbnailImage).size == NSSize(width: 40, height: 40))
    }

    @Test("Thumbnail is read and decoded in the background")
    func thumbnailIsReadAndDecodedInTheBackground() async throws {
      let itemDecorator = historyItemDecorator(pngData(width: 2000, height: 1000), .png)
      // Stored images are read through a background context.
      try Storage.shared.context.save()
      #expect(itemDecorator.hasImage)
      let genericLabel = itemDecorator.accessibilityLabel

      itemDecorator.ensureThumbnailImage()
      #expect(itemDecorator.thumbnailImage == nil)
      _ = await itemDecorator.thumbnailImageGenerationTask?.result

      let thumbnail = try #require(itemDecorator.thumbnailImage)
      let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
      #expect(thumbnail.size == NSSize(width: 80, height: 40))
      #expect(thumbnail.representations.count == 1)
      #expect(thumbnail.representations.first?.pixelsHigh == Int(40 * scale))
      #expect(itemDecorator.imagePixelSize == NSSize(width: 2000, height: 1000))
      #expect(itemDecorator.accessibilityLabel != genericLabel)
      #expect(itemDecorator.accessibilityLabel.contains("2000"))
    }

    @Test("Thumbnail does not retain original")
    func thumbnailDoesNotRetainOriginal() throws {
      weak var original: NSData?
      var thumbnail: NSImage.Thumbnail?
      autoreleasepool {
        let data = NSData(data: pngData(width: 2000, height: 1000))
        original = data
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        thumbnail = NSImage.thumbnail(of: source, fitting: NSSize(width: 340, height: 40), scale: 2)
      }

      #expect(original == nil)
      let image = try #require(thumbnail?.image)
      #expect(image.size == NSSize(width: 80, height: 40))
      #expect(image.representations.count == 1)
      let representation = try #require(image.representations.first)
      // A drawing handler would draw, and so keep, the full-size image.
      #expect(!(representation is NSCustomImageRep))
      #expect(representation.pixelsWide == 160)
      #expect(representation.pixelsHigh == 80)
      #expect(thumbnail?.originalPixelSize == NSSize(width: 2000, height: 1000))
    }

    @Test("Thumbnail has same size as image")
    func thumbnailHasSameSizeAsImage() throws {
      // Retina screenshots are 144 dpi, so they're half as large in points as in pixels.
      let data = pngData(width: 2000, height: 1000, size: NSSize(width: 1000, height: 500))
      let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
      let thumbnail = try #require(NSImage.thumbnail(of: source, fitting: NSSize(width: 4000, height: 4000), scale: 2))

      #expect(thumbnail.image.size == NSImage(data: data)?.size)
      #expect(thumbnail.image.size == NSSize(width: 1000, height: 500))
      #expect(thumbnail.image.representations.first?.pixelsWide == 2000)
      #expect(thumbnail.originalPixelSize == NSSize(width: 2000, height: 1000))
    }

    @Test("Releasing large images keeps thumbnail")
    func releasingLargeImagesKeepsThumbnail() async throws {
      let itemDecorator = historyItemDecorator(try #require(NSImage(named: "NSApplicationIcon")))
      await itemDecorator.sizeImages()
      #expect(itemDecorator.previewImage != nil)

      itemDecorator.releaseLargeImages()

      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage != nil)
    }

    @Test("File", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      let itemDecorator = historyItemDecorator(url)
      #expect(itemDecorator.title == "file://\(path)")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Item without data")
    func itemWithoutData() {
      let itemDecorator = historyItemDecorator(nil)
      #expect(itemDecorator.title == "")
      #expect(itemDecorator.previewImage == nil)
      #expect(itemDecorator.thumbnailImage == nil)
    }

    @Test("Unpinned by default")
    func unpinnedByDefault() {
      let itemDecorator = historyItemDecorator("foo")
      #expect(itemDecorator.item.pin == nil)
      #expect(!itemDecorator.isPinned)
    }

    @Test("Deallocates when no longer referenced")
    func deallocatesWhenNoLongerReferenced() {
      weak var weakDecorator: HistoryItemDecorator?

      autoreleasepool {
        let itemDecorator = historyItemDecorator("foo")
        weakDecorator = itemDecorator
        #expect(weakDecorator != nil)
      }

      #expect(weakDecorator == nil)
    }

    @Test("Highlight")
    func highlight() throws {
      let itemDecorator = historyItemDecorator("foo bar baz")
      itemDecorator.highlight("random", [
        range(from: 1, to: 2, in: itemDecorator),
        range(from: 8, to: 10, in: itemDecorator)
      ])
      var expectedTitle = AttributedString("foo bar baz")
      expectedTitle[try #require(expectedTitle.range(of: "oo"))].font = .bold(.body)()
      expectedTitle[try #require(expectedTitle.range(of: "baz"))].font = .bold(.body)()
      #expect(itemDecorator.attributedTitle == expectedTitle)
      itemDecorator.highlight("", [])
      #expect(itemDecorator.attributedTitle == nil)
    }

    private func historyItemDecorator(
      _ value: String?,
      application: String? = "com.apple.finder"
    ) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value?.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = application
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(
      _ value: Data?,
      _ type: NSPasteboard.PasteboardType
    ) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: value
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(_ value: NSImage) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: value.tiffRepresentation
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func historyItemDecorator(_ value: URL) -> HistoryItemDecorator {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: value.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.lastPathComponent.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()
      item.application = "com.apple.finder"
      item.firstCopiedAt = firstCopiedAt
      item.lastCopiedAt = lastCopiedAt
      item.numberOfCopies = 2

      return HistoryItemDecorator(item)
    }

    private func pngData(width: Int, height: Int, size: NSSize? = nil) -> Data {
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )!
      if let size {
        bitmap.size = size
      }
      return bitmap.representation(using: .png, properties: [:])!
    }

    // swiftlint:disable:next identifier_name
    private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
      let startIndex = item.title.startIndex
      let lowerBound = item.title.index(startIndex, offsetBy: from)
      let upperBound = item.title.index(startIndex, offsetBy: to + 1)

      return lowerBound..<upperBound
    }
  }
}
