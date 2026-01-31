import Foundation
import CoreAudio
import AudioToolbox

// 简化版MP3元数据编辑器
class SimpleMP3MetadataEditor {
    
    // 读取MP3文件的基本信息（使用系统API）
    static func canReadBasicInfo(for url: URL) -> Bool {
        return url.pathExtension.lowercased() == "mp3"
    }
    
    // 尝试使用AudioFile API读取基本信息
    static func readBasicMetadata(from url: URL) -> (title: String?, artist: String?, album: String?)? {
        guard url.pathExtension.lowercased() == "mp3" else { return nil }
        
        var audioFile: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile)
        
        guard status == noErr, let file = audioFile else {
            return nil
        }
        
        defer {
            AudioFileClose(file)
        }
        
        // 读取基本元数据（这个方法对MP3支持有限）
        var title: String?
        var artist: String?
        var album: String?
        
        // 尝试读取字典格式的信息字典
        var infoSize: UInt32 = 0
        var isWritable: UInt32 = 0
        
        let infoStatus = AudioFileGetPropertyInfo(file, kAudioFilePropertyInfoDictionary, &infoSize, &isWritable)
        
        if infoStatus == noErr && infoSize > 0 {
            var infoDictionary: Unmanaged<CFDictionary>?
            let getStatus = AudioFileGetProperty(file, kAudioFilePropertyInfoDictionary, &infoSize, &infoDictionary)
            
            if getStatus == noErr, let unmanaged = infoDictionary {
                let dict = unmanaged.takeUnretainedValue() as NSDictionary
                title = dict["title"] as? String
                artist = dict["artist"] as? String
                album = dict["album"] as? String
            }
        }
        
        return (title: title, artist: artist, album: album)
    }
    
    // 注意：真正的MP3写入需要第三方库
    // 这里我们提供一个提示性的方法
    static func writeMetadata(to url: URL, title: String, artist: String, album: String) throws {
        throw MP3Error.editingNotSupported("MP3元数据编辑需要额外的第三方库支持。\n当前版本暂不支持MP3文件的元数据修改。\n请考虑将MP3文件转换为M4A格式后再编辑。")
    }
}

enum MP3Error: LocalizedError {
    case editingNotSupported(String)
    
    var errorDescription: String? {
        switch self {
        case .editingNotSupported(let message):
            return message
        }
    }
}
