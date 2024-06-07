#!/bin/sh

# Enable Debugging in SOCAT Style
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

# FUNCTION TO START THE SENDER. LISTEN TO MULTICASTS AND FORWARD THEM TO ANOTHER IP ADDRESS (WHICH RECEIVES THEM AND SENDS THEM OUT AS MULTICASTS).
start_sender() {
  echo "Starting the sender..."
  socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECV:$MULTICAST_PORT,bind=$MULTICAST_ADDRESS,ip-add-membership=$MULTICAST_ADDRESS:$FROM_IP_OR_INTERFACE,reuseaddr,fork,ip-multicast-loop=0 UDP4-SENDTO:$TO_ADDRESS:$MULTICAST_PORT &
}

# FUNCTION TO START THE RECEIVER. LISTEN TO UDP PACKETS FROM THE SENDER (ADDRESSES TO THE SAME PORT AS THE MULTICAST PORT) AND SENDS THEM OUT AS MULTICASTS.
start_receiver() {
  echo "Starting the receiver..."
  socat $SOCAT_DEBUG_LEVEL -u -T $SOCAT_TIMEOUT UDP4-RECVFROM:$MULTICAST_PORT,ip-add-membership=$MULTICAST_ADDRESS:$FROM_IP_OR_INTERFACE,reuseaddr,fork UDP4-SENDTO:$MULTICAST_ADDRESS:$MULTICAST_PORT &
}

# FUNCTION TO REMOVE THE ROUTES THAT WE ADD DURING OUR STARTUP (NEEDED BECAUSE WE ADD ROUTES TO THE NETWORK STACK OF THE HOST)
remove_routes() {
  echo "Removing routes..."
	if echo "$FROM_IP_OR_INTERFACE" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
		route del -host $MULTICAST_ADDRESS gw $FROM_IP_OR_INTERFACE
	else
		route del --host $MULTICAST_ADDRESS dev $FROM_IP_OR_INTERFACE
	fi
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

# CHECK IF FROM_IP_OR_INTERFACE IS GIVEN
if [ -z "$FROM_IP_OR_INTERFACE" ]; then
  echo "Please, specify the IP or INTERFACE on which you expect this multicast to arrive, we will join this interface or IP address to the multicast group. I.e.: ovs_bond0, eth0, or 192.168.0.10."
  exit;
fi

# CHECK IF TO_ADDRESS IS GIVEN
if [ -z "$TO_ADDRESS" ]; then
  echo "Please, specify the TO_ADDRESS, which is the other Proxy instance to which we need to send the (encapsulated) multicasts to. I.e. 145.25.27.10"
  exit 1
fi

# BECAUSE THE RECEIVER MIGHT HAVE MULTIPLE INTERFACES, WE NEED TO MAKE SURE TO ROUTE OUT THE MULTICAST VIA THE CORRECT INTERFACE (WHICH IS THE $FROM_IP_OR_INTERFACE).
# (NOTE THAT THIS ROUTE WILL BE APPLIED TO THE WHOLE HOST BECAUSE IT USES THE HOST NETWORK INTERFACE)
echo "Adding route to this multicast address via $FROM_IP_OR_INTERFACE."
if echo "$FROM_IP_OR_INTERFACE" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
	route add -host $MULTICAST_ADDRESS gw $FROM_IP_OR_INTERFACE
else
	route add -host $MULTICAST_ADDRESS dev $FROM_IP_OR_INTERFACE
fi

# REMOVE THE ROUTES WHEN THIS SCRIPT OR DOCKER CONTAINER STOPS
trap remove_routes EXIT

# START SENDER AND RECEIVER
start_sender
start_receiver

# KEEP THE SCRIPT ACTIVE BY USING WAIT
while true; do
  wait
done
