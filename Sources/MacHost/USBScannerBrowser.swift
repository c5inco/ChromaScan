import Foundation
import IOKit
import IOKit.usb
import IOUSBHost
import OSLog

private let usbBrowserLog = Logger(subsystem: "com.chromascan.usb", category: "browser")

// MARK: - USB Configuration Descriptor Parser

/// Pure parser that inspects raw USB Configuration Descriptor bytes across **all** alternate
/// settings to find IPP-over-USB (`bInterfaceClass == 0x07`, `bInterfaceSubClass == 0x01`,
/// `bInterfaceProtocol == 0x04`) interfaces and their Bulk IN / Bulk OUT endpoints.
enum USBConfigurationDescriptorParser {
    static let usbDescriptorTypeInterface: UInt8 = 0x04
    static let usbDescriptorTypeEndpoint: UInt8 = 0x05
    static let printerClass: UInt8 = 0x07
    static let printerSubClass: UInt8 = 0x01
    static let ippUSBProtocol: UInt8 = 0x04

    static func parseIPPUSBInterfaces(from descriptorData: Data) -> [IPPUSBInterfaceDescriptor] {
        var results: [IPPUSBInterfaceDescriptor] = []

        var currentInterface: (num: UInt8, alt: UInt8, isIPPUSB: Bool)?
        var bulkIn: UInt8?
        var bulkOut: UInt8?
        var maxPacket: UInt16 = 512

        func flushCurrent() {
            if let iface = currentInterface, iface.isIPPUSB, let inAddr = bulkIn, let outAddr = bulkOut {
                results.append(IPPUSBInterfaceDescriptor(
                    interfaceNumber: iface.num,
                    alternateSetting: iface.alt,
                    bulkInAddress: inAddr,
                    bulkOutAddress: outAddr,
                    maxPacketSize: maxPacket
                ))
            }
            bulkIn = nil
            bulkOut = nil
            maxPacket = 512
        }

        descriptorData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let total = raw.count
            var offset = 0

            while offset + 2 <= total {
                let len = Int(base[offset])
                let type = base[offset + 1]
                guard len >= 2, offset + len <= total else { break }

                if type == usbDescriptorTypeInterface && len >= 9 {
                    flushCurrent()
                    let ifNum = base[offset + 2]
                    let alt = base[offset + 3]
                    let cls = base[offset + 5]
                    let sub = base[offset + 6]
                    let proto = base[offset + 7]
                    let isIPP = (cls == printerClass && sub == printerSubClass && proto == ippUSBProtocol)
                    currentInterface = (ifNum, alt, isIPP)
                } else if type == usbDescriptorTypeEndpoint && len >= 7,
                          let iface = currentInterface, iface.isIPPUSB {
                    let epAddr = base[offset + 2]
                    let attrs = base[offset + 3]
                    let transferType = attrs & 0x03
                    if transferType == 0x02 { // Bulk endpoint
                        let mps = UInt16(base[offset + 4]) | (UInt16(base[offset + 5]) << 8)
                        if (epAddr & 0x80) != 0 {
                            if bulkIn == nil { bulkIn = epAddr }
                        } else {
                            if bulkOut == nil { bulkOut = epAddr }
                        }
                        if mps > 0 { maxPacket = mps }
                    }
                }

                offset += len
            }
        }

        flushCurrent()

        var seen = Set<UInt8>()
        return results
            .sorted { ($0.interfaceNumber, $0.alternateSetting) < ($1.interfaceNumber, $1.alternateSetting) }
            .filter { seen.insert($0.interfaceNumber).inserted }
    }
}

// MARK: - USB IPP-USB Scanner Discovery (IOKit + IOUSBHost)

/// Watches for hot-plugged USB devices advertising IPP-over-USB (`0x07/0x01/0x04`) interfaces
/// on any alternate setting and spins up a lazy local `IPPUSBBridge` (`127.0.0.1:<port>`) per device.
///
/// All IOKit notification port setup, initial iterator draining, callback handling, and teardown
/// are strictly serialized on `ioQueue` so IOKit callbacks can never race teardown or touch a freed context.
@MainActor
final class USBScannerBrowser {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?

    private struct TrackedUSBDevice {
        let entryID: UInt64
        let scanner: DiscoveredScanner
        let bridge: IPPUSBBridge
    }

    private struct DiscoveredUSBDeviceInfo: Sendable {
        let entryID: UInt64
        let vendorID: UInt16
        let productID: UInt16
        let locationID: UInt32
        let vendorName: String?
        let productName: String?
        let serialNumber: String?
        let interfaces: [IPPUSBInterfaceDescriptor]
    }

