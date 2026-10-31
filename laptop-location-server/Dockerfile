FROM alpine:3.23
RUN apk add --no-cache ca-certificates coreutils curl jq flock tzdata \
    && mkdir -p /app /data
COPY container/ /app/
RUN chmod 755 /app/*.sh
ENTRYPOINT ["/app/entrypoint.sh"]
