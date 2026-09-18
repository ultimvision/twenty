# Deploying Twenty on Elestio (CI/CD)

Elestio's CI/CD pipeline clones this repository on the target VM, writes a `.env`
file at the repository root from the variables configured in the dashboard, then
runs the build and run commands declared in `elestio.yml`.

## Files it relies on

| File | Why it exists |
| --- | --- |
| `elestio.yml` (repo root) | Pipeline descriptor: reverse proxy ports, environment variables, runtime, lifecycle hooks. Elestio only reads it from the repository root. |
| `docker-compose.yml` (repo root) | The stack Elestio starts. Kept separate from `packages/twenty-docker/docker-compose.yml` so upstream merges stay conflict-free. |
| `packages/twenty-docker/elestio/scripts/preInstall.sh` | Creates the bind-mounted data directories with the ownership the images expect. |

## Differences with the generic self-hosting compose file

- **Port binding.** `172.17.0.1:3000:3000` instead of `3000:3000`. Elestio's
  reverse proxy terminates TLS on the public domain and forwards to the Docker
  bridge address; binding `0.0.0.0` would expose the app without TLS.
- **Bind mounts instead of named volumes.** Elestio's backups snapshot the
  deployment directory, so Postgres data and local file storage live under
  `./storage/` to be included.
- **`env_file: ./.env` on server and worker.** Any variable added in the Elestio
  dashboard reaches both containers without editing the compose file. See the
  [environment variables reference](https://docs.twenty.com/developers/self-host/capabilities/setup).
- **`SOFTWARE_VERSION_TAG` instead of `TAG`** for the image tag, which is the
  variable Elestio's version updater writes.

## Setup

1. Create an Elestio CI/CD service, pointing at this repository and the branch
   you deploy from.
2. Elestio picks up `elestio.yml` and pre-fills the environment variables. The
   ones marked `random_password` are generated at install time.
3. Check `SERVER_URL` matches the domain Elestio assigned (it defaults to
   `https://[CI_CD_DOMAIN]`, which Elestio substitutes). It has to match what
   users type in the browser, otherwise generated links and secure cookies break.
4. Deploy. The first boot runs the database migrations from the server
   container's entrypoint, which takes a few minutes.

## Notes

- `ENCRYPTION_KEY` protects every secret stored in the database (OAuth tokens,
  application variables, TOTP secrets). Losing it means losing access to them, so
  keep the generated value backed up.
- If you change `PG_DATABASE_PASSWORD`, use alphanumeric characters only: it is
  interpolated into a Postgres connection URL that is not URL-encoded.
- Twenty needs at least 2 GB of RAM to run both the server and the worker.
