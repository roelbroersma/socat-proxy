#!/bin/sh

# FUNCTION TO CHECK FOR ROOT PRIVILEGES OR CAP_NET_ADMIN REQUIRED CAPABILITIES
check_root_and_capabilities() {
   # CHECK IF USER IS ROOT
   if [ "$(id -u)" -ne 0 ]; then
     return 1 # RETURN 1 IF USER IS NOT ROOT
   fi
   
   # CHECK IF THE 'CAPSH' COMMAND IS AVAILABLE
   if ! command -v capsh >/dev/null 2>&1; then
     echo "WARNING: 'capsh' command not found. Unable to check capabilities." >&2
     return 1
   fi
   
   # CHECK IF THE USER HAS CAP_NET_ADMIN CAPABILITY
   if capsh --print | grep -q '!cap_net_admin'; then
     return 1 # RETURN 1 IF USER DOES NOT HAVE CAP_NET_ADMIN CAPABILITY
   fi

   # IF USER IS ROOT AND HAS CAP_NET_ADMIN CAPABILITY IS PRESENT, RETURN 0
   return 0
}

# FUNCTION WHICH DISPLAY THE USAGE (DOCKER AND COMMAND LINE)
display_usage() {
   echo ""
   echo "Use docker with environment variables: MULTICAST_ADDRESS, MULTICAST_PORT, FROM_IP, TO_ADDRESS, VIA_PORT and optionally: DEBUG, DEBUG_PACKET and WATCHDOG."
   echo "or use the following command line options:"
   echo ""
   echo "Usage:"
   echo "./proxy.sh --multicast_address=224.0.0.251 --multicast_port=5353 --from_ip=192.168.0.1 --to_address=10.0.0.1 --via_port=5354 --debug=2 --debug_packet=2 --watchdog=10"
   echo ""
   echo "OPTIONS (mandatory)"
   echo " --multicast_address=  The multicast IP addres you want to listen/capture"
   echo " --multicast_port=     The multicast port you wan to listen/capture"
   echo " --from_ip=            The IP address (of your local interface) on which you expect the multicasts"
   echo " --to_address=         The IP address to which you want to send/forward the multicasts"
   echo " --via_port=           The udp port to use when sending it to the destination IP address, use another port than multicast_port! (tip: 1 number higher)"
   echo ""
   echo "OPTIONS (optional)"
   echo " --ttl=		default=1, Time-To-Live of forwarded/proxied packets"
   echo " --debug=              1=only errors, 2=errors+warnings, 3=errors+warnings+info, 4=errors+warnings+info+debug"
   echo " --debug_packet=       1=basic tcpdump output, 2=verbose tcpdump output, 3=tcpdump verbose + packet payload in ASCI (handy for MDNS/SSDP!)"
   echo " --watchdog=           After this many seconds of inactivity, the process will restart internally (default=3)"
   echo ""
   echo ""
   echo "Docker example:"
   echo "  docker run -e MULTICAST_ADDRESS=<value> -e MULTICAST_PORT=<value> -e FROM_IP=<value> -e TO_ADDRESS=<value> -e VIA_PORT=<value> roeller/socat-proxy:latest"
}

# PARSE COMMAND LINE ARGUMENTS (IF STARTED FROM COMMAND LINE, OTHERWISE TAKE THE ENVIRONMENT VARIABLES BECAUSE PROBABLY USED AS DOCKER CONTAINER)
while [ $# -gt 0 ]; do
  case "$1" in
    --*=*)
      key="${1%%=*}"  # EXTRACT THE OPTION PART BEFORE '='
      value="${1#*=}" # EXTRACT THE OPTION PART AFTER '='
      case "$key" in
        --multicast_address)
          MULTICAST_ADDRESS="$value"
          ;;
        --multicast_port)
          MULTICAST_PORT="$value"
          ;;
        --via_port)
          VIA_PORT="$value"
          ;;
        --from_ip)
          FROM_IP="$value"
          ;;
        --to_address)
          TO_ADDRESS="$value"
          ;;
	--ttl)
 	  TTL=="$value"
    	  ;;
        --debug)
          DEBUG="$value"
          ;;
        --debug_packet)
          DEBUG_PACKET="$value"
          ;;
        --watchdog)
          WATCHDOG="$value"
          ;;
        *)
          echo "ERROR: Unknown option: $1"
	  display_usage
          exit 1
          ;;
      esac
      shift
      ;;
    *)
      echo "ERROR: Unknown option: $1"
      display_usage
      exit 1
      ;;
  esac
