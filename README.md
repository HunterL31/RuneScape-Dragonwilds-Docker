# RuneScape: Dragonwilds Dedicated Server — Docker for Unraid

Runs the official free **RuneScape: Dragonwilds - Dedicated Servers** Steam product
(AppID `4019830`) in a container tuned for Unraid: `nobody:users` ownership by default,
appdata volume, graceful shutdown, hourly save backups, auto-update on start and
crash restart. Includes a Community-Applications-style template.

## What's inside

| File | Purpose |
|---|---|
| `Dockerfile` | Ubuntu 24.04 + SteamCMD + gosu |
| `entrypoint.sh` | Permissions, update, config generation, backups, signal handling |
| `unraid-template/my-dragonwilds.xml` | Unraid Docker template (all settings exposed in the UI) |
| `docker-compose.yml` | For local build/test or the Unraid Compose Manager plugin |
| `.github/workflows/docker-publish.yml` | Builds and pushes the image to Docker Hub |
| `ca_profile.xml` | Maintainer profile shown by Community Applications |

## Requirements

- x86-64 Unraid box with **2 GB + 1 GB per player** RAM free (8 GB for a full 6-player server)
- ~10 GB disk for game files, ideally on the cache/SSD pool
- **UDP 7777** forwarded from your router to the Unraid IP
- Your **Player ID** (bottom of the in-game Settings menu, use the copy button)

## Install on Unraid

