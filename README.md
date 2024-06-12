# Socat Proxy

Socat Proxy is the ultimate multicast proxy for forwarding MDNS, KNX, and other multicast protocols to another VLAN, (VPN) site, or network.

## Table of Contents

1. [Requirements](#requirements)
2. [Docker](#docker)
3. [Environment Variables](#environment-variables)
4. [Usage on Linux shell](#usage)
5. [Notes](#notes)

## Requirements

- **Docker** with root privileges or CAP_NET_ADMIN capabilities (for configuring network settings);

or
- When using a **Linux operating system**:
  - Linux operating system (or similar)
  - Bash shell
  - Socat and Tcpdump binaries

## Docker
Socat Proxy can be run as a Docker container. You can pull the Docker image from Docker Hub:

`docker pull roeller/socat-proxy:latest`

Then, run the container with the appropriate environment variables:

```bash
docker run -e MULTICAST_ADDRESS=<value> -e MULTICAST_PORT=<value> -e VIA_PORT=<value> -e FROM_IP=<value> -e TO_ADDRESS=<value> roeller/socat-proxy:latest
```

## Environment Variables

Ensure the following required environment variables are set before starting Socat Proxy:

* MULTICAST_ADDRESS: The multicast IP address you want to listen on.
* MULTICAST_PORT: The port you want to listen for multicast traffic on.
* FROM_IP: The IP address on which you expect to receive the multicast traffic.
* VIA_PORT: The port you want to forward the received multicast traffic to.
* TO_ADDRESS: The IP address to which you want to forward the multicast traffic.

The following environment variables are optional:

* DEBUG: Can be 1 (=error), 2 (=error+warning), 3(=error+warning+info), 4=(error+warning+info+debugging)
* DEBUG_PACKET: Can be 1 (=just tcpdump of the packets received by the proxy and sended out by the proxy), 2 (=some verbose info), 3 (=also packet info in text, handy for MDNS and SSDP!)
* WATCHDOG: Number of seconds of inactivity before the proxy automatically restarts it's process (default=3)

## Usage (from Bash shell in Linux operating system)

Before using Socat Proxy, ensure you meet the following requirements:

1. Install the necessary tools, such as `socat` and `tcpdump`, on the system where you intend to use Socat Proxy.

2. Start the script by executing the executable file:

```bash
./proxy.sh --multicast_address=224.0.0.251 --multicast_port=5353 --from_ip=192.168.0.1 --via_port=5354 --to_address=10.0.0.1 --debug=2 --debug_packet=2 --watchdog=10
```

## Notes
* This script must be run with root privileges or the correct CAP_NET_ADMIN capabilities to configure network settings.

* Make sure to set up the required environment variables correctly for the script to function as expected.

* For additional debugging or packet logging, you can adjust the environment variables DEBUG and DEBUG_PACKET.

* There is a known issue with some MDNS traffic on Synology NAS (at least DS1823XS, running DSM8). Some MDNS packets are not captured by the proxy and so, not forwarded to the other IP. It looks like this happens with ttl=255 packets.
