import AppKit
import Testing
import Defaults
import SwiftData
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class HistoryTests { // swiftlint:disable:this type_body_length
    let savedSize = Defaults[.size]
    let savedSortBy = Defaults[.sortBy]
    let savedPinOrder = Defaults[.pinOrder]
    let savedPinTo = Defaults[.pinTo]
    let history = History.shared

    init() {
      History.shared.clearAll()
      Defaults[.size] = 10
      Defaults[.sortBy] = .firstCopiedAt
      Defaults[.pinOrder] = PinOrder()
      Defaults[.pinTo] = .bottom
    }

    deinit {
      Defaults[.size] = savedSize
      Defaults[.sortBy] = savedSortBy
      Defaults[.pinOrder] = savedPinOrder
      Defaults[.pinTo] = savedPinTo
    }

    @Test("Default is empty")
    func defaultIsEmpty() {
      #expect(history.items.toArray() == [])
    }

    @Test("Adding")
    func adding() {
      let first = history.add(historyItem("foo"))
      let second = history.add(historyItem("bar"))
      #expect(history.items.toArray() == [second, first])
    }

    @Test("Adding persisted duplicate")
    func addingPersistedDuplicate() throws {
      let first = historyItem("foo")
      first.title = "xyz"
      first.application = "iTerm.app"
      history.add(first)
      first.pin = "f"

      let third = historyItem("foo")
      third.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.add(third)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.title == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding unsaved duplicate")
    @available(macOS 15.0, *)
    func addingUnsavedDuplicate() throws {
      let first = historyItem("foo")
      first.title = "xyz"
      first.application = "iTerm.app"
      history.add(first)
      first.pin = "f"

      let second = historyItem("foo", persisted: false)
      second.application = "Xcode.app"
      let transferredContents = first.contents
      let merged = history.add(second)

      #expect(history.items.toArray() == [merged])
      #expect(Set(merged.item.contents) == Set(transferredContents))
      #expect(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
      #expect(merged.item.numberOfCopies == 2)
      #expect(merged.item.pin == "f")
      #expect(merged.item.title == "xyz")
      #expect(merged.item.application == "iTerm.app")
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Adding item that is superseded by existing")
    func addingItemThatIsSupersededByExisting() throws {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.rtf.rawValue,
          value: "two".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.application = "Maccy.app"
      firstItem.contents = firstContents
      firstItem.title = firstItem.generateTitle()
      history.add(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.application = "Maccy.app"
      secondItem.contents = secondContents
      secondItem.title = secondItem.generateTitle()
      let second = history.add(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
      try assertStorageCounts(items: 1, contents: firstContents.count)
    }

    @Test("Adding item with different modified type")
    func addingItemWithDifferentModifiedType() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "1".data(using: .utf8)!
        )
      ]
      let firstItem = HistoryItem()
      Storage.shared.context.insert(firstItem)
      firstItem.contents = firstContents
      history.add(firstItem)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)!
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.modified.rawValue,
          value: "2".data(using: .utf8)!
        )
      ]
      let secondItem = HistoryItem()
      Storage.shared.context.insert(secondItem)
      secondItem.contents = secondContents
      let second = history.add(secondItem)

      #expect(history.items.toArray() == [second])
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Adding item from Maccy")
    func addingItemFromMaccy() {
      let firstContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        )
      ]
      let first = HistoryItem()
      Storage.shared.context.insert(first)
      first.application = "Xcode.app"
      first.contents = firstContents
      history.add(first)

      let secondContents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: "one".data(using: .utf8)
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
          value: "".data(using: .utf8)
        )
      ]
      let second = HistoryItem()
      Storage.shared.context.insert(second)
      second.application = "Maccy.app"
      second.contents = secondContents
      let secondDecorator = history.add(second)

      #expect(history.items.toArray() == [secondDecorator])
      #expect(history.items[0].item.application == "Xcode.app")
      #expect(Set(history.items[0].item.contents) == Set(firstContents))
    }

    @Test("Modified after copying")
    func modifiedAfterCopying() {
      history.add(historyItem("foo"))

      let modifiedItem = historyItem("bar")
      modifiedItem.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: String(Clipboard.shared.changeCount).data(using: .utf8)
      ))
      let modifiedItemDecorator = history.add(modifiedItem)

      #expect(history.items.toArray() == [modifiedItemDecorator])
      #expect(history.items[0].text == "bar")
    }

    @Test("Clearing unpinned")
    func clearingUnpinned() throws {
      let pinned = history.add(historyItem("foo"))
      history.togglePin(pinned)
      history.add(historyItem("bar"))
      let orphan = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      )
      Storage.shared.context.insert(orphan)
      try Storage.shared.context.save()

      history.clear()

      #expect(history.items.toArray() == [pinned])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Clearing all")
    func clearingAll() throws {
      history.add(historyItem("foo"))
      let pinned = history.add(historyItem("bar"))
      history.togglePin(pinned)
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "orphan".data(using: .utf8)
      ))
      try Storage.shared.context.save()

      history.clearAll()

      #expect(history.items.toArray() == [])
      try assertStorageCounts(items: 0, contents: 0)
    }

    @Test("Recognized text becomes title")
    func recognizedTextBecomesTitle() async {
      let item = imageItem("Maccy")
      history.add(item)

      await item.titleRecognition?.value

      #expect(item.title == "Maccy")
    }

    @Test("Deleting during text recognition")
    func deletingDuringTextRecognition() async throws {
      let item = history.add(imageItem("Maccy"))
      let recognition = item.item.titleRecognition
      history.delete(item)

      try await assertTextRecognitionKeepsDeleted(recognition)
    }

    @Test("Clearing during text recognition")
    func clearingDuringTextRecognition() async throws {
      let item = history.add(imageItem("Maccy"))
      let recognition = item.item.titleRecognition
      history.clear()

      try await assertTextRecognitionKeepsDeleted(recognition)
    }

    @Test("Clearing all during text recognition")
    func clearingAllDuringTextRecognition() async throws {
      let item = history.add(imageItem("Maccy"))
      history.togglePin(item)
      let recognition = item.item.titleRecognition
      history.clearAll()

      try await assertTextRecognitionKeepsDeleted(recognition)
    }

    @Test("Max size")
    func maxSize() throws {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.add(historyItem(String(index))))
      }

      #expect(history.items.count == 10)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[0]))
      try assertStorageCounts(items: 10, contents: 10)
    }

    @Test("Max size ignores pinned")
    func maxSizeIgnoresPinned() {
      var items: [HistoryItemDecorator] = []

      let item = history.add(historyItem("0"))
      items.append(item)
      history.togglePin(item)

      for index in 1...11 {
        items.append(history.add(historyItem(String(index))))
      }

      #expect(history.items.count == 11)
      #expect(history.items.contains(items[10]))
      #expect(history.items.contains(items[0]))
      #expect(!history.items.contains(items[1]))
    }

    @Test("Pinning updates pin order")
    func pinningUpdatesPinOrder() {
      let item = history.add(historyItem("foo"))
      history.togglePin(item)

      #expect(history.pinnedItems == [item])
      #expect(Defaults[.pinOrder].pins == [item.item.pin].compactMap { $0 })
    }

    @Test("Pins without a free key get no shortcuts")
    func noShortcutsForPinWithoutKey() {
      #expect(KeyShortcut.create(character: "").isEmpty)
      #expect(KeyShortcut.create(character: "b").count == 3)
    }

    @Test("Pinning after all shortcuts are assigned")
    func pinningAfterAllShortcutsAreAssigned() async throws {
      let supportedPins = HistoryItem.supportedPins
      for index in 0..<supportedPins.count {
        let item = history.add(historyItem("keyed \(index)"))
        history.togglePin(item)
      }

      #expect(history.availablePins.isEmpty)
      #expect(Set(history.pinnedItems.compactMap(\.item.pin)) == supportedPins)

      let first = history.add(historyItem("first without shortcut"))
      history.togglePin(first)
      let second = history.add(historyItem("second without shortcut"))
      history.togglePin(second)

      #expect(first.item.pin == "")
      #expect(second.item.pin == "")
      #expect(history.pinnedItems.suffix(2) == [first, second])
      #expect(history.unpinnedItems.isEmpty)

      for index in 0...Defaults[.size] {
        history.add(historyItem("unpinned \(index)"))
      }

      let expectedCount = supportedPins.count + 2
      #expect(history.pinnedItems.count == expectedCount)
      try assertStorageCounts(
        items: expectedCount + Defaults[.size],
        contents: expectedCount + Defaults[.size]
      )

      try await history.load()
      #expect(history.pinnedItems.count == expectedCount)
      #expect(
        Set(history.pinnedItems.filter { $0.item.pin == "" }.map(\.title)) ==
        ["first without shortcut", "second without shortcut"]
      )
    }

    @Test("Unpinning updates pin order")
    func unpinningUpdatesPinOrder() {
      let item = history.add(historyItem("foo"))
      history.togglePin(item)
      history.togglePin(item)

      #expect(history.pinnedItems == [])
      #expect(Defaults[.pinOrder].pins == [])
    }

    @Test("Moving pins updates pin order")
    func movingPinsUpdatesPinOrder() {
      let first = history.add(historyItem("foo"))
      let second = history.add(historyItem("bar"))
      history.togglePin(first)
      history.togglePin(second)

      history.movePin(from: IndexSet(integer: 0), to: 2)

      #expect(history.pinnedItems == [second, first])
      #expect(Defaults[.pinOrder].pins == [second.item.pin, first.item.pin].compactMap { $0 })
    }

    @Test("Max size is changed")
    func maxSizeIsChanged() {
      var items: [HistoryItemDecorator] = []
      for index in 0...10 {
        items.append(history.add(historyItem(String(index))))
      }
      Defaults[.size] = 5
      history.add(historyItem("11"))

      #expect(history.items.count == 5)
      #expect(history.items.contains(items[10]))
      #expect(!history.items.contains(items[5]))
    }

    @Test("Re-adding bottom-most pinned item at full capacity")
    func readdingBottomMostPinnedItemAtFullCapacity() {
      // Regression test for a crash when re-copying (invoking) the bottom-most
      // pinned item while history is at full capacity and pins are sorted to the
      // bottom. The stale insert index used to trap with an out-of-bounds insert.
      // Issue link: https://github.com/p0deje/Maccy/issues/1466
      // `pinTo` is restored to its default value(.top) in `deinit`.
      Defaults[.pinTo] = .bottom

      // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
      // pinned item ends up as the last element.
      let pinned = history.add(historyItem("pinned"))
      history.togglePin(pinned)

      // Fill unpinned history to full capacity.
      for index in 0..<Defaults[.size] {
        history.add(historyItem(String(index)))
      }

      #expect(history.items.last == pinned)

      // Re-copy the pinned item. It is detected as a duplicate, removed and
      // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
      // Before the fix this inserted at a stale, out-of-bounds index and crashed.
      let readded = history.add(historyItem("pinned"))

      #expect(history.items.contains(readded))
      #expect(history.items.filter(\.isPinned).count == 1)
    }

    @Test("Removing")
    func removing() throws {
      let foo = history.add(historyItem("foo"))
      let bar = history.add(historyItem("bar"))
      history.delete(foo)
      #expect(history.items.toArray() == [bar])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Cleaning up orphaned contents")
    func cleaningUpOrphanedContents() throws {
      let live = history.add(historyItem("live"))
      let liveContent = live.item.contents[0]
      for value in ["orphan-1", "orphan-2"] {
        Storage.shared.context.insert(HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        ))
      }
      try Storage.shared.context.save()

      #expect(try Storage.shared.cleanupOrphanedContents() == 2)
      #expect(try Storage.shared.cleanupOrphanedContents() == 0)
      #expect(live.item.contents == [liveContent])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Removing unpersistable contents")
    func removingUnpersistableContents() throws {
      let live = history.add(historyItem("live"))
      live.item.contents.append(HistoryItemContent(
        type: NSPasteboard.PasteboardType.safariWebArchve.rawValue,
        value: Data(repeating: 0x61, count: 1024)
      ))
      try Storage.shared.context.save()

      #expect(try Storage.shared.removeUnpersistableContents() == 1)
      #expect(try Storage.shared.removeUnpersistableContents() == 0)
      #expect(live.item.contents.map(\.type) == [NSPasteboard.PasteboardType.string.rawValue])
      try assertStorageCounts(items: 1, contents: 1)
    }

    @Test("Externalizing contents")
    func externalizingContents() throws {
      let stringType = NSPasteboard.PasteboardType.string.rawValue
      let htmlType = NSPasteboard.PasteboardType.html.rawValue
      let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
      try insertLegacyItem([
        stringType: Data("legacy".utf8),
        htmlType: Data("<b>legacy</b>".utf8),
        rtfType: nil
      ])
      try insertLegacyItem([stringType: Data("orphan".utf8)], orphaned: true)
      #expect(try legacyContentsCount() == 3)

      #expect(try Storage.externalizeContents(in: Storage.shared.container, batchSize: 2) == 3)
      #expect(try legacyContentsCount() == 0)
      #expect(try Storage.externalizeContents(in: Storage.shared.container, batchSize: 2) == 0)

      // Read back through a fresh context, like `History.load()` after launch.
      let context = ModelContext(Storage.shared.container)
      let item = try #require(context.fetch(FetchDescriptor<HistoryItem>()).first)
      let contents = Dictionary(uniqueKeysWithValues: item.contents.map { ($0.type, $0) })
      #expect(Set(contents.keys) == [stringType, htmlType, rtfType])
      #expect(contents[stringType]?.value == Data("legacy".utf8))
      #expect(contents[stringType]?.digest == HistoryItemContent.digest(Data("legacy".utf8)))
      #expect(contents[stringType]?.byteCount == 6)
      #expect(contents[htmlType]?.value == Data("<b>legacy</b>".utf8))
      #expect(contents[htmlType]?.digest == HistoryItemContent.digest(Data("<b>legacy</b>".utf8)))
      #expect(contents[rtfType]?.value == nil)
      #expect(contents[rtfType]?.digest == nil)
      #expect(contents[rtfType]?.byteCount == nil)
      let orphan = try #require(context.fetch(FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.item == nil }
      )).first)
      #expect(orphan.digest == HistoryItemContent.digest(Data("orphan".utf8)))
      #expect(orphan.byteCount == 6)
      #expect(item.supersedes(historyItem("legacy", persisted: false)))
      try assertStorageCounts(items: 1, contents: 4, orphaned: 1)
    }

    // Migrating an SQLite store to external storage reads NULL values back as empty data.
    @Test("Externalizing contents keeps missing values nil")
    func externalizingContentsKeepsMissingValuesNil() throws {
      let stringType = NSPasteboard.PasteboardType.string.rawValue
      let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
      try insertLegacyItem([
        stringType: Data("legacy".utf8),
        rtfType: Data()
      ])
      #expect(try legacyContentsCount() == 2)

      #expect(try Storage.externalizeContents(in: Storage.shared.container) == 2)
      #expect(try Storage.externalizeContents(in: Storage.shared.container) == 0)

      let context = ModelContext(Storage.shared.container)
      let item = try #require(context.fetch(FetchDescriptor<HistoryItem>()).first)
      let contents = Dictionary(uniqueKeysWithValues: item.contents.map { ($0.type, $0) })
      #expect(contents[stringType]?.value == Data("legacy".utf8))
      #expect(contents[rtfType] != nil)
      #expect(contents[rtfType]?.value == nil)
      #expect(contents[rtfType]?.digest == nil)
      #expect(contents[rtfType]?.byteCount == nil)
      try assertStorageCounts(items: 1, contents: 2)
    }

    @Test("Externalizing contents is retried after failure")
    func externalizingContentsIsRetriedAfterFailure() async throws {
      let key = "test-externalize-history-item-contents"
      Defaults[.migrations][key] = nil
      defer { Defaults[.migrations][key] = nil }
      for value in ["foo", "bar", "baz"] {
        try insertLegacyItem([NSPasteboard.PasteboardType.string.rawValue: Data(value.utf8)])
      }

      let saves = Counter()
      let failed = AppDelegate.ensureAsyncMigration(key: key) {
        _ = try Storage.externalizeContents(in: Storage.shared.container, batchSize: 1) { context in
          saves.count += 1
          if saves.count == 2 {
            throw CocoaError(.fileWriteUnknown)
          }
          try context.save()
        }
      }
      await failed?.value

      #expect(saves.count == 2)
      #expect(Defaults[.migrations][key] == nil)
      // The batch saved before the failure is kept.
      #expect(try legacyContentsCount() == 2)

      let retried = AppDelegate.ensureAsyncMigration(key: key) {
        _ = try await Storage.externalizeContentsInBackground(in: Storage.shared.container)
      }
      await retried?.value

      #expect(Defaults[.migrations][key] == true)
      #expect(try legacyContentsCount() == 0)
      let completed = AppDelegate.ensureAsyncMigration(key: key) {
        Issue.record("A completed migration must not run again")
      }
      #expect(completed == nil)
      try assertStorageCounts(items: 3, contents: 3)
    }

    private final class Counter {
      var count = 0
    }

    // Stores an item the way older versions did: without digests, and through
    // another context, as the main one doesn't load anything before migrating.
    private func insertLegacyItem(_ values: [String: Data?], orphaned: Bool = false) throws {
      let context = ModelContext(Storage.shared.container)
      let contents = values.map { type, value in
        let content = HistoryItemContent(type: type, value: value)
        content.digest = nil
        content.byteCount = nil
        return content
      }
      if orphaned {
        contents.forEach(context.insert)
      } else {
        let item = HistoryItem()
        context.insert(item)
        item.contents = contents
        item.title = item.generateTitle()
      }
      try context.save()
    }

    private func legacyContentsCount() throws -> Int {
      try ModelContext(Storage.shared.container).fetchCount(FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.digest == nil && $0.value != nil }
      ))
    }

    private func assertStorageCounts(
      items: Int,
      contents: Int,
      orphaned: Int = 0,
      fileID: String = #fileID,
      filePath: String = #filePath,
      line: Int = #line,
      column: Int = #column
    ) throws {
      let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
      let context = Storage.shared.context
      context.processPendingChanges()
      try context.save()
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItem>()) == items,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>()) == contents,
        sourceLocation: sourceLocation
      )
      #expect(
        try context.fetchCount(FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.item == nil }
        )) == orphaned,
        sourceLocation: sourceLocation
      )
    }

    // OCR finishes after the item was deleted. Writing its title would bring the
    // item back into the context, and `load()` would return it again.
    private func assertTextRecognitionKeepsDeleted(
      _ recognition: Task<Void, Never>?,
      fileID: String = #fileID,
      filePath: String = #filePath,
      line: Int = #line,
      column: Int = #column
    ) async throws {
      let sourceLocation = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
      let recognition = try #require(recognition, sourceLocation: sourceLocation)
      await recognition.value
      #expect(!Storage.shared.context.hasChanges, sourceLocation: sourceLocation)

      try await history.load()

      #expect(history.items.toArray() == [], sourceLocation: sourceLocation)
      try assertStorageCounts(items: 0, contents: 0, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    private func imageItem(_ text: String) -> HistoryItem {
      let image = NSImage(size: NSSize(width: 400, height: 120), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        NSString(string: text).draw(
          at: NSPoint(x: 40, y: 30),
          withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        )
        return true
      }
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: image.tiffRepresentation
        )
      ]
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: String, persisted: Bool = true) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      if persisted {
        Storage.shared.context.insert(item)
      }
      item.contents = contents
      item.numberOfCopies = 1
      item.title = item.generateTitle()

      return item
    }
  }
}
