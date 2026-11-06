import Foundation

/// One observation of an address reached through the selected interface.
public struct FoundHost: Sendable, Equatable {
    public var isLocal = false
    public var address: String
    public var mac: String
    public var interfaceName: String
    public var dnsName: String
    public var mdnsName: String
    public var smbName: String
    public var domain: String
    public var model: String

    public init(address: String, mac: String = "", interfaceName: String = "",
                dnsName: String = "", mdnsName: String = "", smbName: String = "",
                domain: String = "", model: String = "") {
        self.address = address
        self.mac = mac
        self.interfaceName = interfaceName
        self.dnsName = dnsName
        self.mdnsName = mdnsName
        self.smbName = smbName
        self.domain = domain
        self.model = model
    }
}
