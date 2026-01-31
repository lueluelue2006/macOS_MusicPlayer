import Foundation

// Test class for format detection logic
class FormatDetectionTest {
    
    static func runTests() {
        print("🧪 Starting Format Detection Tests...")
        print("=" * 50)
        
        // Test cases with expected results
        let testCases: [(String, EditButtonType)] = [
            // Direct edit formats (blue pencil)
            ("test.m4a", .directEdit),
            ("test.mp4", .directEdit),
            ("test.aac", .directEdit),
            ("TEST.M4A", .directEdit), // Test case insensitive
            
            // FFmpeg supported formats (orange pencil)
            ("test.mp3", .ffmpegCommand),
            ("test.flac", .ffmpegCommand),
            ("test.ogg", .ffmpegCommand),
            ("test.wma", .ffmpegCommand),
            ("test.ape", .ffmpegCommand),
            ("test.opus", .ffmpegCommand),
            ("TEST.MP3", .ffmpegCommand), // Test case insensitive
            
            // Limited support formats (gray pencil)
            ("test.wav", .notSupported),
            ("test.aiff", .notSupported),
            ("TEST.WAV", .notSupported), // Test case insensitive
            
            // Unsupported formats (hidden)
            ("test.txt", .hidden),
            ("test.pdf", .hidden),
            ("test.unknown", .hidden),
            ("test", .hidden), // No extension
        ]
        
        var passedTests = 0
        var failedTests = 0
        
        for (filename, expectedType) in testCases {
            let url = URL(fileURLWithPath: "/tmp/\(filename)")
            let actualType = MetadataEditor.getEditButtonType(for: url)
            let canEdit = MetadataEditor.canEditMetadata(for: url)
            let canShowButton = MetadataEditor.canShowEditButton(for: url)
            
            let passed = actualType == expectedType
            if passed {
                passedTests += 1
                print("✅ \(filename): \(actualType) (expected: \(expectedType))")
            } else {
                failedTests += 1
                print("❌ \(filename): \(actualType) (expected: \(expectedType))")
            }
            
            // Additional validation
            print("   - Can edit metadata: \(canEdit)")
            print("   - Can show edit button: \(canShowButton)")
            print("")
        }
        
        print("=" * 50)
        print("🧪 Test Results:")
        print("   ✅ Passed: \(passedTests)")
        print("   ❌ Failed: \(failedTests)")
        print("   📊 Success Rate: \(passedTests)/\(passedTests + failedTests) (\(Int(Double(passedTests) / Double(passedTests + failedTests) * 100))%)")
        
        if failedTests == 0 {
            print("🎉 All tests passed!")
        } else {
            print("⚠️  Some tests failed. Please check the format detection logic.")
        }
    }
    
    // Test specific format detection scenarios
    static func testSpecificScenarios() {
        print("\n🔍 Testing Specific Scenarios...")
        print("=" * 50)
        
        // Test edge cases
        let edgeCases = [
            "/path/to/song.M4A",
            "/path/to/song.Mp3",
            "/path/to/song.FLAC",
            "/path/to/song with spaces.mp3",
            "/path/to/song.with.dots.m4a",
            "/path/to/song_with_underscores.ogg",
            "/path/to/song-with-dashes.wav"
        ]
        
        for path in edgeCases {
            let url = URL(fileURLWithPath: path)
            let buttonType = MetadataEditor.getEditButtonType(for: url)
            let fileExtension = url.pathExtension.lowercased()
            
            print("📁 \(url.lastPathComponent)")
            print("   Extension: '\(fileExtension)'")
            print("   Button Type: \(buttonType)")
            print("   Can Edit: \(MetadataEditor.canEditMetadata(for: url))")
            print("   Can Show Button: \(MetadataEditor.canShowEditButton(for: url))")
            print("")
        }
    }
}

// Extension to repeat strings (for formatting)
extension String {
    static func * (left: String, right: Int) -> String {
        return String(repeating: left, count: right)
    }
}