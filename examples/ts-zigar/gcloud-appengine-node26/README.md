# `gcloud-appengine-node26` — Google App Engine (`nodejs26`) in Zig 0.17

Google App Engine Standard Environment (`runtime: nodejs26` on Ubuntu 24.04) HTTP service written in Zig 0.17 using `zigar ts` bindings generated from `@types/node@26`.

## Features

- **`app.yaml` (`runtime: nodejs26`)**: Targets Google App Engine Standard's Node.js 26 Active LTS runtime with `inbound_services: [warmup]` and a prebuilt WebAssembly bundle (`entrypoint: node run-wasm.mjs`) requiring zero native compilation during `gcloud app deploy`.
- **Standard GAE Routes**:
  - `GET /` — Returns JSON service metadata (`GAE_SERVICE`, `GAE_VERSION`, `GAE_INSTANCE`, `GOOGLE_CLOUD_PROJECT`, `process.version`, request & warmup counters, and correlated Cloud Trace ID).
  - `GET /_ah/warmup` — App Engine warmup handler for pre-warming instances before live traffic arrives.
  - `GET /healthz` — Readiness probe endpoint (`HEAD` also supported).
- **Structured Google Cloud Logging**: Emits single-line JSON entries to `stdout` with `logging.googleapis.com/severity`, `httpRequest`, and `logging.googleapis.com/trace` / `spanId` / `trace_sampled` parsed from `x-cloud-trace-context`.
- **Graceful `SIGTERM` Drain**: Closes idle keep-alive sockets (`closeIdleConnections()`), drains in-flight HTTP requests via `server.close(cb)`, and detaches listeners cleanly when App Engine stops an instance, releasing 100% of JS handles, callbacks, and Zig allocations.
- **Standalone GAE Packaging (`.gcloudignore`)**: Ships an explicit `.gcloudignore` uploading only `app.yaml`, `package.json`, `run-wasm.mjs`, and `dist/**`, so the deployed instance boots directly from the prebuilt WASM bundle with zero dependency on `zig`, `rollup`, or monorepo parent paths.

## Local Quick Start

```bash
# Generate shared @types/node@26 bindings and run WASM + native integration tests
npm test

# Build the production WebAssembly bundle (dist/gae_server.mjs + stripped .wasm)
npm run build:wasm

# Start locally on 0.0.0.0:${PORT:-8080} (WASM or native node-zigar)
PORT=8080 npm start
PORT=8080 npm run run:native
```

## Deploying to Google App Engine

```bash
npm run build:wasm
gcloud app deploy app.yaml
```
