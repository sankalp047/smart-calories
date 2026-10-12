import Foundation
import CoreBluetooth
import Observation

/// Live connection to any BLE heart-rate monitor using the standard Heart
/// Rate profile (service 0x180D, measurement 0x2A37).
///
/// This deliberately targets the *standard* profile rather than any vendor
/// protocol: WHOOP bands in broadcast mode, Polar/Garmin chest straps, and
/// most armbands all speak it, so one implementation covers every device the
/// user is likely to own. Vendor-specific protocols (WHOOP historical sync,
/// sleep data) can layer on later without touching this.
///
/// Beyond the live BPM it accumulates three things the rest of the app uses:
/// exercise energy (Keytel, gated on elevated HR), a daily resting-HR proxy
/// (lowest calm reading), and rest HRV when the strap sends RR intervals.
@MainActor
@Observable
final class HeartRateService: NSObject {

    enum State: Equatable {
        case poweredOff, unauthorized, idle, scanning, connecting, connected, disconnected

        var label: String {
            switch self {
            case .poweredOff: "Bluetooth off"
            case .unauthorized: "Bluetooth permission needed"
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
        /// Whether the advert itself carried the HR service. Bands like WHOOP
        /// often expose it only after connecting, so false ≠ not a monitor.
        let advertisesHeartRate: Bool
    }

    // MARK: - Observable state

    private(set) var state: State = .idle
    private(set) var discovered: [Discovered] = []
    private(set) var connectedName: String?
    private(set) var bpm: Int?
    /// The band's battery, from the standard Battery Service (0x180F).
    /// Best-effort: not every device serves it over this connection.
    private(set) var batteryPercent: Int?
    private(set) var lastError: String?
    private(set) var dailySummaries: [DailyHeartSummary] = []

    /// Raw per-second archive; every sample lands here as well as in the
    /// daily rollup, and a shipper drains it to the server-side database.
    let samples = HeartSampleStore()

    var isConnected: Bool { state == .connected }

    // MARK: - Live source arbitration

    /// Where the live number is coming from right now. When both devices
    /// stream at once the WHOOP wins — it's the dedicated sensor — and the
    /// Watch fills in whenever the band isn't broadcasting.
    enum LiveSource: String {
        case whoop = "WHOOP"
        case watch = "Apple Watch"
    }
    private(set) var liveSource: LiveSource?
    private var watchStaleTask: Task<Void, Never>?

    /// Entry point for samples streamed from the Watch's workout session.
    func ingestWatchSample(bpm: Int, at date: Date) {
        // The BLE band owns the stream while connected; drop Watch samples
        // rather than interleaving two sensors' views of the same seconds.
        guard !isConnected else { return }
        liveSource = .watch
        handle(hr: bpm, rrIntervalsMs: [])

        // A live source that stops talking must not leave a frozen number
        // on screen; clear after 15 quiet seconds.
        watchStaleTask?.cancel()
        watchStaleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            guard let self, self.liveSource == .watch else { return }
            self.bpm = nil
            self.liveSource = nil
            self.samples.flush()
        }
    }

    /// Exercise kcal accumulated today across all connections.
    var todayActiveKcal: Double {
        summary(for: Date())?.activeKcal ?? 0
    }

    /// Training zone 1–5 for the live UI, nil when no reading or profile.
    var zone: Int? {
        guard let bpm, let age else { return nil }
        return EnergyMath.zone(hr: Double(bpm), age: age, maxHR: maxHROverride)
    }

    // MARK: - Profile inputs (for Keytel / zones)

    private var weightKg: Double?
    private var age: Double?
    private var isMale = true
    /// Learned personal max HR; overrides the age formula in zones and TRIMP.
    private var maxHROverride: Double?

    /// Called by AppEnvironment whenever the profile or calibration changes.
    func configure(weightKg: Double, age: Int, isMale: Bool, maxHR: Double? = nil) {
        self.weightKg = weightKg
        self.age = Double(age)
        self.isMale = isMale
        self.maxHROverride = maxHR
    }

    private var effectiveMaxHR: Double? {
        maxHROverride ?? age.map { EnergyMath.predictedMaxHR(age: $0) }
    }

