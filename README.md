# Ente Photos — Proxmox LXC Installer

Installs [Ente Photos](https://ente.io) as a native Debian 12 LXC container on Proxmox VE — no Docker required. Supports all 64-bit CPUs including older hardware without AVX (e.g. Intel Xeon X5650, E5-2xxx, i7-2xxx series).

---

## Quick Install

Run on your **Proxmox host** to create a new LXC and install Ente inside it:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Mati-l33t/ente-proxmox/main/ct/ente.sh)
```

Or run directly **inside an existing Debian 12 LXC**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Mati-l33t/ente-proxmox/main/install/ente-install.sh)
```

---

## Requirements

| | Minimum | Recommended |
|---|---|---|
| CPU | 2 cores | 4 cores |
| RAM | 4 GB | 6 GB |
| Disk | 20 GB | 30 GB+ |
| OS | Debian 13 or 12 | Debian 13 |

**Build time:** 30–90 minutes depending on CPU speed. The Go and Node.js builds are CPU-intensive. On an Intel Xeon X5650 expect around 60–90 minutes for a full build.

### CPU compatibility

Works on any x86-64 CPU including older Westmere/Sandy Bridge hardware. Ente does not require AVX — unlike some other self-hosted apps, the Go server and Node.js 22 only need SSE4.2, which is available on Xeon X5600/X5500 series, E5-2xxx, and Core i7/i5 first and second gen.

---

## What gets installed

| Component | Version | Purpose |
|---|---|---|
| Museum | latest (git) | Ente API server (Go) |
| PostgreSQL | 15 | Database |
| MinIO | latest | S3-compatible object storage |
| Caddy | latest | Reverse proxy / static file server |
| Go | latest stable | Build toolchain |
| Node.js | 22 LTS | Build toolchain |

---

## Ports

| Service | Port | URL |
|---|---|---|
| Photos app | 3000 | `http://IP:3000` |
| Accounts app | 3001 | `http://IP:3001` |
| Albums app | 3002 | `http://IP:3002` |
| Auth app | 3003 | `http://IP:3003` |
| Cast app | 3004 | `http://IP:3004` |
| Locker app | 3005 | `http://IP:3005` |
| Museum API | 8080 | `http://IP:8080` |
| MinIO S3 API | 3200 | `http://IP:3200` |
| MinIO Console | 3201 | `http://IP:3201` |

---

## Setup

The installer asks one question before starting:

> **Server IP or hostname** — the address clients (browser, mobile app) will use to reach this server.

For a home LAN install, enter the LXC's IP address (e.g. `192.168.1.50`). For a domain, enter `photos.yourdomain.com`. This gets baked into the web app build at compile time, so get it right — changing it later requires rebuilding the web apps.

Everything else is generated automatically:
- PostgreSQL password
- MinIO access key and secret
- Ente encryption key, hash key, and JWT secret

All generated credentials are saved to `/root/ente-credentials.txt` inside the container.

---

## First login

Ente has no pre-set admin account. **The first account you register in the Photos app becomes the admin.** Open `http://IP:3000`, click Sign Up, and create your account.

> **Note:** During registration, Ente will ask for an email verification code. Since SMTP is not configured, the code is printed to the Museum log instead of sent by email. Watch for it with:
> ```bash
> journalctl -u museum -f
> ```

---

## Removing the storage limit

The default free plan includes a 10 GB quota. On a self-hosted instance you can remove this limit by running one command inside the container after registering your account:

```bash
set-storage
```

This sets unlimited storage for every registered user. Run it again whenever you add new accounts.

---

## File locations

| Path | Purpose |
|---|---|
| `/opt/ente/` | Ente source and Museum binary |
| `/opt/ente/server/museum.yaml` | Museum configuration |
| `/var/www/ente/apps/` | Built web apps (served by Caddy) |
| `/var/lib/minio/` | Photo storage data |
| `/etc/caddy/Caddyfile` | Caddy web server config |
| `/etc/default/minio` | MinIO credentials and options |
| `/root/ente-credentials.txt` | All generated passwords and keys |

---

## Logs

```bash
journalctl -u museum -f       # Ente API server
journalctl -u minio -f        # Object storage
journalctl -u caddy -f        # Web server
journalctl -u postgresql -f   # Database
```

---

## Updating

Run inside the container:

```bash
update
```

This pulls the latest Ente source, rebuilds the Museum binary, rebuilds all web apps, and restarts services.

---

## Configuring email (SMTP)

SMTP is not configured during install. To enable it, edit `/opt/ente/server/museum.yaml` and add:

```yaml
smtp:
    host: smtp.yourprovider.com
    port: 587
    username: you@example.com
    password: yourpassword
    sender: you@example.com
```

Then restart Museum:

```bash
systemctl restart museum
```

---

## Configuring the mobile app

In the Ente mobile app, go to **Settings → General → Self Hosting** and set the endpoint to:

```
http://YOUR_IP:8080
```

---

## License

MIT — see [LICENSE](LICENSE)

Built for Proxmox VE. Not affiliated with Ente Technologies.
