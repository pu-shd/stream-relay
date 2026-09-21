# The relay watchdog. Python stdlib only - no pip, no wheels, nothing to pin.
#
# Built and pushed like any other image would be, except that it is not: the compose file
# builds it from this context on the host, because the relay deliberately has no registry
# (the ACR in relay.yml is a leftover of the retired custom-image path). One more image to
# fetch by digest is one more supply-chain edge; this one is built from source that is in
# the repo and reviewed with it.
# Pinned by digest, like every image in the compose file and for the same reason: a tag
# is a mutable pointer, and this builds on a host whose Actions runner is in the docker
# group. Resolved 2026-09-21. To upgrade, pull the tag and read RepoDigests.
FROM alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

# openssl for the certificate expiry check. Reading notAfter out of a PEM by hand means
# parsing DER, and getting that subtly wrong would make the check quietly always pass.
RUN apk add --no-cache python3 openssl ca-certificates

COPY watchdog.py /usr/local/bin/watchdog.py
RUN chmod 0755 /usr/local/bin/watchdog.py

# Unprivileged. It reads a log, reads metrics over HTTP, and writes one JSON file; none of
# that needs root, and this container is on the same network as an internet-facing nginx.
RUN adduser -D -u 10001 watchdog
USER watchdog

# No HEALTHCHECK. The watchdog reporting on its own health is circular; that it is alive
# at all is exactly what the Healthchecks.io dead-man's switch measures, from off the box.
ENTRYPOINT ["python3", "-u", "/usr/local/bin/watchdog.py"]
