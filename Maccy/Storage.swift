import AppKit.NSPasteboard
import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    // Large contents live in external storage next to the database.
    let externalStorage = url.deletingLastPathComponent().appending(path: ".Storage_SUPPORT")
    let externalFiles = FileManager.default.enumerator(at: externalStorage, includingPropertiesForKeys: [.fileSizeKey])?
      .allObjects as? [URL] ?? []
    let size = ([url] + externalFiles)
      .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
      .reduce(0, +)
    guard size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: Int64(size))
  }

  // Migrations of the stored history that run after launch. The history must not
  // be loaded before they finish.
  var migrations: Task<Void, Never>?

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  // Reads `value` through a throwaway context, so the blob isn't kept in memory
  // by the long-lived model for the rest of the session.
  func detachedValue(of content: HistoryItemContent) -> Data? {
    // Unsaved values aren't in the store yet.
    guard content.modelContext != nil, !content.hasChanges else {
      return content.value
    }

    return Self.value(of: content.persistentModelID, in: container)
  }

  nonisolated static func value(of id: PersistentIdentifier, in container: ModelContainer) -> Data? {
    let descriptor = FetchDescriptor<HistoryItemContent>(predicate: #Predicate { $0.persistentModelID == id })
    return try? ModelContext(container).fetch(descriptor).first?.value
  }

  // Contents stored before `value` became external storage stay inline in SQLite
  // and are loaded into memory with their rows. Re-inserting is the only way to
  // move them out: neither enabling external storage nor assigning the same value
  // again does it. Since the old contents are deleted, models of them that another
  // context already loaded become invalid. Each batch is saved on its own, so an
  // interrupted run keeps its progress and the next one picks up where it stopped.
  nonisolated static func externalizeContents(
    in container: ModelContainer,
    batchSize: Int = 10,
    save: (ModelContext) throws -> Void = { try $0.save() }
  ) throws -> Int {
    var count = 0

    while true {
      let batch: Int = try autoreleasepool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var descriptor = FetchDescriptor<HistoryItemContent>(
          predicate: #Predicate { $0.digest == nil && $0.value != nil }
        )
        descriptor.fetchLimit = batchSize

        var batch = 0
        for content in try context.fetch(descriptor) {
          guard let value = content.value else { continue }

          if let item = content.item {
            // Migrating the store to external storage turns NULL values into empty ones.
            // Keep them nil, so an empty RTF or HTML isn't put on the pasteboard when
            // the item is copied back, and so they don't match this fetch again.
            let externalized = HistoryItemContent(type: content.type, value: value.isEmpty ? nil : value)
            context.insert(externalized)
            item.contents.append(externalized)
            context.delete(content)
          } else {
            content.digest = HistoryItemContent.digest(value)
            content.byteCount = value.count
          }
          batch += 1
        }
        guard batch > 0 else {
          return 0
        }

        try save(context)
        return batch
      }

      guard batch > 0 else {
        return count
      }
      count += batch
    }
  }

  // Moving a large history takes seconds, so keep it off the main thread.
  @concurrent
  nonisolated static func externalizeContentsInBackground(in container: ModelContainer) async throws -> Int {
    try externalizeContents(in: container)
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  func removeUnpersistableContents() throws -> Int {
    let contents = try context.fetch(FetchDescriptor<HistoryItemContent>())
    let unwanted = contents.filter {
      !Clipboard.shared.isPersistable(NSPasteboard.PasteboardType($0.type))
    }

    guard !unwanted.isEmpty else {
      return 0
    }

    unwanted.forEach(context.delete)
    context.processPendingChanges()
    try context.save()

    return unwanted.count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}
