import XCTest
import Defaults
import ImageIO
@testable import Maccy

@MainActor
class HistoryItemDecoratorTests: XCTestCase {
  let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
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

  override func setUp() {
    super.setUp()
    Defaults[.highlightMatch] = .bold
    Defaults[.imageMaxHeight] = 40
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.imageMaxHeight] = savedImageMaxHeight
    Defaults[.highlightMatch] = savedHighlightMatch
  }

  func testString() {
    let title = "foo"
    let itemDecorator = historyItemDecorator(title)
    XCTAssertEqual(itemDecorator.title, title)
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testRTF() {
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    let itemDecorator = historyItemDecorator(rtf, .rtf)
    XCTAssertEqual(itemDecorator.title, "foo")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testHTML() {
    let html = "<a href='#'>foo</a>".data(using: .utf8)
    let itemDecorator = historyItemDecorator(html, .html)
    XCTAssertEqual(itemDecorator.title, "foo")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testImage() async {
    let image = NSImage(named: "StatusBarMenuImage")!
    let itemDecorator = historyItemDecorator(image)
    await itemDecorator.sizeImages()
    XCTAssertEqual(itemDecorator.title, "")
    XCTAssertEqual(itemDecorator.previewImage!.size, image.size)
    XCTAssertEqual(itemDecorator.thumbnailImage!.size, image.size)
  }

  // We also need to add test for image with width bigger than max width.
  func testImageWithHeightBiggerThanMaxHeight() async {
    let image = NSImage(named: "NSApplicationIcon")!
    let itemDecorator = historyItemDecorator(image)
    await itemDecorator.sizeImages()
    XCTAssertEqual(itemDecorator.thumbnailImage!.size, NSSize(width: 40, height: 40))
  }

  func testThumbnailIsReadAndDecodedInTheBackground() async throws {
    let itemDecorator = historyItemDecorator(pngData(width: 2000, height: 1000), .png)
    // Stored images are read through a background context.
    try Storage.shared.context.save()
    XCTAssertTrue(itemDecorator.hasImage)
    let genericLabel = itemDecorator.accessibilityLabel

    itemDecorator.ensureThumbnailImage()
    XCTAssertNil(itemDecorator.thumbnailImage)
    _ = await itemDecorator.thumbnailImageGenerationTask?.result

    let thumbnail = try XCTUnwrap(itemDecorator.thumbnailImage)
    let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
    XCTAssertEqual(thumbnail.size, NSSize(width: 80, height: 40))
    XCTAssertEqual(thumbnail.representations.count, 1)
    XCTAssertEqual(thumbnail.representations.first?.pixelsHigh, Int(40 * scale))
    XCTAssertEqual(itemDecorator.imagePixelSize, NSSize(width: 2000, height: 1000))
    XCTAssertNotEqual(itemDecorator.accessibilityLabel, genericLabel)
    XCTAssertTrue(itemDecorator.accessibilityLabel.contains("2000"))
  }

  func testThumbnailDoesNotRetainOriginal() throws {
    weak var original: NSData?
    var thumbnail: NSImage.Thumbnail?
    autoreleasepool {
      let data = NSData(data: pngData(width: 2000, height: 1000))
      original = data
      let source = CGImageSourceCreateWithData(data as CFData, nil)!
      thumbnail = NSImage.thumbnail(of: source, fitting: NSSize(width: 340, height: 40), scale: 2)
    }

    XCTAssertNil(original)
    let image = try XCTUnwrap(thumbnail?.image)
    XCTAssertEqual(image.size, NSSize(width: 80, height: 40))
    XCTAssertEqual(image.representations.count, 1)
    let representation = try XCTUnwrap(image.representations.first)
    // A drawing handler would draw, and so keep, the full-size image.
    XCTAssertFalse(representation is NSCustomImageRep)
    XCTAssertEqual(representation.pixelsWide, 160)
    XCTAssertEqual(representation.pixelsHigh, 80)
    XCTAssertEqual(thumbnail?.originalPixelSize, NSSize(width: 2000, height: 1000))
  }

  func testThumbnailHasSameSizeAsImage() throws {
    // Retina screenshots are 144 dpi, so they're half as large in points as in pixels.
    let data = pngData(width: 2000, height: 1000, size: NSSize(width: 1000, height: 500))
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
    let thumbnail = try XCTUnwrap(NSImage.thumbnail(of: source, fitting: NSSize(width: 4000, height: 4000), scale: 2))

    XCTAssertEqual(thumbnail.image.size, NSImage(data: data)?.size)
    XCTAssertEqual(thumbnail.image.size, NSSize(width: 1000, height: 500))
    XCTAssertEqual(thumbnail.image.representations.first?.pixelsWide, 2000)
    XCTAssertEqual(thumbnail.originalPixelSize, NSSize(width: 2000, height: 1000))
  }

  func testReleasingLargeImagesKeepsThumbnail() async {
    let itemDecorator = historyItemDecorator(NSImage(named: "NSApplicationIcon")!)
    await itemDecorator.sizeImages()
    XCTAssertNotNil(itemDecorator.previewImage)

    itemDecorator.releaseLargeImages()

    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNotNil(itemDecorator.thumbnailImage)
  }

  func testFile() {
    let url = URL(fileURLWithPath: "/tmp/foo.bar")
    let itemDecorator = historyItemDecorator(url)
    XCTAssertEqual(itemDecorator.title, "file:///tmp/foo.bar")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testFileWithEscapedChars() {
    let url = URL(fileURLWithPath: "/tmp/产品培训/产品培训.txt")
    let itemDecorator = historyItemDecorator(url)
    XCTAssertEqual(itemDecorator.title, "file:///tmp/产品培训/产品培训.txt")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testItemWithoutData() {
    let itemDecorator = historyItemDecorator(nil)
    XCTAssertEqual(itemDecorator.title, "")
    XCTAssertNil(itemDecorator.previewImage)
    XCTAssertNil(itemDecorator.thumbnailImage)
  }

  func testUnpinnedByDefault() {
    let itemDecorator = historyItemDecorator("foo")
    XCTAssertNil(itemDecorator.item.pin)
    XCTAssertFalse(itemDecorator.isPinned)
  }

  func testDeallocatesWhenNoLongerReferenced() {
    weak var weakDecorator: HistoryItemDecorator?

    autoreleasepool {
      let itemDecorator = historyItemDecorator("foo")
      weakDecorator = itemDecorator
      XCTAssertNotNil(weakDecorator)
    }

    XCTAssertNil(weakDecorator)
  }

  func testHighlight() {
    let itemDecorator = historyItemDecorator("foo bar baz")
    itemDecorator.highlight("random", [
      range(from: 1, to: 2, in: itemDecorator),
      range(from: 8, to: 10, in: itemDecorator)
    ])
    var expectedTitle = AttributedString("foo bar baz")
    expectedTitle[expectedTitle.range(of: "oo")!].font = .bold(.body)()
    expectedTitle[expectedTitle.range(of: "baz")!].font = .bold(.body)()
    XCTAssertEqual(itemDecorator.attributedTitle, expectedTitle)
    itemDecorator.highlight("", [])
    XCTAssertEqual(itemDecorator.attributedTitle, nil)
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
        value: value.tiffRepresentation!
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
