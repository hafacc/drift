import Testing

/// The subnet hosts a search probes one by one.
struct DeviceSearchTests {
  // 192.168.1.10
  private let address: UInt32 = 0xC0A8_010A

  @Test func sweepsEveryOtherHostOnTheSubnet() {
    let hosts = DeviceSearch.subnetHosts(around: address, prefixLength: 24)
    #expect(hosts.count == 253)
    #expect(hosts.first == "192.168.1.1")
    #expect(hosts.last == "192.168.1.254")
    #expect(!hosts.contains("192.168.1.10"))
    #expect(!hosts.contains("192.168.1.0"))
    #expect(!hosts.contains("192.168.1.255"))
  }

  @Test func sweepsTheLargestAllowedSubnet() {
    let hosts = DeviceSearch.subnetHosts(around: address, prefixLength: 22)
    #expect(hosts.count == 1021)
    #expect(hosts.first == "192.168.0.1")
    #expect(hosts.last == "192.168.3.254")
  }

  @Test func sweepsTheSmallestAllowedSubnet() {
    #expect(DeviceSearch.subnetHosts(around: address, prefixLength: 30) == ["192.168.1.9"])
  }

  @Test func skipsSubnetsOutsideTheLimits() {
    #expect(DeviceSearch.subnetHosts(around: address, prefixLength: 21).isEmpty)
    #expect(DeviceSearch.subnetHosts(around: address, prefixLength: 31).isEmpty)
  }
}