    // MARK: - Session window (for workout logging)

    private var sessionSamples: [Int] = []
    private var sessionKcal: Double = 0
    private var sessionTrimp: Double = 0
    private var sessionZoneSeconds = [Double](repeating: 0, count: 5)
    private var sessionActive = false

    func beginSessionWindow() {
        sessionSamples = []
        sessionKcal = 0
        sessionTrimp = 0
        sessionZoneSeconds = [Double](repeating: 0, count: 5)
        sessionActive = true
    }

    /// Stats for the window since `beginSessionWindow`, nil if no data landed.
    func endSessionWindow() -> SessionHeartStats? {
        sessionActive = false
        guard !sessionSamples.isEmpty else { return nil }
        let avg = Double(sessionSamples.reduce(0, +)) / Double(sessionSamples.count)
        return SessionHeartStats(
            avgHR: Int(avg.rounded()),
            maxHR: sessionSamples.max() ?? 0,
            activeKcal: sessionKcal.rounded(),
            strain: (EnergyMath.strainScore(trimp: sessionTrimp) * 10).rounded() / 10,
            zoneSeconds: sessionZoneSeconds
        )
    }

    // MARK: - Derived

    /// Today's strain on the 0–21 scale.
    var todayStrain: Double {
        summary(for: Date())?.strain ?? 0
    }

    /// Median resting HR over the last 7 recorded days *before* today —
    /// the baseline this morning's value is judged against.
    var baselineRestingHR: Double? {
        let priors = dailySummaries
            .filter { !Calendar.current.isDateInToday($0.date) && $0.minHR < 250 }
            .suffix(7)
            .map(\.minHR)
            .sorted()
        guard priors.count >= 3 else { return nil }
        return Double(priors[priors.count / 2])
    }

    // MARK: - Private

    private let heartRateService = CBUUID(string: "180D")
    private let heartRateMeasurement = CBUUID(string: "2A37")
    private let batteryLevelCharacteristic = CBUUID(string: "2A19")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var autoConnectId: UUID?
    private var didAttemptAutoConnect = false

    private var lastSampleAt: Date?
    /// RR intervals from calm periods, drained into an RMSSD reading per ~50.
    private var calmRRBuffer: [Double] = []
    private var todayRMSSDReadings: [Double] = []

    override init() {
        super.init()
        dailySummaries = Store.load([DailyHeartSummary].self, key: Store.Key.heartDaily) ?? []
        if let raw = Store.load(String.self, key: Store.Key.lastHeartDevice) {
            autoConnectId = UUID(uuidString: raw)
        }
    }

    /// Deferred until a heart-related screen appears, so the Bluetooth
    /// permission prompt has context. Same pattern as ScaleService.
    func activate() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Set when the user asks to scan before CoreBluetooth has powered on —
    /// the first tap otherwise races the permission prompt and silently loses.
    private var wantsScanOnPowerOn = false

    func startScan() {
        guard let central else {
            wantsScanOnPowerOn = true
            activate()
            return
        }
        guard central.state == .poweredOn else {
            wantsScanOnPowerOn = true
            return
        }
        discovered = []
        state = .scanning
        // Unfiltered scan: WHOOP and some other bands advertise only their
        // vendor service and reveal 0x180D after connection, so filtering on
        // the HR service would never see them. We list every *named* device
        // and let the 2A37 subscription after connect decide what it is.
        central.scanForPeripherals(withServices: nil)
    }

