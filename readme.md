# Canopus Workflow Sandbox

A small HTTP service that runs JavaScript workflow scripts and forwards workflow actions to a callback service. The Docker image uses Node.js 22.13.1 and runs as the non-root `node` user.

## Environment variables

Pass configuration **when starting the container**, using `docker run --env-file` or `-e`. No build arguments are required, and the Dockerfile does not copy `.env` into the image. The worker does not load `.env` itself.

| Variable | Required | Default | Purpose |
| --- | --- | --- | --- |
| `WORKFLOW_JS_RUNNER_SECRET` | Yes | None | Shared secret of at least **32 characters**. Clients must send `Authorization: Bearer <secret>` when calling `POST /execute`. |
| `WORKFLOW_JS_CALLBACK_URL` | Yes | None | Full HTTP(S) endpoint used for workflow action callbacks. It must be reachable **from inside the container**. |
| `WORKFLOW_JS_TIMEOUT_MS` | No | `3000` | Script execution timeout in milliseconds. Use a positive integer. Applies to synchronous VM execution and the wait for the returned promise; it does not cancel an in-flight callback request. |
| `PORT` | No | `3000` | HTTP listening port inside the container. Use an available port between `1` and `65535`; the service binds to `0.0.0.0`. |

Startup fails if the secret is missing or shorter than 32 characters, or the callback URL is empty. The callback URL's format and connectivity are not checked at startup. Empty values for `PORT` and `WORKFLOW_JS_TIMEOUT_MS` use their defaults.

## Run with Docker

### 1. Create a local `.env` file

```dotenv
# Required: replace with a randomly generated secret (at least 32 characters).
WORKFLOW_JS_RUNNER_SECRET=replace-with-a-random-secret-at-least-32-characters

# Required: replace with your application's actual callback endpoint.
WORKFLOW_JS_CALLBACK_URL=http://host.docker.internal:8080/your-workflow-callback

# Optional defaults.
WORKFLOW_JS_TIMEOUT_MS=3000
PORT=3000
```

Generate a secret with `openssl rand -hex 32`, then paste its output into the file. Use plain `KEY=value` entries without shell `export` statements or surrounding quotes. Keep `.env` private; it is already excluded by `.gitignore`.

The callback path above is a placeholder. This repository provides the runner, not the callback service.

### 2. Build the image

From the repository directory:

```sh
docker build -t canopus-workflow-sandbox .
```

### 3. Start the container

For local use with the callback service running on your host:

```sh
docker run -d \
  --name canopus-workflow-sandbox \
  --env-file .env \
  --publish 127.0.0.1:3000:3000 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  canopus-workflow-sandbox
```

On Docker Desktop, `host.docker.internal` addresses the host. On Linux Docker Engine, add `--add-host host.docker.internal:host-gateway` to the command when using that hostname. The host callback service must listen on an interface reachable by the container.

For a callback service in another container, attach both containers to the same user-defined Docker network, add `--network <network-name>` to the command, and use the callback container's name and internal port in `WORKFLOW_JS_CALLBACK_URL`, for example `http://workflow-api:8080/your-workflow-callback`.

`localhost` inside the runner refers to the runner container itself. Do not use it for a callback service running on the host or in a different container.

### 4. Check the service

```sh
curl --fail http://localhost:3000/health
```

Expected response:

```json
{"status":"ok"}
```

This checks that the HTTP service is running; it does not test callback connectivity. View startup errors with:

```sh
docker logs canopus-workflow-sandbox
```

## Build and publish to Docker Hub

