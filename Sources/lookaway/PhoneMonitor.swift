import CoreBluetooth
import Foundation

/// Watches the Bluetooth signal of the owner's phone.
///
/// An iPhone changes its Bluetooth address every few minutes, but a Mac signed in to the
/// same Apple ID can resolve it, so CoreBluetooth hands out a stable identifier for it
/// (the technique BLEUnlock uses). The phone is heard two ways: from its adverts while
/// scanning, and by connecting to it and reading the signal every two seconds, which also
/// works while it is quiet in a pocket.
@MainActor
final class PhoneMonitor: NSObject, ObservableObject {
    struct Candidate: Identifiable, Equatable {
        let id: UUID
        /// What the device advertises or macOS knows it as; iPhones advertise no name.
        var name: String?
        /// From its Device Information service, e.g. "iPhone18,3"; read from close Apple devices.
        var model: String?
        var isApple: Bool
        var rssi: Int
        /// Smoothed signal, steadier than one advert, for telling phones apart.
        var average: Double
        var lastSeen: Date

        /// For the list: the Bluetooth name and the model together when both are known
        /// ("Alex’s iPhone · iPhone18,3"), else whichever there is.
        var label: String {
            let named = name.flatMap { $0.isEmpty ? nil : $0 }
            switch (named, model) {
            case let (name?, model?): return "\(name) · \(model)"
            case let (name?, nil): return name
            case let (nil, model?): return "\(Self.kind(of: model)) · \(model)"
            case (nil, nil): return isApple ? "Apple device (unnamed)" : "Unnamed device"
            }
        }

        var isNamed: Bool { (name?.isEmpty == false) || model != nil }

        static func kind(of model: String) -> String {
            for (prefix, kind) in [("iPhone", "iPhone"), ("iPad", "iPad"), ("Watch", "Apple Watch"), ("Mac", "Mac"), ("AirPods", "AirPods")]
            where model.hasPrefix(prefix) { return kind }
            return "Apple device"
        }
    }

    /// Devices heard recently, strongest first, while `discovering` is on.
    @Published private(set) var candidates: [Candidate] = []
    /// Bluetooth itself: nil when it is on and allowed, otherwise why not.
    @Published private(set) var problem: String?

    /// Each reading from the paired phone, in dBm.
    var onReading: ((Double) -> Void)?

    /// The paired phone, or nil to stop watching.
    var target: UUID? {
        didSet {
            guard target != oldValue else { return }
            if let peripheral { central?.cancelPeripheralConnection(peripheral) }
            peripheral = nil
            sync()
        }
    }

    /// Fill `candidates` for the pairing list.
    var discovering = false {
        didSet {
            guard discovering != oldValue else { return }
            if !discovering {
                candidates = []
                for p in probing.values where p.identifier != target { central?.cancelPeripheralConnection(p) }
                probing = [:]
                probed = []
            }
            sync()
        }
    }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var scanning = false
    private var rssiTimer: Timer?
    /// Close, unnamed Apple devices connected to just to read their model. Held strongly:
    /// CoreBluetooth drops a connection whose peripheral is released.
    private var probing: [UUID: CBPeripheral] = [:]
    private var probed: Set<UUID> = []
    private var models: [UUID: String] = [:]
    /// GAP device names read during a probe. iOS often answers just "iPhone".
    private var names: [UUID: String] = [:]
    /// Characteristic reads still outstanding per probed device.
    private var pendingReads: [UUID: Int] = [:]

    private static let deviceInfo = CBUUID(string: "180A")
    private static let modelNumber = CBUUID(string: "2A24")
    private static let genericAccess = CBUUID(string: "1800")
    private static let deviceName = CBUUID(string: "2A00")
    /// Only devices this close get probed: the phone is held next to the Mac while pairing.
    private static let probeRSSI = -70
    private static let maxProbes = 3

