import Foundation

enum IPCDebugSettings {
    static let userDefaultsKey = "ipcDebugEnabled"
    private static let lock = NSLock()
    private static var enabled = false

    static func isEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    static func setEnabled(_ enabled: Bool) {
        lock.lock()
        self.enabled = enabled
        lock.unlock()
        NotificationCenter.default.post(
            name: .ipcDebugModeDidChange,
            object: nil,
            userInfo: ["enabled": enabled]
        )
    }

    /// Commits the coherent preference before changing the process-wide IPC
    /// gate. Protected or failed persistence leaves the runtime gate untouched.
    @discardableResult
    static func persistEnabled(
        _ requestedValue: Bool,
        preferencesStore: AppPreferencesStore
    ) -> Result<Bool, AppPreferencesStore.PersistenceError> {
        switch preferencesStore.persistenceState {
        case .writable:
            break
        case .protectedFuture(let version):
            return .failure(.protectedFuture(version: version))
        case .protectedCorrupt:
            return .failure(.corruptEnvelope)
        }

        let previousValue = preferencesStore.load().ipcDebugEnabled
        _ = preferencesStore.update { $0.ipcDebugEnabled = requestedValue }
        switch preferencesStore.persist() {
        case .success:
            let storedValue = preferencesStore.load().ipcDebugEnabled
            setEnabled(storedValue)
            return .success(storedValue)
        case .failure(let error):
            // Keep a failed request out of a later unrelated flush.
            _ = preferencesStore.update { $0.ipcDebugEnabled = previousValue }
            return .failure(error)
        }
    }
}

extension Notification.Name {
    static let appPreferencesPresentationDidChange = Notification.Name(
        "appPreferencesPresentationDidChange"
    )
}
