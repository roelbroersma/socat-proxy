# USE BASE IMAGE, THIS HAS SOCAT 1.8.0.0 NOWADAYS :)
FROM alpine:latest

# INSTALL SOCAT, ROUTE, IPTABLES AND LIBCAP (FOR CAPSH)
RUN apk add --no-cache socat iproute2 iptables tcpdump libcap

# COPY OUR GREAT SOCAT SCRIPT TO THE ENTRYPOINT
COPY proxy.sh /usr/local/bin/entrypoint.sh

# CREATE SYMBOLIC LINKS TO USE iptables-legacy AS THE DEFAULT iptables BECAUSE SOME HOSTS (I.E. SYNOLOGY NAS) HAVE PROBLEMS WITH IPTABLES
RUN ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables

# GIVE EXEC PERMISSION
RUN chmod +x /usr/local/bin/entrypoint.sh

# SET ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
