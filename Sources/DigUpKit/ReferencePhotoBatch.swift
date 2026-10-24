import Foundation

/// Bounds-checked access for the reference picker, whose async task can outlive the selected photo index.
public struct ReferencePhotoBatch: Sendable {
    public let photos: [URL]

    public init(photos: [URL]) { self.photos = photos }

    public func photo(at index: Int) -> URL? {
        guard photos.indices.contains(index) else { return nil }
        return photos[index]
    }

    public func nextIndex(after index: Int) -> Int? {
        guard photos.indices.contains(index), index < photos.count - 1 else { return nil }
        return index + 1
    }
}
