import Darwin
import Foundation
import MideaKit

/// Searches the local network for ACs: a broadcast, plus a probe to every other host on this
/// Mac's subnet, since some modules answer only a probe sent to their own address.
enum DeviceSearch {
  // Subnets swept host by host: from a /22 (about a thousand hosts) down.
  static let sweptPrefixLengths: ClosedRange<Int> = 22...30

  /// Search for ACs, listening for `timeout` seconds.
  static func discover(timeout: TimeInterval = 4) async throws -> [DiscoveredDevice] {
    try await Discovery.discover(timeout: timeout, unicastTargets: localSubnetHosts())
  }

  /// Search for the AC `known` describes by its id, returning its credentials at the new
  /// address if it answers from somewhere else.
  static func relocate(_ known: DeviceCredentials, timeout: TimeInterval = 4) async
    -> DeviceCredentials?
  {
    guard let found = try? await discover(timeout: timeout),
      let match = found.first(where: { $0.id == known.id }),
      match.ip != known.ip || match.port != known.port
    else { return nil }
    return DeviceCredentials(
      name: known.name, id: known.id, ip: match.ip, port: match.port, version: known.version,
      token: known.token, key: known.key, serialNumber: known.serialNumber)
  }

  /// Every other host on the subnets of this Mac's Wi-Fi and Ethernet interfaces.
  static func localSubnetHosts() -> [String] {
    var interfacesPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfacesPointer) == 0 else { return [] }
    defer { freeifaddrs(interfacesPointer) }

    var ethernetNames: Set<String> = []
    var ipv4Interfaces: [(name: String, address: UInt32, prefixLength: Int)] = []
    var current = interfacesPointer
    while let interface = current {
      current = interface.pointee.ifa_next
      let flags = Int32(interface.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
        flags & IFF_POINTOPOINT == 0, let address = interface.pointee.ifa_addr
      else { continue }
      let name = String(cString: interface.pointee.ifa_name)
      switch Int32(address.pointee.sa_family) {
      case AF_LINK:
        // Wi-Fi reports itself as Ethernet too; bridges, tunnels and the like don't.
        if let data = interface.pointee.ifa_data,
          data.assumingMemoryBound(to: if_data.self).pointee.ifi_type == IFT_ETHER
        {
          ethernetNames.insert(name)
        }
      case AF_INET:
        guard let netmask = interface.pointee.ifa_netmask else { continue }
        ipv4Interfaces.append(
          (name, ipv4Value(address), ipv4Value(netmask).nonzeroBitCount))
      default:
        break
      }
    }
    var hosts: [String] = []
    var seen: Set<String> = []
    for (name, address, prefixLength) in ipv4Interfaces where ethernetNames.contains(name) {
      for host in subnetHosts(around: address, prefixLength: prefixLength)
      where seen.insert(host).inserted {
        hosts.append(host)
      }
    }
    return hosts
  }

  /// Every host on the subnet of `address` with `prefixLength` except `address` itself, or none
  /// when the prefix length is outside `sweptPrefixLengths`.
  static func subnetHosts(around address: UInt32, prefixLength: Int) -> [String] {
    guard sweptPrefixLengths.contains(prefixLength) else { return [] }
    let mask = UInt32.max << UInt32(32 - prefixLength)
    let base = address & mask
    let size = UInt32(1) << UInt32(32 - prefixLength)
    return (1..<(size - 1)).map { base + $0 }.filter { $0 != address }.map(dottedQuad)
  }

  /// The address in a `sockaddr` known to hold an IPv4 one, in host byte order.
  private static func ipv4Value(_ address: UnsafeMutablePointer<sockaddr>) -> UInt32 {
    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
      UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
    }
  }

  /// An IPv4 address in host byte order, written as four dotted numbers.
  private static func dottedQuad(_ address: UInt32) -> String {
    [24, 16, 8, 0].map { String((address >> UInt32($0)) & 0xFF) }.joined(separator: ".")
  }
}