The image is published to Docker Hub as
[`hunterl31/dragonwilds-server`](https://hub.docker.com/r/hunterl31/dragonwilds-server)
and the template already points at it, so there is nothing to build. Unraid pulls the
image the first time you click Apply.

### 1. Add the template

Copy the template to the flash drive from the Unraid terminal (Tools → Terminal, or SSH):

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/my-dragonwilds.xml \
  https://raw.githubusercontent.com/HunterL31/RuneScape-Dragonwilds-Docker/main/unraid-template/my-dragonwilds.xml
```

Then **Docker → Add Container** and pick **Dragonwilds** from the **Template** dropdown
(under *User templates*).

Unraid 6.x also had a **Template repositories** box at the bottom of the Docker tab where
you could paste this repo's GitHub URL instead. Unraid 7 removed it; the only remaining
in-UI way to add third-party templates is Community Applications (see
[Community Applications](#community-applications) below for the listing status).

**No template at all:** click **Add Container** with the Template dropdown empty, set
**Repository** to `hunterl31/dragonwilds-server:latest`, then add a UDP port mapping for
`7777`, a path from `/mnt/user/appdata/dragonwilds` to `/data`, the variables `OWNER_ID`
and `ADMIN_PASSWORD`, and `--stop-timeout 90` under Extra Parameters. Every other setting
has a default baked into the image.

### 2. Configure and apply

Fill in **Owner ID** and **Admin Password** (required), set your **Server Name** and
**Default World Name**, and click **Apply**. Unraid pulls
`hunterl31/dragonwilds-server:latest` and starts the container. The advanced settings
(backups, auto-restart, PUID/PGID, timezone) are under **Show more settings**.

### 3. Forward the port

Forward **UDP 7777** on every router between your Unraid box and the internet.
If you change the host port, change the `PORT` variable to the same number —
internal and external ports must match or players get bounced back to the title screen.

### 4. First start

The first start downloads ~10 GB of game files via SteamCMD; watch the container log. Once you see the
server listening, open the game → **Worlds → Public** and search for your **exact world
name** (case sensitive). The container's health check turns green once the server process is up.

### Updating the container image

When a new image is pushed to Docker Hub, the Unraid Docker tab shows **update ready**
next to the container. Click it to pull the new image. This is separate from game
updates, which SteamCMD applies on every container start (see below).

### Building the image yourself (optional)

If you would rather not pull from Docker Hub:

```bash
# from the Unraid terminal
mkdir -p /mnt/user/appdata/dragonwilds-build && cd /mnt/user/appdata/dragonwilds-build
# copy Dockerfile + entrypoint.sh here, then:
docker build -t dragonwilds-server:latest .
```

Then edit the container in the Unraid UI and change **Repository** to
`dragonwilds-server:latest`. To publish your own build, fork this repo and add
`DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets; the included GitHub Actions
workflow pushes to `<username>/dragonwilds-server` on every push to `main`.

## Community Applications

This repo is laid out as a CA template repository: the template lives in
`unraid-template/`, the icon is served from this repo, and `ca_profile.xml` at the root
supplies the maintainer profile. Once it is accepted, the container appears in the
Unraid **Apps** tab and the manual template copy above becomes unnecessary.

Submitting it, roughly in the order CA's maintainers expect:

1. **Open a support thread** in the Unraid forum under *Docker Containers*
   (https://forums.unraid.net/forum/47-docker-containers/). CA requires a support
   link; a forum thread is the convention, but the template currently points at this
   repo's GitHub Issues, which is also accepted. If you create a thread, put its URL in
   `<Support>` in the template.
2. **Read the current policies** in the pinned thread *Community Applications -
   Application Policies / Notes*
   (https://forums.unraid.net/topic/87144-ca-application-policies-notes/). It lists
   what CA checks: a public image, no unnecessary privileged mode, an icon, a support
   link, a unique name, and a working template.
3. **Send the repository URL** (`https://github.com/HunterL31/RuneScape-Dragonwilds-Docker`)
   to the CA maintainer (Squid) by forum private message, as that thread describes.
   Mention the support link and that the template is under `unraid-template/`.
4. After it is added, CA rescans the repo roughly every couple of hours. Edit the
   template in place to publish changes; add a dated entry to `<Changes>` so the
   changelog shows in the Apps tab.

Things already done here to meet the policies: `Privileged` is false, the image is
public on Docker Hub, `<Icon>`, `<Support>`, `<Project>`, `<Overview>`, `<Category>`,
`<ExtraSearchTerms>`, `<ReadMe>` and `<Changes>` are set, and no other app in the CA
feed uses the name **Dragonwilds**.

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `OWNER_ID` | — | **Required.** Your Player ID. Server refuses to start without it. |
| `ADMIN_PASSWORD` | — | **Required.** Grants in-game Server Management access. |
| `SERVER_NAME` | `Dragonwilds Server` | |
| `DEFAULT_WORLD_NAME` | `MyWorld` | World created on first start; also what players search for. |
| `WORLD_PASSWORD` | empty | Join password. Overrides any password stored in the world save. |
| `PORT` | `7777` | UDP listen port. Keep equal to the host port mapping. |
| `MAX_PLAYERS` | `6` | Official cap is 6. |
| `UPDATE_ON_START` | `true` | Run SteamCMD every start. Restart the container after game patches. |
| `VALIDATE_ON_START` | `false` | Full file verification (slow). Use to repair an install. |
| `AUTO_RESTART` | `true` | Relaunch the server if it crashes. |
| `BACKUP_INTERVAL` | `60` | Minutes between `SaveGames` backups. `0` disables. |
| `BACKUP_KEEP` | `24` | Number of archives kept in `/data/backups`. |
| `BACKUP_ON_STOP` | `true` | Back up when the container stops. |
| `STOP_TIMEOUT` | `60` | Seconds allowed for a clean shutdown. Keep below Docker's `--stop-timeout`. |
| `EXTRA_ARGS` | empty | Extra args appended to the server command line. |
| `PUID` / `PGID` | `99` / `100` | Unraid `nobody:users`. |
| `TZ` | `UTC` | |

## Volume layout (`/data`)

```
/data/server/                                       game install (SteamCMD)
/data/server/RSDragonwilds/Saved/SaveGames/         world .sav files
/data/server/RSDragonwilds/Saved/Config/LinuxServer/DedicatedServer.ini
/data/server/RSDragonwilds/Saved/Logs/RSDragonwilds.log
/data/backups/saves-YYYYMMDD-HHMMSS.tar.gz          automatic backups
```

`DedicatedServer.ini` is regenerated from the environment variables on every start
(the game-assigned `ServerGuid` is preserved). Change settings in the Unraid UI, not
by editing the file — the game discards edits made while it is running anyway.

## Moving an existing world onto the server

1. Stop the container.
2. Empty `/data/server/RSDragonwilds/Saved/SaveGames/` (a backup was taken on stop).
3. Copy your local `.sav` from
   `C:\Users\<you>\AppData\Local\RSDragonwilds\Saved\SaveGames\` into that folder.
4. Set `DEFAULT_WORLD_NAME` to that world's name and start the container.

The server loads the newest `.sav` it finds; it only creates a fresh default world when the folder is empty.

## Updating after a game patch

Restart the container. With `UPDATE_ON_START=true` SteamCMD fetches the new build
before launch. If clients can't see the server after a patch, compare the version at the top of
`RSDragonwilds.log` with the one in the game's top-left corner.

## Troubleshooting

- **Server not in the Public list** — port forwarding, version mismatch, or `OWNER_ID`/`ADMIN_PASSWORD` unset. Check the container log first.
- **Visible but not joinable** — UDP port not reaching the container, or host/`PORT` mismatch.
- **Permission errors** — set `PUID`/`PGID` to match the owner of the appdata folder, or `chown -R 99:100 /mnt/user/appdata/dragonwilds`.
- **SteamCMD "login anonymous" failures** — usually transient; the entrypoint retries 3 times, then restart the container.
- **Slow saves / stutter** — make sure the appdata share is cache-only (SSD), not on the array.
