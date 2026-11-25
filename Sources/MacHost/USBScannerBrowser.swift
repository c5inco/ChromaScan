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

        // Deduplicate by interfaceNumber (preferring lower alternateSetting if somehow repeated)
        var seen = Set<UInt8>()
        return results
            .sorted { ($0.interfaceNumber, $0.alternateSetting) < ($1.interfaceNumber, $1.alternateSetting) }
            .filter { seen.insert($0.interfaceNumber).inserted }
    }
}

// MARK: - USB IPP-USB Scanner Discovery (IOKit + IOUSBHost)

/// Watches for hot-plugged USB devices advertising IPP-over-USB (`0x07/0x01/0x04`) interfaces
/// on any alternate setting and spins up a lazy local `IPPUSBBridge` (`127.0.0.1:<port>`) per device.
@MainActor
final class USBScannerBrowser {
    var onScannersChanged: (([DiscoveredScanner]) -> Void)?

    private struct TrackedUSBDevice {
        let entryID: UInt64
        let scanner: DiscoveredScanner
        let bridge: IPPUSBBridge
    }

    private let ioQueue = DispatchQueue(label: "com.chromascan.usb.discovery")
    private var notificationPort: IONotificationPortRef?
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    private var callbackContext: Unmanaged<NotificationBridge>?
    private var trackedByEntryID: [UInt64: TrackedUSBDevice] = [:]
    private var isStarted = false

    private final class NotificationBridge: @unchecked Sendable {
        weak var owner: USBScannerBrowser?
        init(owner: USBScannerBrowser) { self.owner = owner }
    }

    func start() {
        stop()
        isStarted = true

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            usbBrowserLog.error("Failed to create IOKit notification port")
            return
        }
        IONotificationPortSetDispatchQueue(port, ioQueue)
        self.notificationPort = port

        let bridge = NotificationBridge(owner: self)
        let retained = Unmanaged.passRetained(bridge)
        self.callbackContext = retained
        let refCon = retained.toOpaque()

        // 1. Register arrival notification (also yields all currently attached USB devices)
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
                Task { @MainActor in
                    box.owner?.handleArrivedDevices(devices)
                }
            },
            refCon,
            &matchIter
        )

        if matchKR == KERN_SUCCESS {
            self.matchedIterator = matchIter
            let initial = Self.drainArrivedDevices(from: matchIter)
            handleArrivedDevices(initial)
        } else {
            usbBrowserLog.error("IOServiceAddMatchingNotification(firstMatch) failed: \(matchKR)")
        }

        // 2. Register termination notification (USB unplug detection)
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
                Task { @MainActor in
                    box.owner?.handleRemovedEntryIDs(removedIDs)
                }
            },
            refCon,
            &termIter
        )

        if termKR == KERN_SUCCESS {
            self.terminatedIterator = termIter
            // Drain initial iterator to arm future termination notifications
            _ = Self.drainTerminatedEntryIDs(from: termIter)
        } else {
            usbBrowserLog.error("IOServiceAddMatchingNotification(terminated) failed: \(termKR)")
        }
    }

    func stop() {
        isStarted = false

        if matchedIterator != 0 {
            IOObjectRelease(matchedIterator)
            matchedIterator = 0
        }
        if terminatedIterator != 0 {
            IOObjectRelease(terminatedIterator)
            terminatedIterator = 0
        }
        if let port = notificationPort {
            IONotificationPortSetDispatchQueue(port, nil)
            IONotificationPortDestroy(port)
            notificationPort = nil
        }
        if let ctx = callbackContext {
            ctx.release()
            callbackContext = nil
        }

        for tracked in trackedByEntryID.values {
            tracked.bridge.stop()
        }
        trackedByEntryID.removeAll()
    }

    // MARK: - Device Arrival / Removal

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

    private func handleArrivedDevices(_ infos: [DiscoveredUSBDeviceInfo]) {
        guard isStarted, !infos.isEmpty else { return }
        var changed = false

        for info in infos {
            guard trackedByEntryID[info.entryID] == nil else { continue }
            guard !info.interfaces.isEmpty else { continue }

            let deviceKey = info.serialNumber ?? String(format: "%04x-%04x-%08x", info.vendorID, info.productID, info.locationID)
            let interfaces = info.interfaces
            let locationID = info.locationID
            let vendorID = info.vendorID
            let productID = info.productID

            let bridge = IPPUSBBridge(
                deviceIdentifier: deviceKey,
                channelCount: interfaces.count,
                idleReleaseSeconds: 4.0
            ) { slotIndex in
                let desc = interfaces[min(slotIndex, interfaces.count - 1)]
                guard let ifService = Self.findInterfaceService(
                    vendorID: vendorID,
                    productID: productID,
                    locationID: locationID,
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
                changed = true
                usbBrowserLog.notice("Discovered USB IPP-USB scanner '\(displayName, privacy: .public)' (interfaces=\(interfaces.count), port=\(boundPort))")
            } catch {
                bridge.stop()
                usbBrowserLog.error("Failed to start IPPUSBBridge for \(deviceKey, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if changed {
            publishScanners()
        }
    }

    private func handleRemovedEntryIDs(_ entryIDs: [UInt64]) {
        guard isStarted, !entryIDs.isEmpty else { return }
        var changed = false
        for id in entryIDs {
            if let removed = trackedByEntryID.removeValue(forKey: id) {
                removed.bridge.stop()
                changed = true
                usbBrowserLog.notice("USB scanner disconnected: '\(removed.scanner.displayTitle, privacy: .public)'")
            }
        }
        if changed {
            publishScanners()
        }
    }

    private func publishScanners() {
        let sorted = trackedByEntryID.values
            .map(\.scanner)
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        onScannersChanged?(sorted)
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

        let locationID = uint32Property(service, key: "locationID") ?? 0
        let vendorName = stringProperty(service, key: "USB Vendor Name")
            ?? stringProperty(service, key: "kUSBVendorString")
        let productName = stringProperty(service, key: "USB Product Name")
            ?? stringProperty(service, key: "kUSBProductString")
        let serialNumber = stringProperty(service, key: "USB Serial Number")
            ?? stringProperty(service, key: "kUSBSerialNumberString")

        // 1. Try reading full USB configuration descriptor (finds IPP-USB even on alt setting 1+)
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
            // When ippusbd holds the device, endpoint addresses are resolved dynamically if direct
            // access is ever opened later; record placeholder descriptor so the device is recognized.
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

    private nonisolated static func findInterfaceService(
        vendorID: UInt16,
        productID: UInt16,
        locationID: UInt32,
        interfaceNumber: UInt8
    ) -> io_service_t? {
        let matching = IOServiceMatching(kIOUSBInterfaceClassName)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        while case let service = IOIteratorNext(iter), service != 0 {
            let vid = intProperty(service, key: "idVendor").map(UInt16.init)
            let pid = intProperty(service, key: "idProduct").map(UInt16.init)
            let loc = uint32Property(service, key: "locationID")
            let ifNum = intProperty(service, key: "bInterfaceNumber").map(UInt8.init)

            if vid == vendorID && pid == productID && ifNum == interfaceNumber && (locationID == 0 || loc == locationID) {
                return service // Caller owns and releases
            }
            IOObjectRelease(service)
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
