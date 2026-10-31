FROM alpine:3.23 AS prepared
RUN apk add --no-cache ca-certificates coreutils curl git openssh-client jq flock tzdata supercronic \
    && mkdir -p /app /data /root/.ssh
COPY container/ /app/
RUN chmod 755 /app/*.sh
ENV TZ=Etc/UTC

FROM prepared AS runtime
ENTRYPOINT ["/usr/bin/supercronic", "-inotify", "/config/crontab"]
