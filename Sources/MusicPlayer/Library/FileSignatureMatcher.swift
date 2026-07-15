import Foundation

/// Pure matcher for FileSignature identity comparison.
/// No I/O, no disk scanning, no filesystem access—only value-based logic.
enum FileSignatureMatcher {

    // MARK: - Result Types

    enum MatchResult: Equatable, Sendable {
        case matched
        case rejected
    }

    enum BatchMatchResult: Equatable, Sendable {
        case matched(FileSignature)
        case ambiguous
        case none
    }

    // MARK: - Single Match

    /// Compare original signature against a candidate.
    /// Returns `.matched` only if strong identity criteria are satisfied.
    static func match(original: FileSignature, candidate: FileSignature) -> MatchResult {
        // Tier 1: Strong identity via fileResourceIdentifier + volumeIdentifier
        let originalResourceId = usableIdentifier(original.fileResourceIdentifier)
        let candidateResourceId = usableIdentifier(candidate.fileResourceIdentifier)
        let originalVolumeId = usableIdentifier(original.volumeIdentifier)
        let candidateVolumeId = usableIdentifier(candidate.volumeIdentifier)

        let bothHaveResourceId = originalResourceId != nil && candidateResourceId != nil
        let bothLackResourceId = originalResourceId == nil && candidateResourceId == nil

        // If either side has a resource ID, both must have it and match exactly
        if !bothLackResourceId {
            guard bothHaveResourceId else {
                // One has resourceId, one doesn't → reject (no downgrade/upgrade)
                return .rejected
            }

            // Both have resourceId: must match exactly
            guard originalResourceId == candidateResourceId else {
                return .rejected
            }

            // Resource IDs match; now require both volumeIds usable and matching
            guard let origVol = originalVolumeId,
                  let candVol = candidateVolumeId,
                  origVol == candVol else {
                return .rejected
            }

            // Strong identity confirmed
            return .matched
        }

        // Tier 2: Inode fallback (only when both lack resourceId)
        // Requires: inode, volumeId, size, mtime all present and matching
        guard let origInode = original.inode,
              let candInode = candidate.inode,
              origInode == candInode else {
            return .rejected
        }

        guard let origVol = originalVolumeId,
              let candVol = candidateVolumeId,
              origVol == candVol else {
            return .rejected
        }

        guard original.size == candidate.size else {
            return .rejected
        }

        guard original.modificationTimeNanoseconds == candidate.modificationTimeNanoseconds else {
            return .rejected
        }

        // Inode fallback match confirmed
        return .matched
    }

    // MARK: - Batch Match

    /// Find best match among candidates.
    /// Returns `.matched(signature)` if exactly one candidate matches.
    /// Returns `.ambiguous` if multiple candidates match.
    /// Returns `.none` if no candidates match.
    static func matchBest(original: FileSignature, candidates: [FileSignature]) -> BatchMatchResult {
        let matches = candidates.filter { candidate in
            match(original: original, candidate: candidate) == .matched
        }

        switch matches.count {
        case 0:
            return .none
        case 1:
            return .matched(matches[0])
        default:
            return .ambiguous
        }
    }

    // MARK: - Private Helpers

    /// Returns the identifier string if non-nil and non-blank, otherwise nil.
    /// Trimming is used only to test for usability; the original value is returned for comparison.
    private static func usableIdentifier(_ identifier: String?) -> String? {
        guard let identifier = identifier else {
            return nil
        }
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return identifier // Return original, not trimmed
    }
}
