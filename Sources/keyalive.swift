// Required Notice: Copyright (c) 2026 Saul Gonzalez (https://github.com/Saul-Punybz/keyalive)
// Licensed under the PolyForm Noncommercial License 1.0.0 — see LICENSE.md. Commercial use requires a paid license.
//
// KeyAlive — keeps Bluetooth LE keyboards from falling asleep on macOS.
//
// Many cheap BLE keyboards power down their radio after a few idle minutes and
// then take seconds (or a manual re-pair) to come back. KeyAlive finds every BLE
// keyboard the system has connected, reads a tiny GATT characteristic from it on
// a fixed interval so the keyboard sees traffic, and keeps a pending connection
// open so that a keyboard that does drop is re-attached the moment it wakes.

import CoreBluetooth
import Foundation
import IOKit.hid

let version = "0.1.0"

// MARK: - Options

struct Options {
    var interval: TimeInterval = 60
    var names: [String] = []      // explicit name filters (substring, case-insensitive)
    var includeMice = false
    var verbose = false
    var command = "run"           // run | list
    var listSeconds: TimeInterval = 15
}

func usage() -> Never {
    print("""
    keyalive \(version) — keep Bluetooth LE keyboards awake on macOS

    USAGE
      keyalive [run] [--interval SECONDS] [--name TEXT]... [--include-mice]
      keyalive list [SECONDS]
      keyalive --version | --help

    run (default)   Watch every BLE keyboard the Mac has connected, ping each one
                    every --interval seconds (default 60) and reconnect it as soon
                    as it wakes up if it ever drops.
    list            Show the BLE keyboards (and mice) macOS knows about right now,
                    then scan for nearby BLE devices for SECONDS (default 15).

      --name TEXT     Only handle devices whose name contains TEXT (repeatable).
                      Without it, every BLE keyboard macOS reports is handled.
      --include-mice  Also keep BLE mice and trackpads awake.
      --verbose       Log every ping (to see whether a keyboard drops right after one).
    """)
    exit(0)
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    if let first = args.first, !first.hasPrefix("-") { o.command = first; args.removeFirst() }
    var i = 0
    func value() -> String {
        i += 1
        guard i < args.count else { fail("missing value for \(args[i - 1])") }
        return args[i]
    }
    while i < args.count {
        switch args[i] {
        case "--interval", "-i":
            guard let v = TimeInterval(value()), v >= 5 else { fail("--interval must be a number ≥ 5") }
            o.interval = v
        case "--name", "-n": o.names.append(value().lowercased())
        case "--include-mice": o.includeMice = true
        case "--verbose": o.verbose = true
        case "--version", "-v": print(version); exit(0)
        case "--help", "-h": usage()
        default:
            if o.command == "list", let s = TimeInterval(args[i]) { o.listSeconds = s }
            else { fail("unknown option \(args[i])") }
        }
        i += 1
    }
    guard ["run", "list"].contains(o.command) else { fail("unknown command \(o.command)") }
    return o
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write("keyalive: \(msg)\n".data(using: .utf8)!)
    exit(2)
}

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date()))  \(s)")
    fflush(stdout)
}

// MARK: - Which devices are BLE keyboards (asked to the HID system, not guessed)

struct HIDDevice { let name: String; let isKeyboard: Bool }

/// Names of the HID devices macOS currently has over Bluetooth LE.
func bleHIDDevices() -> [HIDDevice] {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(manager, nil)
    guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
    var seen = [String: HIDDevice]()
    for d in set {
        let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
        guard transport.localizedCaseInsensitiveContains("Bluetooth Low Energy") else { continue }
        guard let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String else { continue }
        let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
        guard page == kHIDPage_GenericDesktop else { continue }
        let isKeyboard = usage == kHIDUsage_GD_Keyboard || usage == kHIDUsage_GD_Keypad
        let isPointer = usage == kHIDUsage_GD_Mouse || usage == kHIDUsage_GD_Pointer
        guard isKeyboard || isPointer else { continue }
        if seen[name]?.isKeyboard != true { seen[name] = HIDDevice(name: name, isKeyboard: isKeyboard) }
    }
    return Array(seen.values).sorted { $0.name < $1.name }
}

// MARK: - Remembered devices (so a keyboard asleep at login is still re-attached)

let stateDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/keyalive")
let knownFile = stateDir.appendingPathComponent("known.json")

func loadKnown() -> [UUID: String] {
    guard let d = try? Data(contentsOf: knownFile),
          let raw = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
    return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
}

func saveKnown(_ known: [UUID: String]) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let raw = Dictionary(uniqueKeysWithValues: known.map { ($0.key.uuidString, $0.value) })
    if let d = try? JSONEncoder().encode(raw) { try? d.write(to: knownFile) }
}

// MARK: - Keep-alive agent

let hidService = CBUUID(string: "1812")
let batteryService = CBUUID(string: "180F")
let batteryLevel = CBUUID(string: "2A19")
let deviceInfoService = CBUUID(string: "180A")

