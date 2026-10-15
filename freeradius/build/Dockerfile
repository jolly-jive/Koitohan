# The image of FreeRADIUS, with a packet filter put in front of it. See
# entrypoint.sh for why.
FROM cayenneryo/freeradius-server:4.0.40537-devel-ubuntu26-14fdfb3-r1

RUN apt-get update \
 && apt-get install -y --no-install-recommends nftables \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /koitohan-entrypoint.sh

# A new ENTRYPOINT clears the CMD of the base image, so it is given again
ENTRYPOINT ["/koitohan-entrypoint.sh"]
CMD ["freeradius"]