The Makefile targets [api2studio/workflow-sandbox on Docker Hub](https://hub.docker.com/r/api2studio/workflow-sandbox). You need Docker running, `make`, and a Docker Hub account with push access to that repository.

```sh
# Authenticate with Docker Hub.
docker login

# Build with the version from version.txt and the latest tag.
make build

# Build and push both the version tag and latest.
make push
```

Edit `version.txt` to set the release version (currently `0.0.1`). This file is the source of the version tag; `TAG` overrides are ignored. `make build` tags the same image with both that version and `latest`. `make push` builds first, then pushes the version tag followed by `latest`, stopping if a command fails. Running `make` or `make help` shows the available commands.

| Make variable | Default | Purpose |
| --- | --- | --- |
| `IMAGE` | `api2studio/workflow-sandbox` | Image repository, without a tag. |
| `PLATFORM` | Docker daemon's architecture | Optional single target platform, such as `linux/amd64` or `linux/arm64`. |

For example, to publish an AMD64 image from an ARM machine, use `make push PLATFORM=linux/amd64` (requires cross-platform build support in Docker). These targets publish a single-platform image.

The Makefile's image name differs from the local shorthand used in the earlier `docker run` example. To run an image built or published with Make, replace the final image argument with `api2studio/workflow-sandbox:latest` (or your selected tag).

Runtime environment variables are supplied when starting the container, not when building or pushing. `.dockerignore` excludes local `.env` files and Git metadata from the build context.

## Ports and configuration changes

Docker port mappings use `HOST_PORT:CONTAINER_PORT`. To expose the default internal port on host port `8081`, use `--publish 127.0.0.1:8081:3000` and leave `PORT=3000`.

If you change `PORT` to `4000`, also change the mapping, for example `--publish 127.0.0.1:3000:4000`. The Dockerfile's `EXPOSE 3000` is metadata; it does not publish a port or override `PORT`.

Environment values are read at startup. After editing `.env`, recreate the container with the updated `docker run` command; restarting the existing container does not reload the file:

```sh
docker stop canopus-workflow-sandbox
docker rm canopus-workflow-sandbox
# Run the docker run command above again.
```

## Requests and callbacks

- `GET /health` is unauthenticated and returns `{"status":"ok"}`.
- `POST /execute` requires the runner secret as a bearer token and accepts JSON containing `script`, `context`, and `capability`.
- Scripts can read `context` and call workflow actions using `actions.<action>(args)` or the equivalent global function. Action arguments must be objects.
- Each action makes a JSON `POST` to `WORKFLOW_JS_CALLBACK_URL` with `{ "capability": ..., "action": ..., "args": ... }`. The callback should return JSON containing `result` on success or `error` on failure with a non-success HTTP status.
- The runner secret authenticates incoming execution requests. It is **not** sent to the callback service; the callback receives the request's `capability` and must validate it.

Example execution request (replace the token with your configured secret):

```sh
curl --fail-with-body http://localhost:3000/execute \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer YOUR_RUNNER_SECRET' \
  --data '{"script":"return context.value * 2;","context":{"value":21},"capability":null}'
```

Expected response: `{"result":42}`. This example does not invoke a callback; scripts that invoke actions need a capability accepted by your callback service.

Execution errors return HTTP `422`, and incorrect or missing bearer tokens return `401`. Request bodies are limited to 128 KiB, and scripts to 65,536 JavaScript string characters. These limits are fixed in `worker.js`, not configurable through environment variables.

## Container isolation

The image enables Node.js permissions and disables string-based code generation. The run command above adds a read-only root filesystem, drops Linux capabilities, and prevents privilege escalation. It publishes the runner only on the host loopback interface.

The Dockerfile mentions Compose isolation, but this repository does not include a Compose file. Network restrictions and resource limits must be configured by your deployment. The example run command allows outbound networking so callbacks can work. For untrusted workflows, restrict network access to the intended callback service and set appropriate memory, CPU, and process limits. `--network none` prevents HTTP callbacks from working.

Node's `vm` context is not a security boundary; deployment isolation is required for untrusted scripts.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Container exits immediately | Check `docker logs`; confirm both required variables are set and the secret has at least 32 characters. |
| Health endpoint cannot be reached | Confirm the container is running and the published container port matches `PORT`. |
| `/execute` returns `401` | Send the exact configured secret using `Authorization: Bearer <secret>`. |
| Actions fail with a fetch or connection error | Check the callback URL, container DNS/network access, and callback service listener. |
| Actions fail while parsing JSON | The callback must return JSON, including for error responses. |
| Execution returns `Script timed out` | Check script and callback latency; adjust `WORKFLOW_JS_TIMEOUT_MS` if appropriate. |
| `.env` changes have no effect | Recreate the container with `--env-file .env`. |
