# The image of FreeRADIUS, with a packet filter put in front of it. See
# entrypoint.sh for why.
FROM cayenneryo/freeradius-server:4.0.41575-devel-ubuntu26-3af4e9e-r1

RUN apt-get update \
 && apt-get install -y --no-install-recommends nftables \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /koitohan-entrypoint.sh

# A new ENTRYPOINT clears the CMD of the base image, so it is given again
ENTRYPOINT ["/koitohan-entrypoint.sh"]
CMD ["freeradius"]