done

# ENABLE DEBUGGING IN SOCAT STYLE, USING (MULTIPLE) -D
SOCAT_DEBUG_LEVEL=""
if [ -n "$DEBUG" ]; then
  case "$DEBUG" in
    1)
      SOCAT_DEBUG_LEVEL="-d"
      ;;
    2)
      SOCAT_DEBUG_LEVEL="-d -d"
      ;;
    3)
      SOCAT_DEBUG_LEVEL="-d -d -d"
      ;;
    4)
      SOCAT_DEBUG_LEVEL="-d -d -d -d"
      ;;
    *)
      SOCAT_DEBUG_LEVEL=""
      ;;
  esac
fi

# ENABLE DEBUG PACKETS WITH TCPDUMP
if [ -n "$DEBUG_PACKET" ]; then
  case "$DEBUG_PACKET" in
    1)
      TCPDUMP_OPTIONS=""
      ;;
    2)
      TCPDUMP_OPTIONS="-vv"
      ;;
    3)
      TCPDUMP_OPTIONS="-vv -A"
      ;;
    *)
      TCPDUMP_OPTIONS=""
      ;;
  esac
fi

# CHECK IF MULTICAST_PORT IS GIVEN
if [ -z "$MULTICAST_ADDRESS" ]; then
  echo "ERROR: Please, specify for which MULTICAST_ADDRESS you want to run this proxy. I.e. for MDNS the MULTICAST_ADDRESS is 224.0.0.251."
  display_usage
  exit 1
fi

# CHECK IF MULTICAST_PORT IS GIVEN
if [ -z "$MULTICAST_PORT" ]; then
  echo "ERROR: Please, specify for which MULTICAST_PORT you want to run this proxy. I.e. for MDNS, the MULTICAST_PORT is 5353."
  display_usage
  exit 1
fi

# CHECK IF VIA_PORT IS GIVEN
if [ -z "$VIA_PORT" ]; then
  echo "ERROR: Please, specify the VIA_PORT, which is the port you use between sender and receiver."
  display_usage
  exit 1
fi

# CHECK IF FROM_IP IS GIVEN
if [ -z "$FROM_IP" ]; then
  echo "ERROR: Please, specify the FROM_IP on which you expect this multicast to arrive, we will join this IP address to the multicast group. I.e.: 192.168.0.10."
  display_usage
  exit 1;
fi

# CHECK IF TO_ADDRESS IS GIVEN
if [ -z "$TO_ADDRESS" ]; then
  echo "ERROR: Please, specify the TO_ADDRESS, which is the other Proxy instance to which we need to send the (encapsulated) multicasts to. I.e. 145.25.27.10"
  display_usage
  exit 1
fi

check_root_and_capabilities
if [ $? -eq 1 ]; then
  echo "############################ WARNING #####################################"
  echo "### This script must be run as root which can achieved by running      ###"
  echo "### this container in privileged mode or by running it with            ###"
  echo "### CAP_NET_ADMIN capability.                                          ###"
  echo "### We will continue but host routes and loop protection will probably ###"
  echo "### not set correctly.						       ###"
  echo "##########################################################################"
fi

# SET SOCAT TIMEOUT/WATCHDOG (IT QUITS AFTER THIS SECONDS OF INACTIVITY)
SOCAT_TIMEOUT=3
if [ -n "$WATCHDOG" ]; then
	SOCAT_TIMEOUT=$WATCHDOG
fi
echo "WATCHDOG timeout set to $SOCAT_TIMEOUT seconds."

# SET TTL (DEFAULT=1)
if [ -z "$TTL" ]; then
  TTL=1
fi

# FUNCTION TO START THE SENDER. LISTEN TO MULTICASTS AND FORWARD THEM TO ANOTHER IP ADDRESS (WHICH RECEIVES THEM AND SENDS THEM OUT AS MULTICASTS).
start_sender() {
  echo "Starting the sender..."
  while true; do
     #socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECV:$MULTICAST_PORT,bind=$MULTICAST_ADDRESS,ip-add-membership=$MULTICAST_ADDRESS:$FROM_IP,reuseaddr,reuseport,ip-multicast-loop=0 UDP4-SENDTO:$TO_ADDRESS:$VIA_PORT > >(tee -a /dev/stdout) 2> >(tee -a /dev/stderr)
     socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECV:$MULTICAST_PORT,bind=$MULTICAST_ADDRESS,ip-add-membership=$MULTICAST_ADDRESS:$FROM_IP,reuseaddr,reuseport,ip-multicast-loop=0 UDP4-SENDTO:$TO_ADDRESS:$VIA_PORT
     echo ""
     echo "Sender process stopped, restarting..."
     echo ""
  done
}

