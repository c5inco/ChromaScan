import Foundation

enum ESCLXMLBuilder {
    static func buildScanSettingsXML(for request: ScanJobRequest, minimal: Bool = false) -> String {
        let intentValue = request.isPreview ? "Preview" : request.intent.rawValue
        let formatValue = request.transferFormat.rawValue
        var toneXML = ""
        if let brightness = request.brightness {
            toneXML += "\n  <scan:Brightness>\(brightness)</scan:Brightness>"
        }
        if let contrast = request.contrast {
            toneXML += "\n  <scan:Contrast>\(contrast)</scan:Contrast>"
        }

        // HP eSCL printers (e.g. OfficeJet 3830) encode image/jpeg as YCC and reject ColorSpace=sRGB with 409 Conflict.
        let colorSpaceXML: String
        if !minimal && request.colorMode == .rgb24 && request.transferFormat == .rawOctetStream {
            colorSpaceXML = "\n  <scan:ColorSpace>sRGB</scan:ColorSpace>"
        } else {
            colorSpaceXML = ""
        }

        let contentTypeXML = minimal ? "" : "\n  <pwg:ContentType>\(request.intent.contentType)</pwg:ContentType>"
        let formatExtXML = minimal ? "" : "\n  <scan:DocumentFormatExt>\(formatValue)</scan:DocumentFormatExt>"

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <scan:ScanSettings xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
          <pwg:Version>\(request.version)</pwg:Version>
          <scan:Intent>\(intentValue)</scan:Intent>
          <pwg:ScanRegions>
            <pwg:ScanRegion>
              <pwg:Height>\(request.region.height)</pwg:Height>
              <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
              <pwg:Width>\(request.region.width)</pwg:Width>
              <pwg:XOffset>\(request.region.xOffset)</pwg:XOffset>
              <pwg:YOffset>\(request.region.yOffset)</pwg:YOffset>
            </pwg:ScanRegion>
          </pwg:ScanRegions>
          <pwg:InputSource>\(request.inputSource.rawValue)</pwg:InputSource>
          <scan:ColorMode>\(request.colorMode.rawValue)</scan:ColorMode>\(colorSpaceXML)\(contentTypeXML)
          <pwg:DocumentFormat>\(formatValue)</pwg:DocumentFormat>\(formatExtXML)
          <scan:XResolution>\(request.resolution)</scan:XResolution>
          <scan:YResolution>\(request.resolution)</scan:YResolution>\(toneXML)
        </scan:ScanSettings>
        """
    }
}

enum ESCLXMLParserError: Error, LocalizedError {
    case invalidXML(String)

    var errorDescription: String? {
        switch self {
        case .invalidXML(let msg): return "Failed to parse eSCL XML: \(msg)"
        }
    }
}

// MARK: - ScannerCapabilities Parser

final class CapabilitiesXMLParser: NSObject, XMLParserDelegate {
    private var elementStack: [String] = []
    private var currentText = ""

    private var version = "2.5"
    private var makeAndModel = "eSCL Scanner"
    private var serialNumber: String?

    private struct MutableInputCaps {
        var minWidth = 8
        var maxWidth = 2550
        var minHeight = 8
        var maxHeight = 3300
        var discreteResolutions: Set<Int> = []
        var colorModes: Set<String> = []
        var documentFormats: Set<String> = []
        var intents: Set<String> = []
        var contentTypes: Set<String> = []
        var maxOpticalResolution = 600
        var currentXRes: Int?
        var currentYRes: Int?

        func build() -> ScannerCapabilities.InputSourceCaps {
            let sortedRes = discreteResolutions.sorted()
            let maxOpt = max(maxOpticalResolution, sortedRes.last ?? 300)
            return ScannerCapabilities.InputSourceCaps(
                minWidth: minWidth,
                maxWidth: maxWidth,
                minHeight: minHeight,
                maxHeight: maxHeight,
                discreteResolutions: sortedRes.isEmpty ? [75, 100, 200, 300, 600] : sortedRes,
                colorModes: Array(colorModes).sorted(),
                documentFormats: Array(documentFormats).sorted(),
                intents: Array(intents).sorted(),
                contentTypes: Array(contentTypes).sorted(),
                maxOpticalResolution: maxOpt
            )
        }
    }

    private struct MutableToneRange {
        var min = 0
        var max = 2000
        var normal = 1000
        var step = 1
        func build() -> ScannerCapabilities.ToneRange {
            ScannerCapabilities.ToneRange(min: min, max: max, normal: normal, step: step)
        }
    }

    private var platenCaps: MutableInputCaps?
    private var adfCaps: MutableInputCaps?
    private var brightness: MutableToneRange?
    private var contrast: MutableToneRange?

    private enum Section {
        case none, platen, adf, brightness, contrast
    }
    private var currentSection: Section = .none

    static func parse(_ data: Data) throws -> ScannerCapabilities {
        let handler = CapabilitiesXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = handler
        guard parser.parse() else {
            throw ESCLXMLParserError.invalidXML(parser.parserError?.localizedDescription ?? "Unknown XML error")
        }
        return ScannerCapabilities(
            version: handler.version,
            makeAndModel: handler.makeAndModel,
            serialNumber: handler.serialNumber,
            platen: handler.platenCaps?.build(),
            adf: handler.adfCaps?.build(),
            brightnessRange: handler.brightness?.build(),
            contrastRange: handler.contrast?.build()
        )
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = localName(elementName)
        elementStack.append(name)
        currentText = ""

        switch name {
        case "PlatenInputCaps":
            currentSection = .platen
            if platenCaps == nil { platenCaps = MutableInputCaps() }
        case "AdfSimplexInputCaps":
            currentSection = .adf
            if adfCaps == nil { adfCaps = MutableInputCaps() }
        case "BrightnessSupport":
            currentSection = .brightness
            brightness = MutableToneRange()
        case "ContrastSupport":
            currentSection = .contrast
            contrast = MutableToneRange()
        case "DiscreteResolution":
            if currentSection == .platen {
                platenCaps?.currentXRes = nil
                platenCaps?.currentYRes = nil
            } else if currentSection == .adf {
                adfCaps?.currentXRes = nil
                adfCaps?.currentYRes = nil
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch currentSection {
        case .none:
            switch name {
            case "Version": if !text.isEmpty { version = text }
            case "MakeAndModel": if !text.isEmpty { makeAndModel = text }
            case "SerialNumber": if !text.isEmpty { serialNumber = text }
            default: break
            }

        case .platen:
            updateInputCaps(&platenCaps, element: name, value: text)
            if name == "PlatenInputCaps" { currentSection = .none }

        case .adf:
            updateInputCaps(&adfCaps, element: name, value: text)
            if name == "AdfSimplexInputCaps" { currentSection = .none }

        case .brightness:
            updateToneRange(&brightness, element: name, value: text)
            if name == "BrightnessSupport" { currentSection = .none }

        case .contrast:
            updateToneRange(&contrast, element: name, value: text)
            if name == "ContrastSupport" { currentSection = .none }
        }

        if !elementStack.isEmpty { elementStack.removeLast() }
        currentText = ""
    }

    private func updateInputCaps(_ caps: inout MutableInputCaps?, element: String, value: String) {
        guard caps != nil else { return }
        switch element {
        case "MinWidth": if let v = Int(value) { caps?.minWidth = v }
        case "MaxWidth": if let v = Int(value) { caps?.maxWidth = v }
        case "MinHeight": if let v = Int(value) { caps?.minHeight = v }
        case "MaxHeight": if let v = Int(value) { caps?.maxHeight = v }
        case "XResolution": if let v = Int(value) { caps?.currentXRes = v }
        case "YResolution": if let v = Int(value) { caps?.currentYRes = v }
        case "DiscreteResolution":
            if let x = caps?.currentXRes, let y = caps?.currentYRes, x == y {
                caps?.discreteResolutions.insert(x)
            }
        case "ColorMode": if !value.isEmpty { caps?.colorModes.insert(value) }
        case "DocumentFormat", "DocumentFormatExt": if !value.isEmpty { caps?.documentFormats.insert(value) }
        case "Intent": if !value.isEmpty { caps?.intents.insert(value) }
        case "ContentType": if !value.isEmpty { caps?.contentTypes.insert(value) }
        case "MaxOpticalXResolution": if let v = Int(value) { caps?.maxOpticalResolution = v }
        default: break
        }
    }

    private func updateToneRange(_ range: inout MutableToneRange?, element: String, value: String) {
        guard let v = Int(value) else { return }
        switch element {
        case "Min": range?.min = v
        case "Max": range?.max = v
        case "Normal": range?.normal = v
        case "Step": range?.step = v
        default: break
        }
    }
}

// MARK: - ScannerStatus Parser

final class StatusXMLParser: NSObject, XMLParserDelegate {
    private var currentText = ""
    private var state: String?
    private var adfState: String?
    private var inJobs = false

    static func parse(_ data: Data) throws -> ScannerStatus {
        let handler = StatusXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = handler
        guard parser.parse() else {
            throw ESCLXMLParserError.invalidXML(parser.parserError?.localizedDescription ?? "Unknown XML error")
        }
        return ScannerStatus(state: handler.state ?? "Unknown", adfState: handler.adfState)
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") { return String(name[name.index(after: idx)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        if localName(elementName) == "Jobs" { inJobs = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "Jobs" { inJobs = false }
        if !inJobs {
            if name == "State", state == nil, !text.isEmpty { state = text }
            if name == "AdfState", !text.isEmpty { adfState = text }
        }
        currentText = ""
    }
}

// MARK: - ScanImageInfo Parser

final class ScanImageInfoXMLParser: NSObject, XMLParserDelegate {
    private var currentText = ""
    private var jobUUID: String?
    private var actualWidth: Int?
    private var actualHeight: Int?
    private var actualBytesPerLine: Int?

    static func parse(_ data: Data) throws -> ScanImageInfo {
        let handler = ScanImageInfoXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = handler
        guard parser.parse(),
              let w = handler.actualWidth,
              let h = handler.actualHeight,
              let bpl = handler.actualBytesPerLine else {
            throw ESCLXMLParserError.invalidXML("Missing ScanImageInfo fields")
        }
        return ScanImageInfo(jobUUID: handler.jobUUID, actualWidth: w, actualHeight: h, actualBytesPerLine: bpl)
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") { return String(name[name.index(after: idx)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "JobUuid": if !text.isEmpty { jobUUID = text }
        case "ActualWidth": actualWidth = Int(text)
        case "ActualHeight": actualHeight = Int(text)
        case "ActualBytesPerLine": actualBytesPerLine = Int(text)
        default: break
        }
        currentText = ""
    }
}
