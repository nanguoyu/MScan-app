import Darwin
import Foundation

// UPnP speakers, home gateways and media players publish their model in a
// description document. Read only a numeric HTTP location on the responding
// device. Keep both datagrams and TCP traffic on the originally selected link.
enum UPnPModel {
    static func lookup(_ target: ProbeEndpoint, address: String) async -> String {
        let bare = String(address.prefix(while: { $0 != "%" }))
        let authority = target.family == AF_INET6 ? "[\(bare)]" : bare
        let request = "M-SEARCH * HTTP/1.1\r\nHOST: \(authority):1900\r\nMAN: \"ssdp:discover\"\r\nST: upnp:rootdevice\r\nMX: 1\r\n\r\n"
        guard let data = await target.requestUDP(Array(request.utf8), port: 1900, timeout: 750),
              let location = location(in: data, expectedHost: bare),
              let body = await fetch(location: location, target: target) else { return "" }
        return model(in: body)
    }

    static func location(in data: [UInt8], expectedHost: String) -> URLComponents? {
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        guard let first = lines.first, first.uppercased().hasPrefix("HTTP/1.1 200 ") else { return nil }
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":"), line[..<separator].lowercased() == "location" else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard let url = URLComponents(string: value), url.scheme?.lowercased() == "http",
                  url.user == nil, url.password == nil, url.fragment == nil, let host = url.host else { return nil }
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: "%").first.map(String.init) ?? ""
            // Use the already-resolved, bound socket for the request even if the
            // advertised spelling differs. Never resolve a returned hostname.
            guard let announced = try? ProbeEndpoint(address: bare, interfaceName: ""),
                  let expected = try? ProbeEndpoint(address: expectedHost, interfaceName: ""),
                  announced.family == expected.family,
                  withUnsafeBytes(of: announced.storage, { lhs in
                      withUnsafeBytes(of: expected.storage, { rhs in lhs.elementsEqual(rhs) })
                  }), (1...65535).contains(url.port ?? 80) else { return nil }
            return url
        }
        return nil
    }

    private static func fetch(location: URLComponents, target: ProbeEndpoint) async -> Data? {
        let port = UInt16(location.port ?? 80)
        guard let fd = await target.openTCP(port, timeout: 500) else { return nil }
        defer { Darwin.close(fd) }
        var path = location.percentEncodedPath.isEmpty ? "/" : location.percentEncodedPath
        if let query = location.percentEncodedQuery { path += "?" + query }
        guard path.hasPrefix("/"), path.utf8.count <= 4096, let host = location.percentEncodedHost else { return nil }
        let request = Array("GET \(path) HTTP/1.0\r\nHost: \(host):\(port)\r\nConnection: close\r\n\r\n".utf8)
        let sent = request.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == request.count else { return nil }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_200_000_000
        while bytes.count < 128 * 1024 && DispatchTime.now().uptimeNanoseconds < deadline {
            guard await ProbeEndpoint.wait(fd: fd, events: Int16(POLLIN), milliseconds: 400) else { break }
            let size = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if size <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(size))
        }
        guard !Task.isCancelled, let split = bytes.range(of: Data("\r\n\r\n".utf8)),
              let headers = String(data: bytes[..<split.lowerBound], encoding: .isoLatin1),
              headers.hasPrefix("HTTP/1.0 200 ") || headers.hasPrefix("HTTP/1.1 200 ") else { return nil }
        return Data(bytes[split.upperBound...])
    }

    static func model(in xml: Data) -> String {
        guard let text = String(data: xml, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { return "" }
        let delegate = DeviceDescription()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return "" }
        let name = delegate.values["modelName"] ?? ""
        let number = delegate.values["modelNumber"] ?? ""
        if name.isEmpty { return number }
        return number.isEmpty || name.localizedCaseInsensitiveContains(number) ? name : "\(name) (\(number))"
    }

    private final class DeviceDescription: NSObject, XMLParserDelegate {
        var stack: [String] = []
        var text = ""
        var values: [String: String] = [:]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            stack.append(elementName.components(separatedBy: ":").last ?? elementName)
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if stack.count == 3, stack[0] == "root", stack[1] == "device",
               ["modelName", "modelNumber"].contains(stack[2]) {
                values[stack[2]] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            _ = stack.popLast()
            text = ""
        }
    }
}
