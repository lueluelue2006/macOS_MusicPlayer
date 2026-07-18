import Foundation

/// A zero-copy numbered view over a random-access track collection.
///
/// The row number is presentation-only; identity remains the track's stable
/// path-based ID so filtering, sorting, and deletion do not reattach row state
/// to a different song.
struct NumberedTracks<Base: RandomAccessCollection>: RandomAccessCollection
where Base.Element == AudioFile {
  struct Element: Identifiable {
    let number: Int
    let file: AudioFile

    var id: String { file.id }
  }

  typealias Index = Base.Index

  let base: Base

  var startIndex: Index { base.startIndex }
  var endIndex: Index { base.endIndex }

  func index(after index: Index) -> Index {
    base.index(after: index)
  }

  func index(before index: Index) -> Index {
    base.index(before: index)
  }

  subscript(position: Index) -> Element {
    Element(
      number: base.distance(from: base.startIndex, to: position) + 1,
      file: base[position]
    )
  }
}

extension RandomAccessCollection where Element == AudioFile {
  var numberedTracks: NumberedTracks<Self> {
    NumberedTracks(base: self)
  }
}
