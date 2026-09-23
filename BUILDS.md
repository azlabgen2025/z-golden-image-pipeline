# Build Log

Every published image is recorded here automatically. The build number is the
commit counter (`git rev-list --count HEAD`) — it only increases when the code
changes, so running the same commit again does **not** bump it. That makes it
safe to roll back: every build points to exactly one commit.

| Build | Version | Commit | Date | Image tags | Digest (sha256) | Changes |
|-------|---------|--------|------|------------|------------------|---------|
| 1 | 0.1.0 | `fd680b8` | 2026-09-21 | `v0.1.0-build-1`, `v0.1.0-fd680b8` | `9684a30f9a7447b20990fa264305abf65e4c658225c679d884560b3ff272db2c` | build: version images properly — per-build tags, generate version.json at build time |
| 17 | 0.1.0 | `1eb7b42` | 2026-09-21 | `v0.1.0-build-17`, `v0.1.0-1eb7b42` | `abc8f2cdcec44024583f2f9f347584507a791a4a8c8b7aec655cf9b4b61cb528` | ci: fetch full history so the per-build image tag uses the real build count |

> Note: build 1's counter was under-estimated (shallow clone); the count was
> corrected to the real value (17) once the workflow fetched full history.

## How to roll back

```bash
# 1. Find the build you want in the table above, then pull its tag:
docker pull ghcr.io/azlabgen2025/z-golden-image-pipeline:v0.1.0-build-<N>

# 2. Recreate the container from it (data volume keeps your settings):
docker rm -f golden-image-pipeline
docker run -d --name golden-image-pipeline --restart unless-stopped \
  -p 8080:8080 -e ADMIN_USER=admin -e ADMIN_PASSWORD=<your .env pw> \
  -v golden-image-data:/app/data \
  ghcr.io/azlabgen2025/z-golden-image-pipeline:v0.1.0-build-<N>

# 3. Check the running version (should match the row you picked):
curl -s http://<your-ip>:8080/api/version
```
| 21 | 0.1.0 | `557889e` | 2026-09-23 | `v0.1.0-build-21`, `v0.1.0-557889e` | sha256:a319669b8f5981ab747e92e70251026360875928248ac1d00f638acba1ba9faa | ci: give Build step id 'build-push' so the Record build step fires (it was skipped every run) |
