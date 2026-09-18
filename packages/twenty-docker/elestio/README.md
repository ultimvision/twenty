# Deploying Twenty on Elestio (CI/CD)

Elestio's CI/CD pipeline clones this repository on the target VM, writes a `.env`
file at the repository root from the variables configured in the dashboard, then
runs the build and run commands.

## Files it relies on

| File | Why it exists |
| --- | --- |
| `docker-compose.yml` (repo root) | The stack Elestio starts. Elestio only detects the `dockerCompose` runtime when this file is at the root of the deployed branch. Kept separate from `packages/twenty-docker/docker-compose.yml` so upstream merges stay conflict-free. |
| `scripts/preInstall.sh` (repo root) | Creates the bind-mounted data directories with the ownership the images expect. |
| `elestio.yml` (repo root) | Same settings in Elestio's template format. The wizard does not read it when you create a custom CI/CD pipeline, so it only serves as the reference for the values to enter, and for publishing this as an Elestio template later. |
| `packages/twenty-docker/elestio/.env.example` | Ready to paste or upload into the dashboard's environment variables editor. |

## Wizard settings

| Field | Value |
| --- | --- |
| Branch | the branch carrying the root `docker-compose.yml` |
| Application type | Full Stack |
| Runtime | Docker Compose |
| Build command | `docker-compose build` |
| Run command | `docker-compose --env-file .env up -d --build` |
| Pre install command | `./scripts/preInstall.sh` |
| Reverse proxy | HTTPS 443 to HTTP `172.17.0.1:3000`, path `/` |

Environment variables come from `.env.example`. `SERVER_URL` has to match the
domain Elestio assigned, and `ENCRYPTION_KEY` must be a fresh random secret.

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

## Notes

- `ENCRYPTION_KEY` protects every secret stored in the database (OAuth tokens,
  application variables, TOTP secrets). Losing it means losing access to them, so
  keep the value backed up.
- If you change `PG_DATABASE_PASSWORD`, use alphanumeric characters only: it is
  interpolated into a Postgres connection URL that is not URL-encoded.
- The first boot runs the database migrations from the server container's
  entrypoint, which takes a few minutes before the health check turns green.
- Redis has no volume, same as upstream: queued background jobs are lost on
  restart. Add a `./storage/redis:/data` bind mount if that matters to you.
- Twenty needs at least 2 GB of RAM to run both the server and the worker.
