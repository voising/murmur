import CoreAudio
import Foundation

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceManager {
    private static let selectedUIDKey = "MurmurSelectedInputDeviceUID"

    /// Persisted UID of the user-pinned input device, or nil for "system default".
    static var selectedUID: String? {
        get { UserDefaults.standard.string(forKey: selectedUIDKey) }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: selectedUIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedUIDKey)
            }
        }
    }

    /// Lists every CoreAudio device that exposes input streams.
    static func listInputDevices() -> [AudioInputDevice] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }

        return ids.compactMap { id -> AudioInputDevice? in
            guard hasInputStreams(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal),
                  let name = stringProperty(id, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal) else {
                return nil
            }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    /// Returns the AudioDeviceID matching the persisted UID, or nil if no pin or device unplugged.
    static func resolveSelectedDeviceID() -> AudioDeviceID? {
        guard let uid = selectedUID else { return nil }
        return listInputDevices().first(where: { $0.uid == uid })?.id
    }

    // MARK: - CoreAudio helpers

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf)
        guard status == noErr, let value = cf?.takeRetainedValue() else { return nil }
        return value as String
    }
}
