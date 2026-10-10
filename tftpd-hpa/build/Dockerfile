FROM alpine:3.24

RUN apk add --no-cache tftp-hpa tzdata \
 && addgroup -g 1000 tftpd \
 && adduser -D -H -u 1000 -G tftpd -s /sbin/nologin tftpd

COPY entrypoint.sh /entrypoint.sh

EXPOSE 69/udp

ENTRYPOINT ["/entrypoint.sh"]
