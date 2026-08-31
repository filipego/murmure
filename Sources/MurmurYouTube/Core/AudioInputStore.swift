import CoreAudio
import Foundation
import MurmurAudioCore
import Observation

final class CoreAudioInputObserver: @unchecked Sendable {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)
    private var listener: AudioObjectPropertyListenerBlock?
    private var isObserving = false

    func start(onChange: @escaping @MainActor @Sendable () -> Void) throws {
        guard !isObserving else { return }

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in onChange() }
        }
        self.listener = listener

        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(
                systemObject,
                &address,
                .main,
                listener
            )
            guard status == noErr else {
                stop()
                throw CoreAudioInputCatalogError.property(selector: selector, status: status)
            }
        }
        isObserving = true
    }

    func stop() {
        guard let listener else { return }
        for selector in [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultInputDevice
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                systemObject,
                &address,
                .main,
                listener
            )
        }
        self.listener = nil
        isObserving = false
    }

    deinit { stop() }
}

@MainActor
@Observable
final class AudioInputStore {
    static let shared = AudioInputStore()

    private(set) var snapshot = AudioInputCatalogSnapshot(
        devices: [],
        defaultDeviceID: nil
    )
    private(set) var errorMessage: String?

    private let catalog: CoreAudioInputCatalog
    private let observer: CoreAudioInputObserver

    init(
        catalog: CoreAudioInputCatalog = CoreAudioInputCatalog(),
        observer: CoreAudioInputObserver = CoreAudioInputObserver()
    ) {
        self.catalog = catalog
        self.observer = observer
        refresh()
        do {
            try observer.start { [weak self] in self?.refresh() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var devices: [AudioInputDevice] { snapshot.devices }

    func resolution(for selection: MicrophoneSelection) -> AudioInputResolution {
        snapshot.resolve(selection)
    }

    func refresh() {
        do {
            snapshot = try catalog.snapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
