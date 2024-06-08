# USE ALPINE BASE IMAGE, THIS HAS SOCAT 1.8.0.0 NOWADAYS :)
FROM alpine:latest

# INSTALL SOCAT, ROUTE, IPTABLES, TCPDUMP (for debug/troubleshoot) AND LIBCAP (FOR CAPSH)
RUN apk add --no-cache socat iproute2 iptables-legacy tcpdump libcap

# COPY OUR GREAT SOCAT SCRIPT TO THE ENTRYPOINT
COPY proxy.sh /usr/local/bin/entrypoint.sh

# Install dependencies and iptables
#RUN apk update && \
#    apk add --no-cache iptables-legacy

# CREATE SYMBOLIC LINKS TO USE iptables-legacy AS THE DEFAULT iptables BECAUSE SOME HOSTS (I.E. SYNOLOGY NAS) HAVE PROBLEMS WITH IPTABLES
#RUN if [ -f /usr/sbin/iptables-legacy ]; then ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables; else ln -sf /usr/bin/iptables-legacy /usr/sbin/iptables; fi && \
#    if [ -f /usr/sbin/ip6tables-legacy ]; then ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables; else ln -sf /usr/bin/ip6tables-legacy /usr/sbin/ip6tables; fi

# CLEAN UP
#RUN rm -rf /var/cache/apk/*

# GIVE EXEC PERMISSION
RUN chmod +x /usr/local/bin/entrypoint.sh

# SET ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
