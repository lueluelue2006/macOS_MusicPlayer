import Foundation
import CoreAudio

/// Monitors macOS audio output route changes and triggers callbacks
/// for headphone disconnect/connect so the app can pause/resume.
final class AudioRouteMonitor {
    private var onHeadphonesDisconnected: () -> Void
    private var onHeadphonesConnected: () -> Void
    private var onDeviceChanged: (String) -> Void

    private let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var jackAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyJackIsConnected,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var dataSourceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private var currentDefaultDevice: AudioDeviceID = 0

    // Listener blocks must be retained and passed back to the remove API.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var jackListenerBlock: AudioObjectPropertyListenerBlock?
    private var dataSourceListenerBlock: AudioObjectPropertyListenerBlock?

    init(onHeadphonesDisconnected: @escaping () -> Void,
         onHeadphonesConnected: @escaping () -> Void,
         onDeviceChanged: @escaping (String) -> Void) {
        self.onHeadphonesDisconnected = onHeadphonesDisconnected
        self.onHeadphonesConnected = onHeadphonesConnected
        self.onDeviceChanged = onDeviceChanged
        setup()
    }

    deinit {
        teardown()
    }

    private func setup() {
        // Track default output device changes.
        var addr = defaultDeviceAddress
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultDeviceChanged()
        }
        defaultDeviceListenerBlock = defaultBlock
        AudioObjectAddPropertyListenerBlock(systemObjectID, &addr, .main, defaultBlock)