    /// Exclusively owned by `ioQueue` — never mutated from the main actor.
    private final class IOState: @unchecked Sendable {
        var notificationPort: IONotificationPortRef?
        var matchedIterator: io_iterator_t = 0
        var terminatedIterator: io_iterator_t = 0
        var callbackContext: Unmanaged<NotificationBridge>?
        var activeGeneration: UInt64 = 0
    }

    private final class NotificationBridge: @unchecked Sendable {
        weak var owner: USBScannerBrowser?
        let generation: UInt64
        init(owner: USBScannerBrowser, generation: UInt64) {
            self.owner = owner
            self.generation = generation
        }
    }

    private let ioQueue = DispatchQueue(label: "com.chromascan.usb.discovery")
    private let ioState = IOState()
    private var trackedByEntryID: [UInt64: TrackedUSBDevice] = [:]
    private var generation: UInt64 = 0
    private var isStarted = false

    func start() {
        stop()
        isStarted = true
        generation &+= 1
        let startGen = generation
        let state = ioState

        ioQueue.async { [weak self] in
            guard let self else { return }
            Self.startIOKitOnQueue(owner: self, state: state, generation: startGen)
        }
    }

    /// Performs an additive USB rescan without tearing down existing live bridges or changing their ports.
    func refresh() {
        guard isStarted else {
            start()
            return
        }
        let currentGen = generation
        ioQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = Self.scanCurrentlyAttachedDevices()
            Task { @MainActor [weak self] in
                guard let self, self.isStarted, self.generation == currentGen else { return }
                self.reconcileScannedDevices(snapshot)
            }
        }
    }

    func stop() {
        isStarted = false
        generation &+= 1

        let bridgesToStop = Array(trackedByEntryID.values.map(\.bridge))
        trackedByEntryID.removeAll()

        let state = ioState
        // Serialize IOKit teardown on ioQueue so no in-flight callback can touch freed iterators/context.
        ioQueue.async {
            Self.stopIOKitOnQueue(state: state)
            for bridge in bridgesToStop {
                bridge.stop()
            }
        }
    }

    // MARK: - Device Arrival / Removal (MainActor)

    private func handleArrivedDevices(_ infos: [DiscoveredUSBDeviceInfo], generation eventGen: UInt64) {
        guard isStarted, generation == eventGen, !infos.isEmpty else { return }
        var changed = false
        for info in infos {
            if addTrackedDeviceIfNeeded(info) {
                changed = true
            }
        }
        if changed {
            publishScanners()
        }
    }

    private func handleRemovedEntryIDs(_ entryIDs: [UInt64], generation eventGen: UInt64) {
        guard isStarted, generation == eventGen, !entryIDs.isEmpty else { return }
        var changed = false
        var bridgesToStop: [IPPUSBBridge] = []
        for id in entryIDs {
            if let removed = trackedByEntryID.removeValue(forKey: id) {
                bridgesToStop.append(removed.bridge)
                changed = true
                usbBrowserLog.notice("USB scanner disconnected: '\(removed.scanner.displayTitle, privacy: .public)'")
            }
        }
        if !bridgesToStop.isEmpty {
            let stopList = bridgesToStop
            ioQueue.async {
                for bridge in stopList {
                    bridge.stop()
                }
            }
        }
        if changed {
            publishScanners()
        }
    }

    private func reconcileScannedDevices(_ snapshot: [DiscoveredUSBDeviceInfo]) {
        var changed = false
        let liveIDs = Set(snapshot.map(\.entryID))

        // Remove any devices that are no longer attached
        var bridgesToStop: [IPPUSBBridge] = []
        for entryID in Array(trackedByEntryID.keys) where !liveIDs.contains(entryID) {
            if let removed = trackedByEntryID.removeValue(forKey: entryID) {
                bridgesToStop.append(removed.bridge)
                changed = true
            }
        }
        if !bridgesToStop.isEmpty {
            let stopList = bridgesToStop
            ioQueue.async {
                for bridge in stopList {
                    bridge.stop()
                }
            }
        }

        // Add any newly detected devices while keeping existing bridges untouched
        for info in snapshot {
            if addTrackedDeviceIfNeeded(info) {
                changed = true
            }
        }
        if changed {
            publishScanners()
        }
    }

    private func addTrackedDeviceIfNeeded(_ info: DiscoveredUSBDeviceInfo) -> Bool {
        guard trackedByEntryID[info.entryID] == nil else { return false }
        guard !info.interfaces.isEmpty else { return false }

        let deviceKey = info.serialNumber ?? String(format: "%04x-%04x-%08x", info.vendorID, info.productID, info.locationID)
        let interfaces = info.interfaces
        let deviceEntryID = info.entryID

        let bridge = IPPUSBBridge(
            deviceIdentifier: deviceKey,
            channelCount: interfaces.count,
            idleReleaseSeconds: 4.0
        ) { slotIndex in
            let desc = interfaces[min(slotIndex, interfaces.count - 1)]
            guard let ifService = Self.findInterfaceService(
                deviceEntryID: deviceEntryID,
                interfaceNumber: desc.interfaceNumber
            ) else {
                throw IPPUSBBridgeError.interfaceNotFound(desc.interfaceNumber)
            }
            defer { IOObjectRelease(ifService) }
            return try IOUSBHostChannelTransport(ioService: ifService, descriptor: desc)
        }

        do {
            let boundPort = try bridge.start()
            let displayName = DiscoveredScanner.usbDisplayName(
                vendor: info.vendorName,
                product: info.productName
            )
            let modelName: String? = {
                let cleanProd = info.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let cleanVend = info.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !cleanProd.isEmpty {
                    if !cleanVend.isEmpty && !cleanProd.lowercased().hasPrefix(cleanVend.lowercased()) {
                        return "\(cleanVend) \(cleanProd)"
                    }
                    return cleanProd
                }
                return nil
            }()
            let idSuffix = (info.serialNumber?.isEmpty == false)
                ? info.serialNumber!
                : String(format: "%04x:%04x:%08x", info.vendorID, info.productID, info.locationID)

            let scanner = DiscoveredScanner(
                id: "usb:\(idSuffix)",
                name: displayName,
                host: "127.0.0.1",
                port: Int(boundPort),
                useTLS: false,
                rootPath: "eSCL",
                modelName: modelName,
                uuid: nil,
                transport: .usb,
                serialNumber: info.serialNumber,
                usbLocationID: info.locationID
            )

            trackedByEntryID[info.entryID] = TrackedUSBDevice(
                entryID: info.entryID,
                scanner: scanner,
                bridge: bridge
            )
            usbBrowserLog.notice("Discovered USB IPP-USB scanner '\(displayName, privacy: .public)' (interfaces=\(interfaces.count), port=\(boundPort))")
            return true
        } catch {
            bridge.stop()
            usbBrowserLog.error("Failed to start IPPUSBBridge for \(deviceKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func publishScanners() {
        let sorted = trackedByEntryID.values
            .map(\.scanner)
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        onScannersChanged?(sorted)
    }

    // MARK: - ioQueue-Serialized IOKit Setup & Teardown

    private nonisolated static func startIOKitOnQueue(owner: USBScannerBrowser, state: IOState, generation: UInt64) {
        stopIOKitOnQueue(state: state)
        state.activeGeneration = generation

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            usbBrowserLog.error("Failed to create IOKit notification port")
            return
        }
        state.notificationPort = port

        let bridge = NotificationBridge(owner: owner, generation: generation)
        let retained = Unmanaged.passRetained(bridge)
        state.callbackContext = retained
        let refCon = retained.toOpaque()

        // Register notifications before attaching dispatch queue so initial drain on this serial
        // queue cannot race against live hot-plug callbacks.
        let matchDict = IOServiceMatching(kIOUSBDeviceClassName)
        var matchIter: io_iterator_t = 0
        let matchKR = IOServiceAddMatchingNotification(
            port,
            kIOFirstMatchNotification,
            matchDict,
            { refCon, iterator in
                guard let refCon else { return }
                let box = Unmanaged<NotificationBridge>.fromOpaque(refCon).takeUnretainedValue()
                let devices = USBScannerBrowser.drainArrivedDevices(from: iterator)
                let gen = box.generation
                Task { @MainActor in
                    box.owner?.handleArrivedDevices(devices, generation: gen)
                }
            },
            refCon,
            &matchIter
        )

        var initialDevices: [DiscoveredUSBDeviceInfo] = []
        if matchKR == KERN_SUCCESS {
            state.matchedIterator = matchIter
            initialDevices = drainArrivedDevices(from: matchIter)
        } else {
            usbBrowserLog.error("IOServiceAddMatchingNotification(firstMatch) failed: \(matchKR)")
        }

        let termDict = IOServiceMatching(kIOUSBDeviceClassName)
        var termIter: io_iterator_t = 0
        let termKR = IOServiceAddMatchingNotification(
            port,
            kIOTerminatedNotification,
            termDict,
            { refCon, iterator in
                guard let refCon else { return }
                let box = Unmanaged<NotificationBridge>.fromOpaque(refCon).takeUnretainedValue()
                let removedIDs = USBScannerBrowser.drainTerminatedEntryIDs(from: iterator)
                let gen = box.generation
                Task { @MainActor in
                    box.owner?.handleRemovedEntryIDs(removedIDs, generation: gen)
                }
            },
            refCon,
            &termIter
        )

        if termKR == KERN_SUCCESS {
            state.terminatedIterator = termIter
            _ = drainTerminatedEntryIDs(from: termIter)
        } else {
            usbBrowserLog.error("IOServiceAddMatchingNotification(terminated) failed: \(termKR)")
        }

        // Arm future callbacks on the owner's serial ioQueue now that initial draining is complete.
        IONotificationPortSetDispatchQueue(port, owner.ioQueue)

        if !initialDevices.isEmpty {
            Task { @MainActor [weak owner] in
                owner?.handleArrivedDevices(initialDevices, generation: generation)
            }
        }
    }

    private nonisolated static func stopIOKitOnQueue(state: IOState) {
        state.activeGeneration &+= 1
        if let port = state.notificationPort {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
            state.notificationPort = nil
        }
        if state.matchedIterator != 0 {
            IOObjectRelease(state.matchedIterator)
            state.matchedIterator = 0
        }
        if state.terminatedIterator != 0 {
            IOObjectRelease(state.terminatedIterator)
            state.terminatedIterator = 0
        }
        if let ctx = state.callbackContext {
            state.callbackContext = nil
            ctx.release()
        }
    }

    private nonisolated static func scanCurrentlyAttachedDevices() -> [DiscoveredUSBDeviceInfo] {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iter) }
        return drainArrivedDevices(from: iter)
    }

    // MARK: - Non-Isolated IOKit Descriptor Inspection

    private nonisolated static func drainArrivedDevices(from iterator: io_iterator_t) -> [DiscoveredUSBDeviceInfo] {
        var found: [DiscoveredUSBDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let info = inspectUSBDevice(service) {
                found.append(info)
            }
        }
        return found
    }

    private nonisolated static func drainTerminatedEntryIDs(from iterator: io_iterator_t) -> [UInt64] {
        var ids: [UInt64] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS {
                ids.append(entryID)
            }
        }
        return ids
    }

    private nonisolated static func inspectUSBDevice(_ service: io_service_t) -> DiscoveredUSBDeviceInfo? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }

        guard let vendorID = intProperty(service, key: "idVendor").map(UInt16.init),
              let productID = intProperty(service, key: "idProduct").map(UInt16.init) else {
            return nil
        }

        // Fast skip for Apple hubs / internal controllers
        if vendorID == 0x05AC { return nil }

        // Pre-filter purely via non-exclusive IORegistry properties so we NEVER take an exclusive
        // IOUSBHostDevice open on unrelated USB devices (keyboards, hubs, audio interfaces, phones).
        guard looksLikePrinterOrIPPUSBDevice(service) else { return nil }

        let locationID = uint32Property(service, key: "locationID") ?? 0
        let vendorName = stringProperty(service, key: "USB Vendor Name")
            ?? stringProperty(service, key: "kUSBVendorString")
        let productName = stringProperty(service, key: "USB Product Name")
            ?? stringProperty(service, key: "kUSBProductString")
        let serialNumber = stringProperty(service, key: "USB Serial Number")
            ?? stringProperty(service, key: "kUSBSerialNumberString")

        // 1. Read full USB configuration descriptor (finds IPP-USB even on alt setting 1+)
        var ippInterfaces = readIPPUSBInterfacesViaHostDevice(service)

        // 2. Fallback: if another process (e.g. macOS ippusbd) currently holds exclusive IOUSBHostDevice access,
        //    inspect child IOUSBHostInterface registry properties (no exclusive lock needed).
        if ippInterfaces.isEmpty {
            ippInterfaces = inspectChildRegistryInterfaces(service)
        }

        guard !ippInterfaces.isEmpty else { return nil }

        return DiscoveredUSBDeviceInfo(
            entryID: entryID,
            vendorID: vendorID,
            productID: productID,
            locationID: locationID,
            vendorName: vendorName,
            productName: productName,
            serialNumber: serialNumber,
            interfaces: ippInterfaces
        )
    }

    /// Non-exclusive IORegistry pre-filter: returns `true` only if the USB device advertises a
    /// Printer-class (`0x07`) child interface or includes the `07 01 04` IPP-USB triplet in its
    /// `UsbDeviceSignature` property.
    private nonisolated static func looksLikePrinterOrIPPUSBDevice(_ deviceService: io_service_t) -> Bool {
        if let sig = IORegistryEntryCreateCFProperty(
            deviceService,
            "UsbDeviceSignature" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Data {
            let pattern = Data([
                USBConfigurationDescriptorParser.printerClass,
                USBConfigurationDescriptorParser.printerSubClass,
                USBConfigurationDescriptorParser.ippUSBProtocol
            ])
            if sig.range(of: pattern) != nil {
                return true
            }
        }

        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(childIter) }

        while case let child = IOIteratorNext(childIter), child != 0 {
            defer { IOObjectRelease(child) }
            if let cls = intProperty(child, key: "bInterfaceClass"),
               cls == Int(USBConfigurationDescriptorParser.printerClass) {
                return true
            }
        }
        return false
    }

    private nonisolated static func readIPPUSBInterfacesViaHostDevice(_ service: io_service_t) -> [IPPUSBInterfaceDescriptor] {
        do {
            let device = try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { device.destroy() }
            guard let configPtr = device.configurationDescriptor else { return [] }
            let totalLen = Int(configPtr.pointee.wTotalLength)
            guard totalLen > 0 else { return [] }
            let data = Data(bytes: configPtr, count: totalLen)
            return USBConfigurationDescriptorParser.parseIPPUSBInterfaces(from: data)
        } catch {
            return []
        }
    }

    private nonisolated static func inspectChildRegistryInterfaces(_ deviceService: io_service_t) -> [IPPUSBInterfaceDescriptor] {
        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(childIter) }

        var found: [IPPUSBInterfaceDescriptor] = []
        while case let child = IOIteratorNext(childIter), child != 0 {
            defer { IOObjectRelease(child) }
            guard let cls = intProperty(child, key: "bInterfaceClass"),
                  let sub = intProperty(child, key: "bInterfaceSubClass"),
                  let proto = intProperty(child, key: "bInterfaceProtocol"),
                  cls == Int(USBConfigurationDescriptorParser.printerClass),
                  sub == Int(USBConfigurationDescriptorParser.printerSubClass),
                  proto == Int(USBConfigurationDescriptorParser.ippUSBProtocol),
                  let ifNum = intProperty(child, key: "bInterfaceNumber") else {
                continue
            }
            let alt = UInt8(intProperty(child, key: "bAlternateSetting") ?? 0)
            // Exact endpoint addresses are resolved from iface.configurationDescriptor when opened.
            found.append(IPPUSBInterfaceDescriptor(
                interfaceNumber: UInt8(ifNum),
                alternateSetting: alt,
                bulkInAddress: 0x82,
                bulkOutAddress: 0x01,
                maxPacketSize: 512
            ))
        }
        return found.sorted { $0.interfaceNumber < $1.interfaceNumber }
    }

    /// Locates the exact child `IOUSBHostInterface` belonging to `deviceEntryID`, avoiding
    /// cross-device confusion when two identical VID/PID printers are attached simultaneously.
    private nonisolated static func findInterfaceService(
        deviceEntryID: UInt64,
        interfaceNumber: UInt8
    ) -> io_service_t? {
        guard let matching = IORegistryEntryIDMatching(deviceEntryID) else { return nil }
        let deviceService = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard deviceService != 0 else { return nil }
        defer { IOObjectRelease(deviceService) }

        var childIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(deviceService, kIOServicePlane, &childIter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(childIter) }

        while case let child = IOIteratorNext(childIter), child != 0 {
            if let ifNum = intProperty(child, key: "bInterfaceNumber").map(UInt8.init),
               ifNum == interfaceNumber {
                return child // Caller owns and releases
            }
            IOObjectRelease(child)
        }
        return nil
    }

    private nonisolated static func stringProperty(_ service: io_service_t, key: String) -> String? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    private nonisolated static func intProperty(_ service: io_service_t, key: String) -> Int? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (raw as? NSNumber)?.intValue
    }

    private nonisolated static func uint32Property(_ service: io_service_t, key: String) -> UInt32? {
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return nil
        }
        return (raw as? NSNumber)?.uint32Value
    }
}
