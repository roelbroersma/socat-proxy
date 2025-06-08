# USE ALPINE BASE IMAGE, THIS HAS SOCAT 1.8.0.0 NOWADAYS :)
FROM alpine:latest

LABEL maintainer="roel@gigaweb.nl" \
      org.opencontainers.image.title="socat multicast proxy" \
      org.opencontainers.image.description="Forward multicast packets from one interface/IP to another using socat." \
      org.opencontainers.image.version="2.1.0" \
      org.opencontainers.image.licenses="MIT"

# INSTALL SOCAT, ROUTE, IPTABLES, TCPDUMP (for debug/troubleshoot), LIBCAP (FOR CAPSH) AND PROCPS (for pgrep healthcheck)
RUN apk add --no-cache socat iproute2 iptables tcpdump libcap procps

# COPY OUR GREAT SOCAT SCRIPT TO THE ENTRYPOINT
COPY proxy.sh /usr/local/bin/entrypoint.sh

# GIVE EXEC PERMISSION
RUN chmod +x /usr/local/bin/entrypoint.sh

# SET ENTRYPOINT
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# DOCKER HEALTHCHECK, THIS WILL CHECK IF THE SOCAT (RECEIVER AND SENDER) ARE RUNNING.
# IF NOT (MAYBE THE PROCESSES ARE RESTARTING), IT WILL RETRY AGAIN 100MS LATER, UNTIL A MAXIMUM OF 10 TIMES. THEN IT WILL FAIL
HEALTHCHECK CMD ["sh", "-c", "socat_recv_ok=1; socat_recvfrom_ok=1; \
for i in $(seq 1 10); do \
  pgrep -f \"socat .*UDP4-RECV\" >/dev/null && socat_recv_ok=0; \
  pgrep -f \"socat .*UDP4-RECVFROM\" >/dev/null && socat_recvfrom_ok=0; \
  [ $socat_recv_ok -eq 0 ] && [ $socat_recvfrom_ok -eq 0 ] && exit 0; \
  sleep 0.1; \
done; echo \"healthcheck: socat UDP4-RECV or UDP4-RECVFROM not seen within 1s\" >&2; exit 1"]
