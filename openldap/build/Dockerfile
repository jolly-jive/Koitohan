FROM alpine:3.24

# the slapd.conf and slapd.ldif of the package are not used. entrypoint.sh
# makes the config in slapd.d.
RUN apk add --no-cache \
      openldap \
      openldap-back-mdb \
      openldap-clients \
      openldap-overlay-memberof \
      openldap-overlay-ppolicy \
      openldap-overlay-refint \
      tzdata \
 && rm -f /etc/openldap/slapd.conf /etc/openldap/slapd.ldif

COPY entrypoint.sh /entrypoint.sh

# The root filesystem is read-only. What is written at the start goes in
# the config (/etc/openldap/slapd.d) and the data
# (/var/lib/openldap/openldap-data), both mounted, and in /run and
# /var/lib/openldap/run, both tmpfs (the socket of ldapi:///, where the
# build of the package put it).
# /etc/koitohan is where the certificates, the LDIF of the seed and the
# passwords of the administrators are mounted. Only root can enter it.
RUN mkdir -m 700 /etc/koitohan \
 && mkdir /etc/koitohan/certs /etc/koitohan/ldif /etc/koitohan/secrets \
 && mkdir -p /etc/openldap/slapd.d /var/lib/openldap/openldap-data /var/lib/openldap/run

EXPOSE 636/tcp

ENTRYPOINT ["/entrypoint.sh"]
