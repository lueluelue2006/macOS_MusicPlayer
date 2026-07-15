import XCTest
@testable import MusicPlayer

final class FileSignatureTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSignatureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Codable Round-trip

    func testFileSignatureCodableRoundTrip() throws {
        let original = FileSignature(
            pathKey: "/canonical/path/to/file.mp3",
            size: 1024,
            modificationTimeNanoseconds: 1234567890123456789,
            inode: 9876543210,
            fileResourceIdentifier: "resource-id-123",
            volumeIdentifier: "volume-uuid-456"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FileSignature.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.pathKey, original.pathKey)
        XCTAssertEqual(decoded.size, original.size)
        XCTAssertEqual(decoded.modificationTimeNanoseconds, original.modificationTimeNanoseconds)
        XCTAssertEqual(decoded.inode, original.inode)
        XCTAssertEqual(decoded.fileResourceIdentifier, original.fileResourceIdentifier)
        XCTAssertEqual(decoded.volumeIdentifier, original.volumeIdentifier)
    }

    func testFileSignatureCodableWithNilOptionals() throws {
        let original = FileSignature(
            pathKey: "/path/file.mp3",
            size: 512,
            modificationTimeNanoseconds: 1000000000000000000,
            inode: nil,
            fileResourceIdentifier: nil,
            volumeIdentifier: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FileSignature.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.inode)
        XCTAssertNil(decoded.fileResourceIdentifier)
        XCTAssertNil(decoded.volumeIdentifier)
    }

    // MARK: - Signature Capture

    func testCaptureSignatureFromSameFileIsEqual() async throws {
        let fileURL = tempDir.appendingPathComponent("test.txt")
        try "Test content".write(to: fileURL, atomically: true, encoding: .utf8)

        let identity = FileIdentity()
        let sig1 = try await identity.captureSignature(for: fileURL)
        let sig2 = try await identity.captureSignature(for: fileURL)

        XCTAssertEqual(sig1, sig2)
        XCTAssertEqual(sig1.pathKey, sig2.pathKey)
        XCTAssertEqual(sig1.size, sig2.size)
        XCTAssertEqual(sig1.modificationTimeNanoseconds, sig2.modificationTimeNanoseconds)
    }

    func testCaptureSignatureHasNonNegativeSize() async throws {
        let fileURL = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: fileURL)

        let identity = FileIdentity()
        let signature = try await identity.captureSignature(for: fileURL)

        XCTAssertGreaterThanOrEqual(signature.size, 0)
        XCTAssertEqual(signature.size, 0) // Empty file
    }

    // MARK: - Validation

    func testValidateStrictReturnsTrueForUnchangedFile() async throws {
        let fileURL = tempDir.appendingPathComponent("unchanged.txt")
        try "Original content".write(to: fileURL, atomically: true, encoding: .utf8)

        let identity = FileIdentity()
        let signature = try await identity.captureSignature(for: fileURL)

        let isValid = try await identity.validateStrict(signature: signature, against: fileURL)
        XCTAssertTrue(isValid)
    }

    func testValidateStrictReturnsFalseAfterContentChange() async throws {
        let fileURL = tempDir.appendingPathComponent("modified.txt")
        try "Original content".write(to: fileURL, atomically: true, encoding: .utf8)

        let identity = FileIdentity()
        let signature = try await identity.captureSignature(for: fileURL)

        // Modify content (changes size)
        try "Different content with different size".write(to: fileURL, atomically: true, encoding: .utf8)

        let isValid = try await identity.validateStrict(signature: signature, against: fileURL)
        XCTAssertFalse(isValid)
    }

    func testValidateStrictReturnsFalseAfterModificationTimeChange() async throws {
        let fileURL = tempDir.appendingPathComponent("touched.txt")
        let content = "Same content"
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let identity = FileIdentity()
        let originalSignature = try await identity.captureSignature(for: fileURL)
        let originalSize = originalSignature.size
        let originalInode = originalSignature.inode
        let originalResourceId = originalSignature.fileResourceIdentifier

        // Explicitly change modification time using FileManager
        let fm = FileManager.default
        let newModDate = Date(timeIntervalSince1970: Date().timeIntervalSince1970 + 3600) // +1 hour
        try fm.setAttributes([.modificationDate: newModDate], ofItemAtPath: fileURL.path)

        // Verify preconditions
        let newSignature = try await identity.captureSignature(for: fileURL)
        XCTAssertEqual(newSignature.size, originalSize, "Size should not change")
        XCTAssertNotEqual(newSignature.modificationTimeNanoseconds, originalSignature.modificationTimeNanoseconds, "Mtime should have changed")
        if let origInode = originalInode, let newInode = newSignature.inode {
            XCTAssertEqual(newInode, origInode, "Inode should not change when only touching")
        }
        if let origResId = originalResourceId, let newResId = newSignature.fileResourceIdentifier {
            XCTAssertEqual(newResId, origResId, "Resource identifier should not change when only touching")
        }

        // Now validate - should be false due to mtime change
        let isValid = try await identity.validateStrict(signature: originalSignature, against: fileURL)
        XCTAssertFalse(isValid)
    }

    func testValidateReturnsFalseForNonexistentFile() async throws {
        let fileURL = tempDir.appendingPathComponent("exists.txt")
        try "Content".write(to: fileURL, atomically: true, encoding: .utf8)

        let identity = FileIdentity()
        let signature = try await identity.captureSignature(for: fileURL)

        // Delete file
        try FileManager.default.removeItem(at: fileURL)

        let isValid = await identity.validate(signature: signature, against: fileURL)
        XCTAssertFalse(isValid)
    }

    func testValidateStrictThrowsFileNotAccessibleForNonexistentFile() async throws {
        let fileURL = tempDir.appendingPathComponent("exists-then-deleted.txt")
        try "Content".write(to: fileURL, atomically: true, encoding: .utf8)

        let identity = FileIdentity()
        let signature = try await identity.captureSignature(for: fileURL)

        // Delete file
        try FileManager.default.removeItem(at: fileURL)

        do {
            _ = try await identity.validateStrict(signature: signature, against: fileURL)
            XCTFail("Expected validateStrict to throw FileIdentity.Error.fileNotAccessible")
        } catch let error as FileIdentity.Error {
            switch error {
            case .fileNotAccessible:
                break // Expected
            default:
                XCTFail("Expected FileIdentity.Error.fileNotAccessible, got \(error)")
            }
        } catch {
            XCTFail("Expected FileIdentity.Error.fileNotAccessible, got \(error)")
        }
    }

    // MARK: - Error Cases

    func testCaptureSignatureThrowsFileNotAccessibleForNonexistentFile() async throws {
        let nonexistentURL = tempDir.appendingPathComponent("does-not-exist.txt")

        let identity = FileIdentity()

        do {
            _ = try await identity.captureSignature(for: nonexistentURL)
            XCTFail("Expected captureSignature to throw FileIdentity.Error.fileNotAccessible")
        } catch let error as FileIdentity.Error {
            switch error {
            case .fileNotAccessible:
                break // Expected
            default:
                XCTFail("Expected FileIdentity.Error.fileNotAccessible, got \(error)")
            }
        } catch {
            XCTFail("Expected FileIdentity.Error.fileNotAccessible, got \(error)")
        }
    }
}
