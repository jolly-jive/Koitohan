FROM alpine:3.24

RUN apk add --no-cache chrony tzdata

COPY entrypoint.sh /entrypoint.sh

EXPOSE 123/udp

ENTRYPOINT ["/entrypoint.sh"]
