import CryptoKit
import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  // Stored outside of SQLite so that reading `type` doesn't load the blob into memory.
  @Attribute(.externalStorage)
  var value: Data?
  // Let duplicate detection and the preview compare and size contents without
  // loading `value`. SwiftData doesn't fire `didSet`, so change `value` with `setValue`.
  var digest: Data?
  var byteCount: Int?

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil) {
    self.type = type
    self.value = value
    self.digest = value.map(Self.digest)
    self.byteCount = value?.count
  }

  func setValue(_ value: Data?) {
    self.value = value
    digest = value.map(Self.digest)
    byteCount = value?.count
  }

  static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  func hasSameValue(as other: HistoryItemContent) -> Bool {
    switch (digest, other.digest) {
    case let (digest?, otherDigest?):
      return digest == otherDigest
    // Contents without a digest are either empty or not externalized yet,
    // so their value is already in memory and hashing it is cheap.
    case let (digest?, nil):
      return other.value.map(Self.digest) == digest
    case let (nil, otherDigest?):
      return value.map(Self.digest) == otherDigest
    case (nil, nil):
      return value == other.value
    }
  }
}