# FUNCTION TO START THE RECEIVER. LISTEN TO UDP PACKETS FROM THE SENDER (ADDRESSES TO THE SAME PORT AS THE MULTICAST PORT) AND SENDS THEM OUT AS MULTICASTS.
start_receiver() {
  echo "Starting the receiver..."
  while true; do
     socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECVFROM:$VIA_PORT,bind=$FROM_IP,reuseaddr,reuseport,fork,ip-multicast-loop=0 UDP4-SENDTO:$MULTICAST_ADDRESS:$MULTICAST_PORT,ttl=$TTL
     echo ""
     echo "Receiver process stopped, restarting..."
     echo ""
  done
}

# FUNCTION TO REMOVE THE ROUTES THAT WE ADDED DURING OUR STARTUP (NEEDED BECAUSE WE ADD ROUTES TO THE NETWORK STACK OF THE HOST)
remove_routes() {
  echo ""
  echo "Removing routes..."
  echo ""
  # DO THIS IN A WHILE SO WE REMOVE ALL THE ROUTES THAT MATCH THIS ONE (MAYBE SOME WHERE LEFT WHEN THE CONTAINER DIDNT PROPERLY SHUT DOWN)
  while ip route show | grep -q "$MULTICAST_ADDRESS via $FROM_IP"; do
    ip route del $MULTICAST_ADDRESS/32 via $FROM_IP
  done
}

# FUNCTION TO REMOVE THE IPTABLES RULES THAT WE ADDED DURING OUR STARTUP (NEEDED FOR LOOP PROTECTION)
remove_iptables() {
  echo ""
  echo "Removing IPTables rules..."
  echo ""
  # DO THIS IN A WHILE SO WE REMOVE ALL THE RULES THAT MATCH THIS ONE (MAYBE SOME WHERE LEFT WHEN THE CONTAINER DIDNT PROPERLY SHUT DOWN)
  while iptables -C INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP 2>/dev/null; do
    iptables -D INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP
  done
}

# BECAUSE THE RECEIVER MIGHT HAVE MULTIPLE INTERFACES, WE NEED TO MAKE SURE TO ROUTE OUT THE MULTICAST VIA THE CORRECT INTERFACE (WHICH IS THE $FROM_IP)
# (NOTE THAT THIS ROUTE WILL BE APPLIED TO THE WHOLE HOST BECAUSE IT USES THE HOST NETWORK INTERFACE)
echo "Adding route to $MULTICAST_ADDRESS via $FROM_IP..."
# ONLY ADD IF THE ROUTE DOESNT EXISTS YET
if ! ip route show | grep -q "$MULTICAST_ADDRESS via $FROM_IP"; then
  ip route add $MULTICAST_ADDRESS/32 via $FROM_IP
fi

# ADDING IPTABLES FOR EXTRA LOOP PROTECTION, THE ip-multicast-loop=0 FROM SOCAT DOESNT WORK, PROBABLY BECAUSE WE USE MULTIPLE SOCAT PROCESSES AND THEY ARE NOT AWARE OF EACH OTHER
echo "Adding IPTables loop protection to refuse incomming multicast packets to $MULTICAST_ADDRESS:$MULTICAST_PORT with SOURCE: $FROM_IP."
# ONLY ADD IF THE RULE DOESNT EXISTS YET
if ! iptables -C INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP 2>/dev/null; then
    iptables -A INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP
else
   echo "Not adding iptables rule because it already exists."
fi

# REMOVE THE ROUTES WHEN THIS SCRIPT OR DOCKER CONTAINER STOPS
trap remove_routes EXIT TERM
trap remove_iptables EXIT TERM

# START SENDER AND RECEIVER
start_sender &
start_receiver &

# START TCPDUMP (IF DEBUG_PACKET) IS ENABLED
if [ -n "$DEBUG_PACKET" ]; then
   tcpdump -n -i any '((dst host '"$MULTICAST_ADDRESS"' and udp dst port '"$MULTICAST_PORT"') or (dst host '"$TO_ADDRESS"' and udp dst port '"$VIA_PORT"'))' $TCPDUMP_OPTIONS &
fi

# KEEP THE SCRIPT ACTIVE BY USING WAIT
while true; do
  wait
done
