#!/bin/sh

# FUNCTION TO CHECK FOR ROOT PRIVILEGES OR CAP_NET_ADMIN REQUIRED CAPABILITIES
check_root_and_capabilities() {
   if [ "$(id -u)" -ne 0 ] || ! capsh --print | grep -q 'cap_net_admin'; then
     return 1
   fi
   return 0
}

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

SOCAT_TIMEOUT=3
if [ -n "$WATCHDOG" ]; then
	SOCAT_TIMEOUT=$WATCHDOG
fi
echo "WATCHDOG timeout set to $SOCAT_TIMEOUT seconds."

# FUNCTION TO START THE SENDER. LISTEN TO MULTICASTS AND FORWARD THEM TO ANOTHER IP ADDRESS (WHICH RECEIVES THEM AND SENDS THEM OUT AS MULTICASTS).
start_sender() {
  echo "Starting the sender..."
  while true; do
     socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECV:$MULTICAST_PORT,bind=$MULTICAST_ADDRESS,ip-add-membership=$MULTICAST_ADDRESS:$FROM_IP,reuseaddr,reuseport,ip-multicast-loop=0 UDP4-SENDTO:$TO_ADDRESS:$VIA_PORT > >(tee -a /dev/stdout) 2> >(tee -a /dev/stderr)
     echo "Sender process stopped, restarting..."
  done
}

# FUNCTION TO START THE RECEIVER. LISTEN TO UDP PACKETS FROM THE SENDER (ADDRESSES TO THE SAME PORT AS THE MULTICAST PORT) AND SENDS THEM OUT AS MULTICASTS.
start_receiver() {
  echo "Starting the receiver..."
  while true; do
     socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECVFROM:$VIA_PORT,bind=$FROM_IP,reuseaddr,reuseport,fork,ip-multicast-loop=0 UDP4-SENDTO:$MULTICAST_ADDRESS:$MULTICAST_PORT > >(tee -a /dev/stdout) 2> >(tee -a /dev/stderr)
     echo "Receiver process stopped, restarting..."
  done
}

# FUNCTION TO REMOVE THE ROUTES THAT WE ADDED DURING OUR STARTUP (NEEDED BECAUSE WE ADD ROUTES TO THE NETWORK STACK OF THE HOST)
remove_routes() {
  echo "Removing routes..."
  # DO THIS IN A WHILE SO WE REMOVE ALL THE ROUTES THAT MATCH THIS ONE (MAYBE SOME WHERE LEFT WHEN THE CONTAINER DIDNT PROPERLY SHUT DOWN)
  while ip route show | grep -q "$MULTICAST_ADDRESS via $FROM_IP"; do
    ip route del -host $MULTICAST_ADDRESS gw $FROM_IP
  done
}

# FUNCTION TO REMOVE THE IPTABLES RULES THAT WE ADDED DURING OUR STARTUP (NEEDED FOR LOOP PROTECTION)
remove_iptables() {
  echo "Removing IPTables rules..."
  # DO THIS IN A WHILE SO WE REMOVE ALL THE RULES THAT MATCH THIS ONE (MAYBE SOME WHERE LEFT WHEN THE CONTAINER DIDNT PROPERLY SHUT DOWN)
  while iptables -C INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP 2>/dev/null; do
    iptables -D INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP
  done
}

# CHECK IF MULTICAST_PORT IS GIVEN
if [ -z "$MULTICAST_ADDRESS" ]; then
  echo "Please, specify for which MULTICAST_ADDRESS you want to run this proxy. I.e. for MDNS, set ENV: MULTICAST_ADDRESS to 224.0.0.251."
  exit 1
fi

# CHECK IF MULTICAST_PORT IS GIVEN
if [ -z "$MULTICAST_PORT" ]; then
  echo "Please, specify for which MULTICAST_PORT you want to run this proxy. I.e. for MDNS, set ENV: MULTICAST_PORT to 5353."
  exit 1
fi

# CHECK IF VIA_PORT IS GIVEN
if [ -z "$VIA_PORT" ]; then
  echo "Please, specify the VIA_PORT, which is the port you use between sender and receiver."
  exit 1
fi

# CHECK IF FROM_IP IS GIVEN
if [ -z "$FROM_IP" ]; then
  echo "Please, specify the IP on which you expect this multicast to arrive, we will join this IP address to the multicast group. I.e.: 192.168.0.10."
  exit;
fi

# CHECK IF TO_ADDRESS IS GIVEN
if [ -z "$TO_ADDRESS" ]; then
  echo "Please, specify the TO_ADDRESS, which is the other Proxy instance to which we need to send the (encapsulated) multicasts to. I.e. 145.25.27.10"
  exit 1
fi

check_root_and_capabilities
if [ $? -eq 1 ]; then
  echo "############################ WARNING #####################################"
  echo "### This script must be run as root or with CAP_NET_ADMIN capability.  ###"
  echo "### We will continue but host routes and loop protection will probably ###
  echo '### not set correctly.						       ###"
  echo "##########################################################################"
fi

# BECAUSE THE RECEIVER MIGHT HAVE MULTIPLE INTERFACES, WE NEED TO MAKE SURE TO ROUTE OUT THE MULTICAST VIA THE CORRECT INTERFACE (WHICH IS THE $FROM_IP).
# (NOTE THAT THIS ROUTE WILL BE APPLIED TO THE WHOLE HOST BECAUSE IT USES THE HOST NETWORK INTERFACE)
echo "Adding route to $MULTICAST_ADDRESS via $FROM_IP..."
route add -host $MULTICAST_ADDRESS gw $FROM_IP

# ADDING IPTABLES FOR EXTRA LOOP PROTECTION, THE ip-multicast-loop=0 FROM SOCAT DOESNT WORK, PROBABLY BECAUSE WE USE MULTIPLE SOCAT PROCESSES AND THEY ARE NOT AWARE OF EACH OTHER
echo "Adding IPTables loop protection to refuse incomming multicast packets to $MULTICAST_ADDRESS:$MULTICAST_PORT with SOURCE: $FROM_IP."
iptables -A INPUT -s $FROM_IP -d $MULTICAST_ADDRESS -p udp --dport $MULTICAST_PORT -j DROP
iptables -A INPUT -s 10.0.4.5 -d 224.0.23.12 -p udp --dport 3671 -j DROP

# REMOVE THE ROUTES WHEN THIS SCRIPT OR DOCKER CONTAINER STOPS
trap remove_routes EXIT TERM
trap remove_iptables EXIT TERM

# START SENDER AND RECEIVER
start_sender &
start_receiver &

# KEEP THE SCRIPT ACTIVE BY USING WAIT
while true; do
  wait
done
