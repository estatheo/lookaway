import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio

/// The video that plays in the middle of the main display when someone touches the
/// keyboard or mouse while input is blocked: `blocked.mp4` (or `.mov`, `.m4v`) from
/// lookaway's Application Support folder when there is one, else the app's own
/// `default-blocked.mp4`.
///
/// While it plays the system output is unmuted and set to 40%; when it ends, or the cover
/// comes down, the volume and mute go back to what they were. Input during a play does not
/// restart it.
@MainActor
final class InputVideo {
    static let playVolume: Float32 = 0.4

    private var window: NSWindow?
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var savedVolume: SystemVolume.Snapshot?

    var isPlaying: Bool { player != nil }

    static var file: URL? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("lookaway")
        return ["blocked.mp4", "blocked.mov", "blocked.m4v"]
            .map { folder.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            ?? Bundle.main.url(forResource: "default-blocked", withExtension: "mp4")
    }

    func play() {
        guard !isPlaying, let file = Self.file, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        player.volume = 1
        self.player = player

        // Half the screen's width, 16:9; the layer letterboxes anything else on clear.
        let width = screen.frame.width * 0.5
        let height = width * 9 / 16
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2, width: width, height: height)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        // One above the cover's shielding windows, so it shows over the full cover too.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.orderFrontRegardless()
        self.window = window

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }

        savedVolume = SystemVolume.snapshot()
        SystemVolume.set(Self.playVolume, unmute: true)
        player.play()
    }

    func stop() {
        guard let player else { return }
        player.pause()
        self.player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        window?.orderOut(nil)
        window = nil
        if let savedVolume { SystemVolume.restore(savedVolume) }
        savedVolume = nil
    }
}

/// The default output device's volume and mute, through CoreAudio.
enum SystemVolume {
    struct Snapshot {
        let device: AudioDeviceID
        let volume: Float32?
        let muted: UInt32?
    }

    private static func address(_ selector: AudioObjectPropertySelector, output: Bool) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice, output: false)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    private static func get<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID, as _: T.Type, zero: T) -> T? {
        var addr = address(selector, output: true)
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func put<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID, _ value: T) {
        var addr = address(selector, output: true)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        var value = value
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &value)
    }

    static func snapshot() -> Snapshot? {
        guard let device = defaultOutput() else { return nil }
        return Snapshot(
            device: device,
            volume: get(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: device, as: Float32.self, zero: 0),
            muted: get(kAudioDevicePropertyMute, of: device, as: UInt32.self, zero: 0)
        )
    }

    static func set(_ volume: Float32, unmute: Bool) {
        guard let device = defaultOutput() else { return }
        if unmute { put(kAudioDevicePropertyMute, of: device, UInt32(0)) }
        put(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: device, volume)
    }

    /// Back to the snapshot, on the device it was taken from even if the default changed.
    static func restore(_ snapshot: Snapshot) {
        if let volume = snapshot.volume {
            put(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, of: snapshot.device, volume)
        }
        if let muted = snapshot.muted { put(kAudioDevicePropertyMute, of: snapshot.device, muted) }
    }
}
