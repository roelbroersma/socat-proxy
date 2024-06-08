# USE ALPINE BASE IMAGE, THIS HAS SOCAT 1.8.0.0 NOWADAYS :)
FROM alpine:latest

# INSTALL SOCAT, ROUTE, IPTABLES, TCPDUMP (for debug/troubleshoot) AND LIBCAP (FOR CAPSH)
RUN apk add --no-cache socat iproute2 iptables-legacy tcpdump libcap

# COPY OUR GREAT SOCAT SCRIPT TO THE ENTRYPOINT
COPY proxy.sh /usr/local/bin/entrypoint.sh

# GIVE EXEC PERMISSION
RUN chmod +x /usr/local/bin/entrypoint.sh

# SET ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
