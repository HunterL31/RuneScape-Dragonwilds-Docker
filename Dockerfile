# RuneScape: Dragonwilds Dedicated Server — Unraid-friendly image
# Installs the official free "RuneScape: Dragonwilds - Dedicated Servers"
# product (Steam AppID 4019830) via SteamCMD and keeps it updated.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gosu procps tzdata tar gzip \
      lib32gcc-s1 lib32stdc++6 libc6:i386 \
 && rm -rf /var/lib/apt/lists/*

# Unraid defaults: nobody (99) / users (100). Overridable at runtime via PUID/PGID.
RUN useradd -m -u 99 -s /bin/bash steam 2>/dev/null || useradd -m -o -u 99 -s /bin/bash steam

# SteamCMD
RUN mkdir -p /home/steam/steamcmd \
 && curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
    | tar -xz -C /home/steam/steamcmd \
 && chown -R steam:steam /home/steam

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV PUID=99 \
    PGID=100 \
    TZ=UTC \
    UPDATE_ON_START=true \
    VALIDATE_ON_START=false \
    SERVER_NAME="Dragonwilds Server" \
    DEFAULT_WORLD_NAME="MyWorld" \
    OWNER_ID="" \
    ADMIN_PASSWORD="" \
    WORLD_PASSWORD="" \
    PORT=7777 \
    MAX_PLAYERS=6 \
    EXTRA_ARGS="" \
    AUTO_RESTART=true \
    BACKUP_INTERVAL=60 \
    BACKUP_KEEP=24 \
    BACKUP_ON_STOP=true \
    STOP_TIMEOUT=60

VOLUME ["/data"]
EXPOSE 7777/udp

HEALTHCHECK --interval=60s --timeout=10s --start-period=15m --retries=3 \
  CMD pgrep -f RSDragonwildsServer-Linux-Shipping >/dev/null || exit 1

ENTRYPOINT ["/entrypoint.sh"]
