import { connection } from '@kit.NetworkKit';

/** First non-loopback IPv4 address on one network, or '' when there is none. */
function firstIpv4(props: connection.ConnectionProperties): string {
  if (props === null || props === undefined || props.linkAddresses === undefined) {
    return '';
  }
  const links: connection.LinkAddress[] = props.linkAddresses;
  for (let i = 0; i < links.length; i++) {
    const addr: connection.NetAddress = links[i].address;
    if (addr !== undefined && addr !== null && addr.family === 1 &&
      addr.address !== '127.0.0.1' && addr.address !== '0.0.0.0') {
      return addr.address;
    }
  }
  return '';
}

function isWifiNet(caps: connection.NetCapabilities): boolean {
  if (caps === null || caps === undefined || caps.bearerTypes === undefined) {
    return false;
  }
  const types: connection.NetBearType[] = caps.bearerTypes;
  for (let i = 0; i < types.length; i++) {
    if (types[i] === connection.NetBearType.BEARER_WIFI) {
      return true;
    }
  }
  return false;
}

/**
 * Best effort IPv4 lookup.
 *
 * getDefaultNet() alone is not enough on a wearable: when several networks are
 * up (Bluetooth tethering, Wi-Fi, cellular) the default net may carry no IPv4
 * address, which surfaced as 0.0.0.0 on screen. So walk every network and
 * prefer the Wi-Fi one, since that is the interface a phone can reach.
 */
export async function getLocalIpv4(): Promise<string> {
  let fallback: string = '';
  try {
    const nets: connection.NetHandle[] = await connection.getAllNets();
    for (let i = 0; i < nets.length; i++) {
      const net: connection.NetHandle = nets[i];
      let ip: string = '';
      try {
        const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
        ip = firstIpv4(props);
      } catch (e) {
        continue;
      }
      if (ip.length === 0) {
        continue;
      }
      let wifi: boolean = false;
      try {
        const caps: connection.NetCapabilities = await connection.getNetCapabilities(net);
        wifi = isWifiNet(caps);
      } catch (e) {
        wifi = false;
      }
      if (wifi) {
        return ip;
      }
      if (fallback.length === 0) {
        fallback = ip;
      }
    }
  } catch (e) {
    // Missing GET_NETWORK_INFO or no active network.
  }
  return fallback.length > 0 ? fallback : '0.0.0.0';
}
