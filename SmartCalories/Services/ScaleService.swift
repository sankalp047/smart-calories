import Foundation
import CoreBluetooth
import Observation

/// Live connection to a Bluetooth kitchen scale.
///
/// Kitchen scales rarely implement the standard Weight Scale profile — most use
/// a vendor characteristic with an undocumented payload. Rather than hard-code
/// one vendor, this service subscribes to every notifying characteristic it
/// finds, logs raw frames, and hands them to a *calibrated* decoder. That's what
/// makes the app work with scales it has never seen.
@MainActor
@Observable
final class ScaleService: NSObject {

    enum State: Equatable {
        case poweredOff, idle, scanning, connecting, connected, disconnected

        var label: String {
            switch self {
            case .poweredOff: "Bluetooth off"
            case .idle: "Not connected"
            case .scanning: "Searching…"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .disconnected: "Disconnected"
            }
        }
    }

    struct Discovered: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    /// A raw notification payload, kept for the calibration screen.
    struct Frame: Identifiable {
        let id = UUID()
        let characteristic: String
        let bytes: [UInt8]
        let time: Date
        var hex: String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
    }

    // MARK: - Observable state

    private(set) var state: State = .idle
    private(set) var discovered: [Discovered] = []
    private(set) var connectedName: String?
    private(set) var reading: ScaleReading?
    private(set) var frames: [Frame] = []
    private(set) var lastError: String?

    var config = ScaleDecoderConfig.esn00

    /// Smoothed, non-negative grams for the live weigh UI.
    var grams: Double { max(0, reading?.grams ?? 0) }
    var isConnected: Bool { state == .connected }
    var latestFrame: [UInt8]? { frames.first?.bytes }

    // MARK: - Private

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var autoConnectId: UUID?
    private var didAttemptAutoConnect = false
    private let frameLimit = 120

    override init() {
        super.init()
    }

    /// Bring up CoreBluetooth. Deferred until the user actually opens a
    /// scale-related screen so the system permission prompt has context.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func loadSavedConfig() {
        if let saved = Store.load(ScaleDecoderConfig.self, key: Store.Key.scaleConfig) {
            config = saved
        }
        if let idString = Store.load(String.self, key: Store.Key.lastScaleId) {
            autoConnectId = UUID(uuidString: idString)
        }
    }

    func save(config newConfig: ScaleDecoderConfig) {
        config = newConfig
        Store.save(newConfig, key: Store.Key.scaleConfig)
        // Re-decode the most recent frame so the UI reflects the change at once.
        if let bytes = latestFrame {
            reading = ScaleDecoder.decode(bytes, config: newConfig)
        }
    }

    // MARK: - Scanning / connection

    func startScan() {
        activate()
        guard let central, central.state == .poweredOn else { return }
        lastError = nil
        discovered.removeAll()
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        // Scales advertise continuously; a bounded scan keeps the radio sane.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.state == .scanning else { return }
            self.stopScan()
        }
    }

    func stopScan() {
        central?.stopScan()
        if state == .scanning { state = discovered.isEmpty ? .idle : .idle }
    }

    func connect(_ device: Discovered) {
        guard let central,
              let target = central.retrievePeripherals(withIdentifiers: [device.id]).first
        else { return }
        stopScan()
        state = .connecting
        connectedName = device.name
        peripheral = target
        target.delegate = self
        central.connect(target)
        Store.save(device.id.uuidString, key: Store.Key.lastScaleId)
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        reading = nil
        state = .disconnected
    }

    func clearFrames() { frames.removeAll() }

    /// Reconnect to the last-used scale without any user interaction.
    private func attemptAutoConnect() {
        guard !didAttemptAutoConnect,
              let central,
              let id = autoConnectId,
              let known = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return }
        didAttemptAutoConnect = true
        state = .connecting
        connectedName = known.name ?? "Saved scale"
        peripheral = known
        known.delegate = self
        central.connect(known)
    }

    fileprivate func ingest(characteristic uuid: String, bytes: [UInt8]) {
        frames.insert(Frame(characteristic: uuid, bytes: bytes, time: Date()), at: 0)
        if frames.count > frameLimit { frames.removeLast(frames.count - frameLimit) }

        if let decoded = ScaleDecoder.decode(bytes, config: config) {
            reading = decoded
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension ScaleService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let cbState = central.state
        Task { @MainActor in
            switch cbState {
            case .poweredOn:
                if self.state == .poweredOff { self.state = .idle }
                self.attemptAutoConnect()
            case .poweredOff:
                self.state = .poweredOff
            case .unauthorized:
                self.state = .poweredOff
                self.lastError = "Bluetooth permission denied. Enable it in Settings."
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        let id = peripheral.identifier
        let rssi = RSSI.intValue

        // Unnamed peripherals are almost always beacons/accessories, not scales.
        guard !name.isEmpty else { return }

        Task { @MainActor in
            let entry = Discovered(id: id, name: name, rssi: rssi)
            if let idx = self.discovered.firstIndex(where: { $0.id == id }) {
                self.discovered[idx] = entry
            } else {
                self.discovered.append(entry)
            }
            self.discovered.sort { $0.rssi > $1.rssi }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
        Task { @MainActor in
            self.state = .connected
            self.connectedName = peripheral.name ?? self.connectedName
            Haptics.success()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.state = .disconnected
            self.lastError = message ?? "Could not connect to the scale."
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.state = .disconnected
            self.reading = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ScaleService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        // Subscribe to anything that can push data — the weight stream is
        // whichever one starts firing when load changes.
        for ch in service.characteristics ?? []
        where ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
            peripheral.setNotifyValue(true, for: ch)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        let uuid = characteristic.uuid.uuidString
        Task { @MainActor in
            self.ingest(characteristic: uuid, bytes: bytes)
        }
    }
}
