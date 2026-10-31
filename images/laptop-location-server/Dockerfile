FROM alpine:3.23 AS prepared
RUN apk add --no-cache ca-certificates python3 tzdata supercronic \
    && mkdir -p /app /data
COPY container/ /app/
COPY function/main.py /app/main.py
RUN chmod 755 /app/*.sh
ENV TZ=Etc/UTC PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

FROM prepared AS runtime
ENTRYPOINT ["/usr/bin/supercronic", "-inotify", "/config/crontab"]