final class Agent: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let opts: Options
    var cm: CBCentralManager!
    var tracked = [UUID: CBPeripheral]()
    var pingChar = [UUID: CBCharacteristic]()
    var lastBattery = [UUID: Int]()
    var known = loadKnown()
    var timer: Timer?

    init(_ o: Options) {
        opts = o
        super.init()
        cm = CBCentralManager(delegate: self, queue: nil)
    }

    func wanted(_ name: String) -> Bool {
        let n = name.lowercased()
        if !opts.names.isEmpty { return opts.names.contains { n.contains($0) } }
        return bleHIDDevices().contains { $0.name == name && ($0.isKeyboard || opts.includeMice) }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            log("Bluetooth on — looking for BLE keyboards (ping every \(Int(opts.interval)) s)")
            // Turning Bluetooth off (e.g. Mac sleep) cancels every connection: re-arm the ones we track.
            for p in tracked.values where p.state != .connected {
                pingChar[p.identifier] = nil
                cm.connect(p, options: nil)
            }
            // Re-arm pending connections for keyboards seen before (maybe asleep right now).
            // A sleeping keyboard is absent from the HID list, so only the --name filter applies here.
            for p in c.retrievePeripherals(withIdentifiers: Array(known.keys)) {
                let name = (p.name ?? known[p.identifier] ?? "").lowercased()
                if opts.names.isEmpty || opts.names.contains(where: { name.contains($0) }) { track(p, reason: "remembered") }
            }
            refresh()
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: opts.interval, repeats: true) { [weak self] _ in
                    self?.refresh()
                    self?.pingAll()
                }
            }
        case .unauthorized:
            log("Bluetooth permission denied — allow keyalive in System Settings → Privacy & Security → Bluetooth")
        case .poweredOff:
            log("Bluetooth is off — waiting")
        default:
            log("Bluetooth not available (state \(c.state.rawValue))")
        }
    }

    /// Pick up keyboards that connected since the last pass.
    func refresh() {
        let connected = cm.retrieveConnectedPeripherals(withServices: [hidService, batteryService, deviceInfoService])
        for p in connected where tracked[p.identifier] == nil {
            guard let name = p.name, wanted(name) else { continue }
            track(p, reason: "found")
        }
    }

    func track(_ p: CBPeripheral, reason: String) {
        guard tracked[p.identifier] == nil else { return }
        tracked[p.identifier] = p
        p.delegate = self
        if let name = p.name, known[p.identifier] != name { known[p.identifier] = name; saveKnown(known) }
        log("\(reason): \(label(p))")
        cm.connect(p, options: nil)   // no timeout: completes whenever the keyboard is reachable
    }

    func label(_ p: CBPeripheral) -> String { p.name ?? known[p.identifier] ?? p.identifier.uuidString }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("CONNECTED \(label(p))")
        p.discoverServices([batteryService, deviceInfoService])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("DISCONNECTED \(label(p)) (\(error?.localizedDescription ?? "no reason given")) — will reconnect when it wakes")
        pingChar[p.identifier] = nil
        if c.state == .poweredOn { c.connect(p, options: nil) }
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        // While Bluetooth is off, connect fails instantly; the poweredOn handler re-arms it instead.
        guard c.state == .poweredOn else { return }
        log("connect failed for \(label(p)): \(error?.localizedDescription ?? "-") — retrying in 5 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.cm.state == .poweredOn, p.state == .disconnected else { return }
            self.cm.connect(p, options: nil)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        // Battery level is the best ping (small, always readable); otherwise any readable characteristic.
        if let b = chars.first(where: { $0.uuid == batteryLevel }) {
            pingChar[p.identifier] = b
        } else if pingChar[p.identifier] == nil, let r = chars.first(where: { $0.properties.contains(.read) }) {
            pingChar[p.identifier] = r
        }
        ping(p)
    }

    func pingAll() { tracked.values.forEach(ping) }

    func ping(_ p: CBPeripheral) {
        guard p.state == .connected, let ch = pingChar[p.identifier] else {
            if opts.verbose { log("ping skipped \(label(p)) (state \(p.state.rawValue), char \(pingChar[p.identifier] != nil))") }
            return
        }
        if opts.verbose { log("ping → \(label(p))") }
        p.readValue(for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        if let e = error { log("ping failed for \(label(p)): \(e.localizedDescription)"); return }
        if opts.verbose { log("ping ok \(label(p)) [\(ch.uuid.uuidString)]") }
        guard ch.uuid == batteryLevel, let v = ch.value?.first.map(Int.init) else { return }
        if lastBattery[p.identifier] != v {
            log("battery \(label(p)): \(v)%")
            lastBattery[p.identifier] = v
        }
    }
}

// MARK: - list

final class Lister: NSObject, CBCentralManagerDelegate {
    var cm: CBCentralManager!
    var seen = Set<UUID>()
    let seconds: TimeInterval
    init(seconds: TimeInterval) { self.seconds = seconds; super.init(); cm = CBCentralManager(delegate: self, queue: nil) }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        guard c.state == .poweredOn else {
            if c.state == .unauthorized { fail("Bluetooth permission denied for this app") }
            return
        }
        let hid = bleHIDDevices()
        print("BLE keyboards and mice macOS has connected:")
        if hid.isEmpty { print("  (none)") }
        for d in hid { print("  \(d.isKeyboard ? "keyboard" : "mouse   ")  \(d.name)") }
        print("\nScanning for nearby BLE devices for \(Int(seconds)) s (a keyboard in pairing mode shows up here)…")
        c.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        guard seen.insert(p.identifier).inserted else { return }
        guard let name = p.name ?? ad[CBAdvertisementDataLocalNameKey] as? String else { return }
        let services = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let tag = services.contains(hidService) || name.lowercased().contains("keyboard") ? "  <- keyboard?" : ""
        print("  \(name)  (signal \(rssi) dBm)\(tag)")
    }
}

// MARK: - main

let opts = parse()
switch opts.command {
case "list":
    let l = Lister(seconds: opts.listSeconds)
    RunLoop.main.run(until: Date().addingTimeInterval(opts.listSeconds + 1))
    _ = l
default:
    log("keyalive \(version) starting")
    let a = Agent(opts)
    RunLoop.main.run()
    _ = a
}
