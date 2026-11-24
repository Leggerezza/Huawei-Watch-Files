import { connection } from '@kit.NetworkKit';

/**
 * Best effort IPv4 lookup for the interface carrying the default route.
 * On the watch this is normally the Wi-Fi address the phone will connect to.
 */
export async function getLocalIpv4(): Promise<string> {
  try {
    const net: connection.NetHandle = await connection.getDefaultNet();
    if (net === null || net === undefined || net.netId === 0) {
      return '0.0.0.0';
    }
    const props: connection.ConnectionProperties = await connection.getConnectionProperties(net);
    if (props === null || props === undefined || props.linkAddresses === undefined) {
      return '0.0.0.0';
    }
    const links: connection.LinkAddress[] = props.linkAddresses;
    for (let i = 0; i < links.length; i++) {
      const addr: connection.NetAddress = links[i].address;
      if (addr !== undefined && addr !== null && addr.family === 1 && addr.address !== '127.0.0.1') {
        return addr.address;
      }
    }
  } catch (e) {
    // Missing GET_NETWORK_INFO or no active network: caller shows a placeholder.
  }
  return '0.0.0.0';
}