    /// Created lazily: the first CBCentralManager is what makes macOS ask for Bluetooth
    /// access, and nobody should be asked until they pair a phone.
    private func ensureCentral() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    private func sync() {
        let wanted = target != nil || discovering
        if wanted { ensureCentral() }
        guard let central, central.state == .poweredOn else {
            stopTimer()
            return
        }
        if wanted && !scanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
        } else if !wanted && scanning {
            central.stopScan()
            scanning = false
        }
        if let target, peripheral == nil, let known = central.retrievePeripherals(withIdentifiers: [target]).first {
            attach(known)
        }
        if target == nil { stopTimer() }
    }

    private func attach(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        if p.state == .disconnected { central?.connect(p) }
        if rssiTimer == nil {
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            RunLoop.main.add(t, forMode: .common)
            rssiTimer = t
        }
    }

    private func poll() {
        guard let p = peripheral else { return }
        switch p.state {
        case .connected: p.readRSSI()
        case .disconnected: central?.connect(p)
        default: break
        }
    }

    private func stopTimer() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }

    private func heard(_ p: CBPeripheral, name: String?, isApple: Bool?, rssi: Int) {
        guard rssi < 0 else { return }
        if p.identifier == target {
            if peripheral == nil { attach(p) }
            onReading?(Double(rssi))
        }
        guard discovering else { return }
        let now = Date()
        let known = name ?? p.name ?? names[p.identifier]
        if let i = candidates.firstIndex(where: { $0.id == p.identifier }) {
            candidates[i].rssi = rssi
            candidates[i].average += 0.3 * (Double(rssi) - candidates[i].average)
            if let known { candidates[i].name = known }
            if let isApple { candidates[i].isApple = candidates[i].isApple || isApple }
            candidates[i].model = models[p.identifier]
            candidates[i].lastSeen = now
        } else {
            candidates.append(Candidate(
                id: p.identifier, name: known, model: models[p.identifier],
                isApple: isApple ?? false, rssi: rssi, average: Double(rssi), lastSeen: now
            ))
        }
        if let c = candidates.first(where: { $0.id == p.identifier }), !c.isNamed, c.isApple { probeIfClose(p, rssi: rssi) }
        candidates = candidates
            .filter { now.timeIntervalSince($0.lastSeen) < 30 }
            .sorted { $0.rssi > $1.rssi }
    }

    private func probeIfClose(_ p: CBPeripheral, rssi: Int) {
        let id = p.identifier
        guard rssi >= Self.probeRSSI, !probed.contains(id), probing.count < Self.maxProbes, let central else { return }
        probed.insert(id)
        probing[id] = p
        p.delegate = self
        central.connect(p)
        // A device that never answers must not hold a probe slot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated { self?.endProbe(id) }
        }
    }

    private func endProbe(_ id: UUID) {
        pendingReads[id] = nil
        guard let p = probing.removeValue(forKey: id) else { return }
        if id != target { central?.cancelPeripheralConnection(p) }
    }

    /// One characteristic answered (or failed, with `value` nil); the probe ends after the last.
    private func gotValue(_ value: String?, of characteristic: CBUUID, for p: CBPeripheral) {
        let id = p.identifier
        if let value, !value.isEmpty, let i = candidates.firstIndex(where: { $0.id == id }) {
            if characteristic == Self.modelNumber {
                models[id] = value
                candidates[i].model = value
            } else if characteristic == Self.deviceName {
                names[id] = value
                if candidates[i].name?.isEmpty != false { candidates[i].name = value }
            }
        }
        if let name = p.name, !name.isEmpty, let i = candidates.firstIndex(where: { $0.id == id }), candidates[i].name?.isEmpty != false {
            candidates[i].name = name
        }
        finishRead(id)
    }

    private func finishRead(_ id: UUID) {
        guard let left = pendingReads[id] else { return }
        if left <= 1 { endProbe(id) } else { pendingReads[id] = left - 1 }
    }
}

extension PhoneMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: problem = nil
            case .poweredOff: problem = "Bluetooth is off"
            case .unauthorized: problem = "lookaway is not allowed to use Bluetooth (System Settings › Privacy & Security › Bluetooth)"
            case .unsupported: problem = "This Mac has no Bluetooth LE"
            default: problem = "Bluetooth is not ready"
            }
            if central.state != .poweredOn {
                scanning = false
                peripheral = nil
            }
            sync()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // Apple's Bluetooth company identifier, 0x004C, little-endian at the start.
        let maker = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let isApple = maker.map { $0.count >= 2 && $0[$0.startIndex] == 0x4C && $0[$0.startIndex + 1] == 0x00 } ?? false
        MainActor.assumeIsolated { heard(peripheral, name: name, isApple: isApple, rssi: RSSI.intValue) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            if peripheral.identifier == target { peripheral.readRSSI() }
            if probing[peripheral.identifier] != nil { peripheral.discoverServices([Self.deviceInfo, Self.genericAccess]) }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { endProbe(peripheral.identifier) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        MainActor.assumeIsolated { heard(peripheral, name: nil, isApple: nil, rssi: RSSI.intValue) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            let wanted: [CBUUID: CBUUID] = [Self.deviceInfo: Self.modelNumber, Self.genericAccess: Self.deviceName]
            let services = (peripheral.services ?? []).filter { wanted[$0.uuid] != nil }
            guard !services.isEmpty else {
                endProbe(id)
                return
            }
            pendingReads[id] = services.count
            for service in services { peripheral.discoverCharacteristics([wanted[service.uuid]!], for: service) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let wanted = [Self.modelNumber, Self.deviceName]
            guard let c = service.characteristics?.first(where: { wanted.contains($0.uuid) }) else {
                finishRead(peripheral.identifier)
                return
            }
            peripheral.readValue(for: c)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        let uuid = characteristic.uuid
        MainActor.assumeIsolated { gotValue(error == nil ? value : nil, of: uuid, for: peripheral) }
    }
}
