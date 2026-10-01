# certs/

Only needed when running **proxied behind Cloudflare** (orange cloud). See the
[Behind Cloudflare](../README.md#behind-cloudflare-or-any-other-cdn) section of the README.

Put a **Cloudflare Origin certificate** here so Caddy can serve it instead of fetching one
from Let's Encrypt (which can't validate through Cloudflare's proxy):

- `origin.pem` — the certificate
- `origin.key` — its private key

Create them in the Cloudflare dashboard under **SSL/TLS → Origin Server → Create
Certificate**, then set `CLOUDFLARE_ORIGIN_CERT=true` in `.env` and
`docker compose up -d`.

The `.pem`/`.key` files are git-ignored (see `../.gitignore`) — never commit a private key.
This directory is also bind-mounted read-only into the Caddy container; leaving it empty is
harmless for a direct or DNS-only deployment.
