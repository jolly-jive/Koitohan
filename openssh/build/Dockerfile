FROM alpine:3.24 AS passwdqc

ARG PASSWDQC_VERSION=2.1.0
ARG PASSWDQC_SHA256=52fa12271104e74126145c6224b22b4a8dd32cc47de04c1e9fb8f348340df4d2

RUN apk add --no-cache build-base linux-pam-dev

ADD --checksum=sha256:${PASSWDQC_SHA256} \
    https://www.openwall.com/passwdqc/passwdqc-${PASSWDQC_VERSION}.tar.gz /tmp/passwdqc.tar.gz

# the PAM modules of Alpine are in /usr/lib/security
RUN tar -xzf /tmp/passwdqc.tar.gz -C /tmp \
 && cd /tmp/passwdqc-${PASSWDQC_VERSION} \
 && make SECUREDIR=/usr/lib/security SHARED_LIBDIR=/usr/lib \
 && make SECUREDIR=/usr/lib/security SHARED_LIBDIR=/usr/lib DESTDIR=/out install


FROM alpine:3.24

RUN apk add --no-cache \
      gzip \
      linux-pam \
      nftables \
      nss-pam-ldapd \
      openldap-clients \
      openssh-client-common \
      openssh-server-pam \
      setpriv \
      shadow \
      tzdata

COPY --from=passwdqc /out/usr/bin/pwqcheck /usr/bin/pwqcheck
COPY --from=passwdqc /out/usr/lib/libpasswdqc.so.1 /usr/lib/libpasswdqc.so.1
COPY --from=passwdqc /out/usr/lib/security/pam_passwdqc.so /usr/lib/security/pam_passwdqc.so

COPY sshd_config /etc/ssh/sshd_config
COPY pam.d/ /etc/pam.d/
COPY limits.conf /etc/security/limits.d/koitohan.conf
COPY profile.sh /etc/profile.d/koitohan.sh
COPY entrypoint.sh /entrypoint.sh
COPY update-users.sh /usr/local/sbin/koitohan-update-users

# The root filesystem is read-only. The files written at the start go in
# /run (tmpfs), and symbolic links in /etc point at them.
# /etc/koitohan is where the certificates, the host keys and the password
# to bind with are mounted. Only root can enter it.
# The two under /tftpboot have the owner and the permissions that their
# sources (tftpd-hpa/tftpboot/) are asked to have.
RUN mkdir -m 700 /etc/koitohan \
 && mkdir /etc/koitohan/certs /etc/koitohan/hostkeys /etc/koitohan/secrets \
 && mkdir -p /logs/Hosts /tftpboot/configs /tftpboot/firmware \
 && chown 1000:10001 /tftpboot/configs /tftpboot/firmware \
 && chmod 2770 /tftpboot/configs /tftpboot/firmware \
 && mv /etc/passwd /etc/passwd.base \
 && mv /etc/group /etc/group.base \
 && ln -s /run/koitohan/passwd /etc/passwd \
 && ln -s /run/koitohan/group /etc/group \
 && ln -sf /run/koitohan/nslcd.conf /etc/nslcd.conf \
 && ln -sf /run/koitohan/passwdqc.conf /etc/passwdqc.conf

EXPOSE 22/tcp

ENTRYPOINT ["/entrypoint.sh"]
