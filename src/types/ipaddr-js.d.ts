declare module "ipaddr.js" {
  export type IPv4Range =
    | "unicast"
    | "unspecified"
    | "broadcast"
    | "multicast"
    | "linkLocal"
    | "loopback"
    | "carrierGradeNat"
    | "private"
    | "reserved";

  export type IPv6Range =
    | "unicast"
    | "unspecified"
    | "linkLocal"
    | "multicast"
    | "loopback"
    | "uniqueLocal"
    | "ipv4Mapped"
    | "rfc6145"
    | "rfc6052"
    | "6to4"
    | "teredo"
    | "reserved";

  export interface IPv4 {
    octets: number[];
    kind(): "ipv4";
    match(addr: IPv4, bits: number): boolean;
    match(mask: [IPv4, number]): boolean;
    range(): IPv4Range;
    toString(): string;
    toIPv4MappedAddress(): IPv6;
  }

  export interface IPv6 {
    parts: number[];
    zoneId?: string;
    isIPv4MappedAddress(): boolean;
    kind(): "ipv6";
    match(addr: IPv6, bits: number): boolean;
    match(mask: [IPv6, number]): boolean;
    range(): IPv6Range;
    toString(): string;
    toIPv4Address(): IPv4;
  }

  export interface IpAddrApi {
    IPv4: {
      isValid(addr: string): boolean;
      isValidFourPartDecimal(addr: string): boolean;
      parse(addr: string): IPv4;
    };
    IPv6: {
      isValid(addr: string): boolean;
      parse(addr: string): IPv6;
    };
    isValid(addr: string): boolean;
    parse(addr: string): IPv4 | IPv6;
    parseCIDR(cidr: string): [IPv4 | IPv6, number];
  }

  const ipaddr: IpAddrApi;
  export default ipaddr;
}
