import AudioToolbox
import CoreAudio
import Foundation
import MurmurAudioCore

struct AudioInputCatalogSnapshot: Sendable, Equatable {
    let devices: [AudioInputDevice]
    let defaultDeviceID: String?

    func resolve(_ selection: MicrophoneSelection) -> AudioInputResolution {
        AudioInputResolver.resolve(
            selection,
            devices: devices,
            defaultDeviceID: defaultDeviceID
        )
    }
}

enum CoreAudioInputCatalogError: LocalizedError, Equatable {
    case property(selector: AudioObjectPropertySelector, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .property(selector, status):
            "CoreAudio property \(Self.fourCC(selector)) failed (\(status))."
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(value)"
    }
}

/// CoreAudio adapter. Stable UIDs cross the boundary; ephemeral AudioDeviceIDs do not.
struct CoreAudioInputCatalog: Sendable {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func snapshot() throws -> AudioInputCatalogSnapshot {
        let objectIDs = try deviceObjectIDs()
        let defaultObjectID = try defaultInputObjectID()
        var devices: [AudioInputDevice] = []

        for objectID in objectIDs {
            guard try isAlive(objectID), try inputChannelCount(objectID) > 0,
                  let uid = try stringProperty(
                      objectID,
                      selector: kAudioDevicePropertyDeviceUID
                  ),
                  let name = try stringProperty(
                      objectID,
                      selector: kAudioObjectPropertyName
                  ),
                  !uid.isEmpty,
                  !name.isEmpty else {
                continue
            }

            devices.append(AudioInputDevice(
                id: uid,
                displayName: name,
                transport: try transport(objectID),
                isSystemDefault: objectID == defaultObjectID
            ))
        }

        devices.sort {
            if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        return AudioInputCatalogSnapshot(
            devices: devices,
            defaultDeviceID: devices.first(where: \.isSystemDefault)?.id
        )
    }

    func objectID(for uniqueID: String) throws -> AudioDeviceID? {
        for objectID in try deviceObjectIDs() {
            if try stringProperty(objectID, selector: kAudioDevicePropertyDeviceUID) == uniqueID {
                return objectID
            }
        }
        return nil
    }

    private func deviceObjectIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size),
            selector: address.mSelector
        )

        let count = Int(size) / MemoryLayout<AudioDeviceID>.stride
        var devices = Array(repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        try devices.withUnsafeMutableBytes { bytes in
            try check(
                AudioObjectGetPropertyData(
                    systemObject,
                    &address,
                    0,
                    nil,
                    &size,
                    bytes.baseAddress!
                ),
                selector: address.mSelector
            )
        }
        return devices
    }

    private func defaultInputObjectID() throws -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        try check(
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device),
            selector: address.mSelector
        )
        return device == kAudioObjectUnknown ? nil : device
    }

    private func inputChannelCount(_ objectID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            selector: address.mSelector
        )
        guard size >= MemoryLayout<AudioBufferList>.size else { return 0 }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }

        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, storage),
            selector: address.mSelector
        )
        let list = storage.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private func isAlive(_ objectID: AudioDeviceID) throws -> Bool {
        try uint32Property(objectID, selector: kAudioDevicePropertyDeviceIsAlive) != 0
    }

    private func transport(_ objectID: AudioDeviceID) throws -> AudioInputTransport {
        switch try uint32Property(objectID, selector: kAudioDevicePropertyTransportType) {
        case kAudioDeviceTransportTypeBuiltIn:
            .builtIn
        case kAudioDeviceTransportTypeUSB:
            .usb
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            .bluetooth
        case kAudioDeviceTransportTypeThunderbolt:
            .thunderbolt
        case kAudioDeviceTransportTypeAggregate:
            .aggregate
        case kAudioDeviceTransportTypeVirtual:
            .virtual
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless:
            .continuity
        default:
            .other
        }
    }

    private func uint32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            selector: selector
        )
        return value
    }

    private func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nil,
                    &size,
                    UnsafeMutableRawPointer(pointer)
                ),
                selector: selector
            )
        }
        return value?.takeRetainedValue() as String?
    }

    private func check(
        _ status: OSStatus,
        selector: AudioObjectPropertySelector
    ) throws {
        guard status == noErr else {
            throw CoreAudioInputCatalogError.property(selector: selector, status: status)
        }
    }
}