        // Prime current default and start listening to its jack/data source changes.
        currentDefaultDevice = queryDefaultOutputDevice()
        attachDeviceLevelListeners(to: currentDefaultDevice)
        emitCurrentDeviceName()
    }

    private func teardown() {
        var addr = defaultDeviceAddress
        if let block = defaultDeviceListenerBlock {
            AudioObjectRemovePropertyListenerBlock(systemObjectID, &addr, .main, block)
            defaultDeviceListenerBlock = nil
        }
        detachDeviceLevelListeners(from: currentDefaultDevice)
    }

    // MARK: - Default output device
    private func handleDefaultDeviceChanged() {
        let newDevice = queryDefaultOutputDevice()
        if newDevice != currentDefaultDevice {
            let oldDevice = currentDefaultDevice
            // Classify new device and emit connect/disconnect accordingly.
            if isHeadphoneLike(deviceID: newDevice) {
                onHeadphonesConnected()
            } else {
                onHeadphonesDisconnected()
            }
            currentDefaultDevice = newDevice
            emitCurrentDeviceName()

            // Rewire listeners to the new device.
            detachDeviceLevelListeners(from: oldDevice)
            attachDeviceLevelListeners(to: newDevice)
        }
    }

    private func queryDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var addr = defaultDeviceAddress
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &size, &deviceID)
        if status != noErr {
            return 0
        }
        return deviceID
    }

    // MARK: - Device-level listeners
    private func attachDeviceLevelListeners(to deviceID: AudioDeviceID) {
        guard deviceID != 0 else { return }

        // Jack connection change (covers built-in 3.5mm headphones)
        var jack = jackAddress
        if AudioObjectHasProperty(deviceID, &jack) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleJackOrDataSourceChanged(on: deviceID)
            }
            jackListenerBlock = block
            AudioObjectAddPropertyListenerBlock(deviceID, &jack, .main, block)
        } else {
            jackListenerBlock = nil
        }

        // Data source change (Internal Speakers <-> Headphones)
        var ds = dataSourceAddress
        if AudioObjectHasProperty(deviceID, &ds) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleJackOrDataSourceChanged(on: deviceID)
            }
            dataSourceListenerBlock = block
            AudioObjectAddPropertyListenerBlock(deviceID, &ds, .main, block)
        } else {
            dataSourceListenerBlock = nil
        }
    }

    private func detachDeviceLevelListeners(from deviceID: AudioDeviceID) {
        guard deviceID != 0 else { return }
        var jack = jackAddress
        if AudioObjectHasProperty(deviceID, &jack) {
            if let block = jackListenerBlock {
                AudioObjectRemovePropertyListenerBlock(deviceID, &jack, .main, block)
            }
        }
        jackListenerBlock = nil
        var ds = dataSourceAddress
        if AudioObjectHasProperty(deviceID, &ds) {
            if let block = dataSourceListenerBlock {
                AudioObjectRemovePropertyListenerBlock(deviceID, &ds, .main, block)
            }
        }
        dataSourceListenerBlock = nil
    }

    private func handleJackOrDataSourceChanged(on deviceID: AudioDeviceID) {
        // Try jack property first
        var jack = jackAddress
        if AudioObjectHasProperty(deviceID, &jack) {
            var connected: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &jack, 0, nil, &size, &connected) == noErr {
                if connected == 0 { // 0 => disconnected
                    onHeadphonesDisconnected()
                    emitCurrentDeviceName()
                    return
                } else {
                    onHeadphonesConnected()
                    emitCurrentDeviceName()
                    return
                }
            }
        }

        // Fallback to data source name inspection.
        if let name = currentDataSourceName(for: deviceID) {
            let lowered = name.lowercased()
            // If current source looks like internal speakers, treat as unplug.
            if lowered.contains("internal") || lowered.contains("speaker") || lowered.contains("扬声器") || lowered.contains("内置") {
                onHeadphonesDisconnected()
                emitCurrentDeviceName()
            } else if lowered.contains("head") || lowered.contains("耳机") {
                onHeadphonesConnected()
                emitCurrentDeviceName()
            }
        } else {
            // As a conservative fallback, pause on unknown state change.
            onHeadphonesDisconnected()
            emitCurrentDeviceName()
        }
    }

    private func emitCurrentDeviceName() {
        let name = readableOutputName(for: currentDefaultDevice) ?? "未知输出设备"
        onDeviceChanged(name)
    }

    private func readableOutputName(for deviceID: AudioDeviceID) -> String? {
        // Prefer data source name if available (e.g., Headphones/Internal Speakers)
        if let ds = currentDataSourceName(for: deviceID) {
            // Some devices also have a device name (e.g., MacBook Speakers / Display Audio)
            if let dev = deviceName(for: deviceID), dev.lowercased().contains("display") {
                // For displays, include device name to clarify path
                return "\(ds) - \(dev)"
            }
            return ds
        }
        // Fallback to device name
        return deviceName(for: deviceID)
    }

    private func isHeadphoneLike(deviceID: AudioDeviceID) -> Bool {
        // If the device exposes jack and it's connected, it's headphones.
        var jack = jackAddress
        if AudioObjectHasProperty(deviceID, &jack) {
            var connected: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(deviceID, &jack, 0, nil, &size, &connected) == noErr {
                if connected != 0 { return true }
            }
        }
        // Data source heuristic
        if let dsName = currentDataSourceName(for: deviceID)?.lowercased() {
            if dsName.contains("head") || dsName.contains("耳机") { return true }
            if dsName.contains("internal") || dsName.contains("speaker") || dsName.contains("扬声器") || dsName.contains("内置") { return false }
        }
        // Device name heuristic (for Bluetooth/USB headsets)
        if let devName = deviceName(for: deviceID)?.lowercased() {
            let hpKeywords = ["airpods", "beats", "sony", "bose", "head", "buds", "耳机", "耳麦", "蓝牙"]
            let spkKeywords = ["speaker", "扬声器", "display", "hdmi", "airplay"]
            if hpKeywords.contains(where: { devName.contains($0) }) { return true }
            if spkKeywords.contains(where: { devName.contains($0) }) { return false }
        }
        // Unknown: assume not headphone to avoid unintended auto-resume
        return false
    }

    private func currentDataSourceName(for deviceID: AudioDeviceID) -> String? {
        // Read current data source ID
        var dsAddr = dataSourceAddress
        guard AudioObjectHasProperty(deviceID, &dsAddr) else { return nil }
        var dsID: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &dsAddr, 0, nil, &size, &dsID) == noErr else { return nil }

        // Translate ID -> CFString name
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &nameAddr) else { return nil }
        var nameRef: CFString? = nil
        let status = withUnsafeMutablePointer(to: &dsID) { inputPointer in
            withUnsafeMutablePointer(to: &nameRef) { outputPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(inputPointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(outputPointer),
                    mOutputDataSize: UInt32(MemoryLayout<CFString?>.size)
                )
                size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let nameRef else { return nil }
        return nameRef as String
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr) else { return nil }
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &nameRef)
        guard status == noErr, let unmanaged = nameRef else { return nil }
        return unmanaged.takeUnretainedValue() as String
    }
}