    func stopScan() {
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    func connect(_ device: Discovered) {
        guard let central,
              let target = central.retrievePeripherals(withIdentifiers: [device.id]).first
        else { return }
        central.stopScan()
        state = .connecting
        peripheral = target
        target.delegate = self
        central.connect(target)
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        autoConnectId = nil
        Store.delete(key: Store.Key.lastHeartDevice)
    }

    // MARK: - Sample handling

    private func handle(hr: Int, rrIntervalsMs: [Double]) {
        let now = Date()
        bpm = hr
        samples.append(bpm: hr, at: now)

        if sessionActive { sessionSamples.append(hr) }

        // Time credited to this sample: the gap since the last one, capped
        // so a dropout doesn't credit minutes of phantom effort.
        let seconds = min(now.timeIntervalSince(lastSampleAt ?? now), 10)
        let minutes = seconds / 60
        lastSampleAt = now

        if let weightKg, let age {
            // Energy: Keytel only inside its valid range (elevated HR).
            if EnergyMath.isExerciseHeartRate(Double(hr), age: age, maxHR: maxHROverride) {
                let kcal = EnergyMath.keytelKcalPerMinute(
                    hr: Double(hr), weightKg: weightKg, age: age, isMale: isMale
                ) * minutes
                if sessionActive { sessionKcal += kcal }
                mutateToday { $0.activeKcal += kcal }
            }

            // Strain: TRIMP accrues from every sample; low-intensity time
            // contributes almost nothing by construction, so no gate needed.
            let trimp = EnergyMath.trimpIncrement(
                minutes: minutes, hr: Double(hr),
                restHR: baselineRestingHR ?? 60,
                maxHR: maxHROverride ?? EnergyMath.predictedMaxHR(age: age),
                isMale: isMale
            )
            let zoneIndex = EnergyMath.zone(hr: Double(hr), age: age, maxHR: maxHROverride) - 1
            if sessionActive {
                sessionTrimp += trimp
                sessionZoneSeconds[zoneIndex] += seconds
            }
            mutateToday { day in
                day.trimp = (day.trimp ?? 0) + trimp
                var zones = day.zoneSeconds ?? [Double](repeating: 0, count: 5)
                zones[zoneIndex] += seconds
                day.zoneSeconds = zones
            }
        }

        // HRV: collect RR only while calm — RMSSD during exercise is noise.
        if hr < 100, !rrIntervalsMs.isEmpty {
            calmRRBuffer.append(contentsOf: rrIntervalsMs)
            if calmRRBuffer.count >= 50 {
                if let value = EnergyMath.rmssd(rrIntervalsMs: calmRRBuffer) {
                    todayRMSSDReadings.append(value)
                    let sorted = todayRMSSDReadings.sorted()
                    let median = sorted[sorted.count / 2]
                    mutateToday { $0.restRMSSD = median }
                }
                calmRRBuffer = []
            }
        } else if hr >= 100 {
            calmRRBuffer = []
        }

        mutateToday { day in
            if hr < day.minHR, hr < 100 { day.minHR = hr }
            day.maxHR = max(day.maxHR, hr)
            day.avgHR = (day.avgHR * Double(day.sampleCount) + Double(hr))
                / Double(day.sampleCount + 1)
            day.sampleCount += 1
        }
    }

    private func summary(for date: Date) -> DailyHeartSummary? {
        dailySummaries.first { WeightEntry.dayKey($0.date) == WeightEntry.dayKey(date) }
    }

    private var persistCounter = 0

    private func mutateToday(_ mutate: (inout DailyHeartSummary) -> Void) {
        let key = WeightEntry.dayKey(Date())
        if let index = dailySummaries.firstIndex(where: { WeightEntry.dayKey($0.date) == key }) {
            mutate(&dailySummaries[index])
        } else {
            var day = DailyHeartSummary(
                date: Date(), minHR: 250, maxHR: 0, avgHR: 0,
                sampleCount: 0, activeKcal: 0, restRMSSD: nil
            )
            mutate(&day)
            dailySummaries.append(day)
        }
        // At 1 Hz a JSON write per sample would hammer the disk; every ~30
        // samples keeps loss negligible without the churn.
        persistCounter += 1
        if persistCounter >= 30 {
            persistCounter = 0
            persist()
        }
    }

    private func persist() {
        // Cap history at 90 days so the file stays trivial.
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()
        dailySummaries.removeAll { $0.date < cutoff }
        Store.save(dailySummaries, key: Store.Key.heartDaily)
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                state = .idle
                // Reconnect the last monitor silently, once per launch.
                if !didAttemptAutoConnect, let autoConnectId,
                   let known = central.retrievePeripherals(withIdentifiers: [autoConnectId]).first {
                    didAttemptAutoConnect = true
                    state = .connecting
                    peripheral = known
                    known.delegate = self
                    central.connect(known)
                }
            case .poweredOff:
                state = .poweredOff
                bpm = nil
            case .unauthorized:
                state = .unauthorized
                lastError = "Allow Bluetooth for Smart Calories in Settings to connect a monitor."
            default:
                break
            }
            if central.state == .poweredOn, wantsScanOnPowerOn {
                wantsScanOnPowerOn = false
                startScan()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        // Unfiltered scans surface every beacon in the room; a name is the
        // cheapest signal that this is a wearable rather than an AirTag.
        guard let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        else { return }

        var advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        advertised += advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let hasHR = advertised.contains(CBUUID(string: "180D"))

        let id = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            if let index = discovered.firstIndex(where: { $0.id == id }) {
                // Scan responses can add the HR service after the first sight.
                if hasHR, !discovered[index].advertisesHeartRate {
                    discovered[index] = Discovered(id: id, name: name, rssi: rssi,
                                                   advertisesHeartRate: true)
                }
                return
            }
            discovered.append(Discovered(id: id, name: name, rssi: rssi,
                                         advertisesHeartRate: hasHR))
            // Known monitors first, then by signal strength (closest first).
            discovered.sort {
                if $0.advertisesHeartRate != $1.advertisesHeartRate {
                    return $0.advertisesHeartRate
                }
                return $0.rssi > $1.rssi
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            state = .connected
            connectedName = peripheral.name ?? "Heart rate monitor"
            autoConnectId = peripheral.identifier
            Store.save(peripheral.identifier.uuidString, key: Store.Key.lastHeartDevice)
            // All services, not just 0x180D — some bands tuck the HR
            // characteristic somewhere unexpected.
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        Task { @MainActor in
            state = .disconnected
            bpm = nil
            batteryPercent = nil
            if liveSource == .whoop { liveSource = nil }
            persist()
            samples.flush()
            // Straps drop out when taken off; quietly retry so putting it
            // back on just works.
            if let autoConnectId,
               let known = central.retrievePeripherals(withIdentifiers: [autoConnectId]).first {
                central.connect(known)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        Task { @MainActor in
            state = .idle
            lastError = error?.localizedDescription
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateService: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case heartRateMeasurement:
                peripheral.setNotifyValue(true, for: characteristic)
            case batteryLevelCharacteristic:
                // Read now, and subscribe so drops arrive as they happen —
                // devices that reject battery notifications just ignore it.
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        if characteristic.uuid == batteryLevelCharacteristic,
           let byte = characteristic.value?.first, byte <= 100 {
            Task { @MainActor in batteryPercent = Int(byte) }
            return
        }
        guard characteristic.uuid == heartRateMeasurement,
              let data = characteristic.value,
              let parsed = Self.parseHeartRateMeasurement(data)
        else { return }
        Task { @MainActor in
            liveSource = .whoop
            handle(hr: parsed.bpm, rrIntervalsMs: parsed.rrIntervalsMs)
        }
    }

    /// Standard 2A37 layout: flags byte, then HR as u8 or u16 LE (flag bit 0),
    /// then optional Energy Expended u16 (bit 3), then RR intervals as u16 LE
    /// in units of 1/1024 s (bit 4).
    nonisolated static func parseHeartRateMeasurement(_ data: Data) -> (bpm: Int, rrIntervalsMs: [Double])? {
        guard data.count >= 2 else { return nil }
        let flags = data[0]
        var offset = 1

        let bpm: Int
        if flags & 0x01 != 0 {
            guard data.count >= offset + 2 else { return nil }
            bpm = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2
        } else {
            bpm = Int(data[offset])
            offset += 1
        }

        if flags & 0x08 != 0 { offset += 2 }   // skip Energy Expended field

        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while offset + 1 < data.count {
                let raw = Int(data[offset]) | (Int(data[offset + 1]) << 8)
                rr.append(Double(raw) * 1000.0 / 1024.0)
                offset += 2
            }
        }

        guard bpm > 0, bpm < 250 else { return nil }
        return (bpm, rr)
    }
}
