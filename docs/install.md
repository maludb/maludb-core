# MaluDB v4.0.0 — Detailed Install Guide

This is the operator-grade install playbook for MaluDB v4.0.0 on a
clean Ubuntu 24.04 LTS server. Every step has the exact command, the
expected output, the pass criterion, and a troubleshooting note for
the most likely failure mode. If you're following this end-to-end as
the field test, also read [`field-test.md`](field-test.md) for the
acceptance procedure that wraps this guide.

> **Field-test note.** The bootstrap script in this guide has been
> exercised step by step on the build host. The very-first install on
> a *clean* Ubuntu 24.04 server is the field-test step. If anything
> deviates from the expected output below, **stop, capture the diff,
> and report it** rather than papering over.

---

## 0. Host requirements

| | |
|---|---|
| **OS** | Ubuntu 24.04 LTS (Noble Numbat). x86_64 or arm64. |
| **CPU** | 4 cores recommended; 2 cores minimum. |
| **RAM** | 4 GiB minimum for the listener + DB. ≥ 8 GiB recommended on a CPU-only host running a small local model (Qwen 2.5 0.5B / Llama 3.2 1B); 16 GiB for 3B-class models. |
| **Disk** | 20 GiB free for PG + extension + build artifacts. Add model size for local llama. |
| **GPU** | **Optional.** The MaluDB stack is GPU-agnostic; only `llama-cli` benefits from a GPU. Without one, llama.cpp falls back to CPU inference. NVIDIA + CUDA 12.x detected by `scripts/maludb-gpu-check`; CPU-only hosts get a WARN that's treated as PASS by the field-test acceptance procedure. |
| **Network** | Outbound HTTPS to `apt.postgresql.org` and `github.com` for repo + submodule fetch. Inbound `:5329/tcp` to clients (or behind NGINX). |
| **Privileges** | A user with `sudo`. Bootstrap must be invoked via `sudo`. |
| **Firewall** | If running `ufw`, allow your client subnet to `5329/tcp` after install. |

The bootstrap refuses to run on non-Ubuntu unless `MALUDB_FORCE_OS=1`
is set; this is intentional and you should not override it for the
field test.

---

## 1. Prepare the host

### 1.1 Check the OS

```bash
lsb_release -a
```

Expected:

```
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.x LTS
Release:        24.04
Codename:       noble
```

Pass criterion: `Release: 24.04`. If you see something else, stop here
unless you've consciously decided to test on a different distro.

### 1.2 Update apt

```bash
sudo apt-get update
sudo apt-get -y upgrade
```

Pass criterion: no errors. `Failed to fetch`-class network problems
will surface here, not later.

### 1.3 Install git and curl (you'll need them in §2)

```bash
sudo apt-get install -y git curl ca-certificates
```

### 1.4 (Optional) sudo without password during the field test

Bootstrap calls `sudo` repeatedly. If you don't want to type your
password every minute:

```bash
echo "$USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$USER-fieldtest
```

Remove this file after the field test:

```bash
sudo rm /etc/sudoers.d/$USER-fieldtest
```

---

## 2. Get the repo

### 2.1 Clone

```bash
git clone https://github.com/maludb/maludb-core.git ~/maludb-core
cd ~/maludb-core
```

### 2.2 Initialize submodules

MaluDB v4.0.0 builds against `llama.cpp` tag `b9165`, pinned in
`.gitmodules`. Initialise the submodule:

```bash
git submodule update --init --recursive
```

Expected:

```
Submodule 'third_party/llama.cpp' (https://github.com/ggml-org/llama.cpp.git) registered
Cloning into '/home/$USER/maludb-core/third_party/llama.cpp'...
Submodule path 'third_party/llama.cpp': checked out '<pinned commit>'
```

Pass criterion: `third_party/llama.cpp/CMakeLists.txt` exists.

```bash
ls third_party/llama.cpp/CMakeLists.txt
```

If this fails: your network couldn't reach `github.com` from the
server. Configure HTTPS proxy or vendor the submodule via a private
mirror, then retry.

---

## 3. Bootstrap

### 3.1 Preview the plan

The bootstrap supports a `--dry-run` flag that prints what each step
would do without making changes. Always run it first:

```bash
./scripts/maludb-bootstrap --dry-run
```

You should see an 11-step plan. Read it before continuing.

### 3.2 Run the bootstrap

```bash
sudo ./scripts/maludb-bootstrap
```

This will take 2–5 minutes depending on apt mirror speed. The script
is idempotent — running it twice is safe.

Sample output (abbreviated):

```
==> Preflight
    ✓ Ubuntu 24.04 detected
    ✓ Repo root: /home/$USER/maludb-core

==> Installing apt dependencies
    ✓ PGDG repo configured
    ✓ Installed: postgresql-17 postgresql-server-dev-17 postgresql-17-pgvector postgresql-17-pgaudit postgresql-17-partman ...

==> Building maludb_core (PGXS) and maludb_mc2dbd
    ✓ maludb_core built
    ✓ maludb_mc2dbd built

==> Installing maludb_core into PostgreSQL
    ✓ maludb_core installed

==> Creating OS service users
    ✓ Created OS group maludb
    ✓ Created OS user maludb_mc2dbd (primary group maludb)
    ✓ Created OS user maludb_modeld (primary group maludb)

==> Configuring PostgreSQL roles and database
    ✓ Created PG role maludb_mc2dbd (peer-auth via Unix socket)
    ✓ Created PG role maludb_modeld (peer-auth via Unix socket)
    ✓ Created database maludb
    ✓ Extension active in maludb; maludb_mc2dbd and maludb_modeld granted

==> Installing config files
    ✓ Installed /etc/maludb/maludb.conf
    ✓ Installed /etc/maludb/maludb-modeld.conf
    ✓ Installed /etc/maludb/maludb-mc2dbd.conf

==> TLS bootstrap
    ✓ Generated self-signed TLS cert at /etc/maludb/tls/server.crt

==> Installing service binaries
    ✓ Installed: /usr/local/sbin/maludb_mc2dbd, /usr/local/sbin/maludb_modeld

==> systemd units
    ✓ Installed maludb-mc2dbd.service and maludb-modeld.service

==> Bootstrap complete
```

Pass criterion: every section ends with a green ✓ line and the script
exits 0. Re-running should produce mostly cyan `·` (skip) lines.

### 3.3 Common bootstrap failures

| Symptom | Cause | Fix |
|---|---|---|
| `E: Unable to locate package postgresql-17` | PGDG repo step failed silently. | `cat /etc/apt/sources.list.d/pgdg.list` should contain `noble-pgdg main`. Re-run `sudo apt-get update` and look for HTTP errors. |
| `make: *** No rule to make target 'install'.` | You ran bootstrap from a directory other than the repo root. | `cd ~/maludb-core && sudo ./scripts/maludb-bootstrap` |
| Bootstrap stops immediately after `==> Configuring pgaudit preload` | Older bootstrap code aborted when `shared_preload_libraries` or `pgaudit.log` was unset on a fresh cluster. | Pull a revision that includes the pgaudit preload fix, then re-run `sudo ./scripts/maludb-bootstrap`. |
| `psql: error: FATAL: Peer authentication failed` | The cluster's `pg_hba.conf` doesn't have a `local all all peer` line. | The default Ubuntu PG install does have this. If you've customized, add: `local all all peer` to `/etc/postgresql/17/main/pg_hba.conf`, then `sudo systemctl reload postgresql`. |
| `useradd: user 'maludb_mc2dbd' already exists` followed by failure | A previous partial install left the user; the script should `skip`, but a different shell or group was set. | `sudo userdel maludb_mc2dbd && sudo userdel maludb_modeld && sudo groupdel maludb`, then re-run. |
| `cd '/usr/lib/postgresql/17/lib/bitcode' && ... llvm-lto ...` exits non-zero | LLVM JIT build step failed. | Verify `dpkg -l llvm-19-runtime` shows installed. The `postgresql-server-dev-17` package pulls it; if missing, `sudo apt-get install -y llvm-19-runtime`. |

---

## 4. Verify the install

### 4.1 Run the validator

```bash
./scripts/maludb-validate
```

Expected (the listener isn't started yet, so its checks WARN):

```
PASS  PostgreSQL reachable (PostgreSQL 17.x ...)
PASS  maludb_core 0.71.0 installed
PASS  pgvector demo table reachable
WARN  pgvector demo table empty (ok if no rows inserted yet)
PASS  pgaudit present in shared_preload_libraries
PASS  pgaudit.log = 'write, ddl, role'
WARN  no GPU detected (CPU-only install — dev OK; production benchmarks want a GPU)
PASS  model runtime stub mode functional
PASS  14 maludb.r10 tools registered (13 R1.0 + 1 R1.1)
PASS  stage boundary clean
PASS  end-to-end stub pipeline (account → session → context → render → submit → response)
WARN  listener not running at http://127.0.0.1:5329 (start with: sudo systemctl start maludb-mc2dbd)

Validation OK: 9 pass / 3 warn / 0 fail (12 checks)
```

Pass criterion: **no FAIL lines.** WARN is acceptable for the
GPU-readiness check on a CPU-only host and for the listener-not-running
check until §5.

If the extension check FAILs but the database exists: the dev cluster
might have a stale schema from an earlier dry-run. To reset cleanly:

```bash
sudo -u postgres psql -d maludb -c "DROP SCHEMA IF EXISTS mc2db CASCADE; DROP SCHEMA IF EXISTS maludb_core CASCADE; CREATE EXTENSION maludb_core CASCADE;"
./scripts/maludb-validate
```

---

## 5. Start the listener

### 5.1 Enable + start the systemd unit

```bash
sudo systemctl enable --now maludb-mc2dbd
```

Expected on the first enable:

```
Created symlink /etc/systemd/system/multi-user.target.wants/maludb-mc2dbd.service → /etc/systemd/system/maludb-mc2dbd.service.
```

If the unit is already enabled, `systemctl enable --now` may print
nothing and still succeed. Continue to the status check.

### 5.2 Confirm it's running

```bash
systemctl status maludb-mc2dbd --no-pager
```

Expected (truncated):

```
● maludb-mc2dbd.service - MaluDB MC2DB Listener (R1.0)
     Loaded: loaded (/etc/systemd/system/maludb-mc2dbd.service; enabled; ...)
     Active: active (running) since ...
   Main PID: 12345 (maludb_mc2dbd)
     CGroup: /system.slice/maludb-mc2dbd.service
             └─12345 /usr/local/sbin/maludb_mc2dbd --foreground --host 127.0.0.1 --port 5329 ...

... maludb_mc2dbd ... info mc2dbd listening on 127.0.0.1:5329 (TLS=off)
... maludb_mc2dbd ... info mc2dbd maludb_mc2dbd 0.1.0 ready
```

Pass criterion: `Active: active (running)`.

### 5.3 Smoke-test the listener

```bash
curl -fsS http://127.0.0.1:5329/healthz
```

Expected:

```
ok
```

```bash
curl -fsS -X POST http://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | jq .
```

Expected:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2025-11-25",
    "capabilities": {"tools": {"listChanged": false}},
    "serverInfo": {"name": "maludb_mc2dbd", "version": "0.1.0"}
  }
}
```

```bash
curl -fsS -X POST http://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
    | jq '.result.tools | length'
```

Expected: `41`

### 5.4 Re-run the validator

```bash
./scripts/maludb-validate
```

Now expect:

```
... (the pre-listener checks from §4.1) ...
PASS  listener /healthz reachable at http://127.0.0.1:5329
PASS  MCP initialize succeeds (serverInfo.name=maludb_mc2dbd)
PASS  tools/list advertises 41 maludb.* tools
PASS  tools/call maludb.health → status=ok

Validation OK: 13 pass / 2 warn / 0 fail (15 checks)
```

Pass criterion: **no FAIL lines** and the four listener checks above
are PASS. A CPU-only host and an empty `malu$vector_demo` table remain
acceptable WARNs.

### 5.5 Listener won't start

If `systemctl status` shows `Active: failed`:

```bash
sudo journalctl -u maludb-mc2dbd --no-pager | tail -50
```

Common causes:

| Log line | Cause | Fix |
|---|---|---|
| `PG connect failed: FATAL: Peer authentication failed for user "maludb_mc2dbd"` | OS user / PG role mismatch. | The bootstrap should have created both. Verify with `id maludb_mc2dbd` and `sudo -u postgres psql -c "\du maludb_mc2dbd"`. |
| `MHD_start_daemon failed for 127.0.0.1:5329` | Port already in use, or TLS key/cert unreadable. | `ss -tlnp | grep 5329` to find the conflict. For TLS issues, `sudo -u maludb_mc2dbd cat /etc/maludb/tls/server.crt` should succeed. |
| `tls_enabled requires tls_cert_path and tls_key_path` | TLS=true in conf but paths blank. | Either set the paths or set `TLS=false` in `/etc/maludb/maludb-mc2dbd.conf`. |

---

## 6. Configuration reference

After bootstrap, three files in `/etc/maludb/` control behavior. Edit
with `sudoedit` to preserve ownership.

### 6.1 `/etc/maludb/maludb.conf` — shared

| Key | Default | Meaning |
|---|---|---|
| `PG_CONNINFO` | `host=/var/run/postgresql user=maludb_mc2dbd dbname=maludb` | libpq connection string used by the listener. |
| `PG_DATABASE` | `maludb` | Database name MaluDB owns. |
| `SERVICE_USER` | `maludb_mc2dbd` | OS user the listener runs as. |
| `SERVICE_GROUP` | `maludb_mc2dbd` | Primary group. |
| `LOG_DIR` | `/var/log/maludb` | Where MaluDB writes operational logs. |

### 6.2 `/etc/maludb/maludb-mc2dbd.conf` — listener

| Key | Default | Meaning |
|---|---|---|
| `HOST` | `127.0.0.1` | Bind address. Use `0.0.0.0` only if you also enable TLS + bearer-token. |
| `PORT` | `5329` | Listener TCP port. |
| `PG_CONNINFO` | (from `maludb.conf`) | Override per-listener if needed. |
| `BEARER_TOKEN` | (unset) | If set, every request must carry `Authorization: Bearer <this>`. |
| `TLS` | `false` | Set `true` to enable HTTPS. |
| `TLS_CERT` | (commented) | PEM cert path. |
| `TLS_KEY` | (commented) | PEM key path. |

### 6.3 `/etc/maludb/maludb-modeld.conf` — model gateway

| Key | Default | Meaning |
|---|---|---|
| `POLL_INTERVAL` | `5` | Seconds between `malu$model_request` polls. |
| `LLAMA_CLI` | `/usr/local/bin/llama-cli` | Path to llama.cpp's CLI. Bootstrap does NOT install this. |
| `LLAMA_DEFAULT_ARGS` | `--temp 0.0 -n 512 --no-display-prompt` | Args appended to every invocation. |
| `MAX_PROMPT_CHARS` | `200000` | Hard limit on prompt length. |
| `DEFAULT_TIMEOUT` | `300` | Seconds before SIGKILL. Per-request `timeout_ms` wins if smaller. |

After editing any conf, restart the affected service:

```bash
sudo systemctl restart maludb-mc2dbd     # or maludb-modeld
```

### 6.4 Enabling bearer-token authentication

Generate a token and write it directly into the listener's systemd
environment file:

```bash
TOKEN=$(openssl rand -base64 48)

sudo cp /etc/maludb/maludb-mc2dbd.conf /etc/maludb/maludb-mc2dbd.conf.bak
sudo awk -v token="$TOKEN" '
  BEGIN { done=0 }
  /^#?[[:space:]]*BEARER_TOKEN=/ {
    print "BEARER_TOKEN=\"" token "\""
    done=1
    next
  }
  { print }
  END {
    if (!done) print "BEARER_TOKEN=\"" token "\""
  }
' /etc/maludb/maludb-mc2dbd.conf.bak \
  | sudo tee /etc/maludb/maludb-mc2dbd.conf >/dev/null
sudo chown root:maludb /etc/maludb/maludb-mc2dbd.conf
sudo chmod 0640 /etc/maludb/maludb-mc2dbd.conf

sudo systemctl restart maludb-mc2dbd
```

Confirm the file contains a token and the listener is still running:

```bash
sudo awk -F= '/^BEARER_TOKEN=/{print "BEARER_TOKEN=<set>"}' /etc/maludb/maludb-mc2dbd.conf
systemctl status maludb-mc2dbd --no-pager
```

Pass criterion: the first command prints `BEARER_TOKEN=<set>`, and
`systemctl status` shows `Active: active (running)`.

Unauthenticated requests should now fail:

```bash
curl -i -sS -X POST http://127.0.0.1:5329/ \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | head
```

Expected: `HTTP/1.1 401 Unauthorized`.

Authenticated requests should still work:

```bash
curl -fsS -X POST http://127.0.0.1:5329/ \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | jq .
```

To edit manually instead, set this line in
`/etc/maludb/maludb-mc2dbd.conf`:

```conf
BEARER_TOKEN="paste-the-generated-token-here"
```

Then run `sudo systemctl restart maludb-mc2dbd`.

### 6.5 Enabling native TLS

Native TLS means `maludb_mc2dbd` terminates HTTPS itself. The listener
keeps the same bind address and port, but clients must switch from
`http://127.0.0.1:5329` to `https://127.0.0.1:5329`. The bootstrap
creates a self-signed development certificate at
`/etc/maludb/tls/server.crt` and a matching private key at
`/etc/maludb/tls/server.key`; those files are readable by the
`maludb_mc2dbd` service user.

Use this path for a single-host or field-test install. For a public
deployment, either replace the self-signed certificate with one from
your CA or keep the listener on localhost and put NGINX/HAProxy in
front to terminate TLS.

First confirm the generated certificate and key exist and are readable
by the service user:

```bash
sudo -u maludb_mc2dbd test -r /etc/maludb/tls/server.crt
sudo -u maludb_mc2dbd test -r /etc/maludb/tls/server.key
openssl x509 -in /etc/maludb/tls/server.crt -noout -subject -ext subjectAltName
```

If either `test -r` command fails, regenerate the development
certificate:

```bash
sudo ./scripts/maludb-tls-init \
  --out-dir /etc/maludb/tls \
  --owner maludb_mc2dbd \
  --group maludb
```

Now write the TLS settings directly into the listener's systemd
environment file:

```bash
sudo cp /etc/maludb/maludb-mc2dbd.conf /etc/maludb/maludb-mc2dbd.conf.bak
sudo awk '
  BEGIN {
    seen_tls=0
    seen_cert=0
    seen_key=0
  }
  /^#?[[:space:]]*TLS=/ {
    print "TLS=true"
    seen_tls=1
    next
  }
  /^#?[[:space:]]*TLS_CERT=/ {
    print "TLS_CERT=/etc/maludb/tls/server.crt"
    seen_cert=1
    next
  }
  /^#?[[:space:]]*TLS_KEY=/ {
    print "TLS_KEY=/etc/maludb/tls/server.key"
    seen_key=1
    next
  }
  { print }
  END {
    if (!seen_tls) print "TLS=true"
    if (!seen_cert) print "TLS_CERT=/etc/maludb/tls/server.crt"
    if (!seen_key) print "TLS_KEY=/etc/maludb/tls/server.key"
  }
' /etc/maludb/maludb-mc2dbd.conf.bak \
  | sudo tee /etc/maludb/maludb-mc2dbd.conf >/dev/null
sudo chown root:maludb /etc/maludb/maludb-mc2dbd.conf
sudo chmod 0640 /etc/maludb/maludb-mc2dbd.conf

sudo systemctl restart maludb-mc2dbd
```

Confirm the file contains the TLS settings and the listener restarted:

```bash
sudo awk -F= '
  /^(TLS|TLS_CERT|TLS_KEY)=/ { print }
' /etc/maludb/maludb-mc2dbd.conf
systemctl status maludb-mc2dbd --no-pager
```

Pass criterion: the config printout includes
`TLS=true`, `TLS_CERT=/etc/maludb/tls/server.crt`, and
`TLS_KEY=/etc/maludb/tls/server.key`; `systemctl status` shows
`Active: active (running)`.

Plain HTTP should now fail because the listener expects a TLS
handshake:

```bash
curl -i -sS http://127.0.0.1:5329/healthz | head
```

HTTPS should work. The `-k` flag is required for the bootstrap
self-signed certificate because it is not trusted by the OS certificate
store:

```bash
curl -fsSk https://127.0.0.1:5329/healthz
```

Expected: `ok`.

If you enabled bearer-token authentication in §6.4, include the token
on JSON-RPC calls over HTTPS. If you are in a new shell, set `TOKEN`
to the same value you wrote into `/etc/maludb/maludb-mc2dbd.conf`
before running this test:

```bash
curl -fsSk -X POST https://127.0.0.1:5329/ \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | jq .
```

To edit manually instead, set these lines in
`/etc/maludb/maludb-mc2dbd.conf`:

```conf
TLS=true
TLS_CERT=/etc/maludb/tls/server.crt
TLS_KEY=/etc/maludb/tls/server.key
```

Then run `sudo systemctl restart maludb-mc2dbd`.

---

## 7. Register a local model

MaluDB's reference local provider is llama.cpp. Bootstrap does not
build it (operator-controlled).

### 7.1 Build llama.cpp

llama.cpp uses a CMake build. The bootstrap installs `cmake` already,
but if you're building on a host that didn't go through bootstrap,
install it first:

```bash
sudo apt-get install -y cmake
```

Then build:

```bash
# CPU build: default and recommended for CPU-only hosts.
# This runs CMake with CMAKE_BUILD_TYPE=Release and GGML_CUDA=OFF.
make -C runtime

# CUDA build: optional. Use only when the NVIDIA driver and CUDA Toolkit
# are installed and nvcc is on PATH.
# This also uses CMAKE_BUILD_TYPE=Release.
make -C runtime cuda
```

The CPU build takes 2–5 minutes on commodity hardware. CUDA builds
take longer because of the kernel compilation; expect 10+ minutes
on a fresh checkout.

Common configure output:

```text
-- Warning: ccache not found - consider installing it for faster compilation or disable this warning with GGML_CCACHE=OFF
-- CMAKE_SYSTEM_PROCESSOR: x86_64
-- GGML_SYSTEM_ARCH: x86
-- Including CPU backend
-- x86 detected
-- Adding CPU backend variant ggml-cpu: -march=native
```

Those lines are normal. `ccache` is optional; missing `ccache` only
means rebuilds may be slower.

If you run the optional CUDA build on a host without the CUDA Toolkit,
CMake may stop with:

```text
-- Could not find nvcc, please set CUDAToolkit_ROOT.
CMake Error at ggml/src/ggml-cuda/CMakeLists.txt:267 (message):
  CUDA Toolkit not found
```

That error is OK for a CPU-only install. It means only the optional
CUDA path failed; it does not mean the MaluDB install failed. Continue
with the CPU build instead:

```bash
make -C runtime distclean
make -C runtime BUILD_TYPE=Release
```

Expected: `third_party/llama.cpp/build/bin/llama-cli` exists and
prints help when invoked.

```bash
ls third_party/llama.cpp/build/bin/llama-cli

# Install the binary as a real copy (NOT `ln -sf`). The maludb-modeld
# systemd unit hardens with ProtectHome=true, which hides /home/* from
# the service — a symlink into /home/$USER/maludb-core/... would not
# resolve from inside the service even though it works from your shell.
sudo install -m 0755 $(pwd)/third_party/llama.cpp/build/bin/llama-cli \
                     /usr/local/bin/llama-cli

# Install the shared libraries llama-cli depends on. They're all
# emitted under build/bin/, but llama-cli won't load them from there
# at runtime (RPATH points into the build tree, which is hidden by
# ProtectHome). Copy them into /usr/local/lib and reload ldconfig.
sudo install -m 0644 $(pwd)/third_party/llama.cpp/build/bin/lib*.so \
                     /usr/local/lib/
sudo ldconfig

# Verify
llama-cli --help | head
ldd /usr/local/bin/llama-cli | head   # no "not found" lines
```

### 7.2 Acquire a `.gguf` model

Pick whatever fits your GPU memory. For a smoke test, a 1B-parameter
quantized model is plenty:

```bash
sudo install -d -o maludb_modeld -g maludb /var/lib/maludb/models
# example — replace with your own gguf path
sudo curl -fsSL -o /var/lib/maludb/models/qwen2.5-0.5b.q4_k_m.gguf \
    https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf
sudo chown maludb_modeld:maludb /var/lib/maludb/models/*.gguf
```

### 7.3 Register provider, alias, and prompt template

```bash
sudo -u postgres psql -d maludb <<'SQL'
SET search_path TO maludb_core, public;

-- 1. Register the local-runtime provider
SELECT register_model_provider(
    'local-llama', 'local_runtime', 'llama-cli',
    NULL, 'internal');

-- 2. Bind an alias to a specific model file. Eight positional args:
--    p_alias, p_provider, p_model_identifier, p_model_path,
--    p_model_hash, p_quantization, p_context_length, p_runtime_params.
SELECT register_model_alias(
    'tiny',                                                      -- alias
    'local-llama',                                               -- provider
    'qwen2.5-0.5b-instruct',                                     -- model_identifier
    '/var/lib/maludb/models/qwen2.5-0.5b.q4_k_m.gguf',           -- model_path
    NULL,                                                        -- model_hash (optional)
    'Q4_K_M',                                                    -- quantization
    32768,                                                       -- context_length
    '{"temperature":0,"max_tokens":256}'::jsonb);                -- runtime_params

-- 3. Register a prompt template
SELECT register_prompt_template(
    'r10-greet',
    'Say hi to :name, briefly.');

-- 4. Verify
SELECT alias_name, provider_kind, model_path FROM malu$model_alias
JOIN malu$model_provider USING (provider_id) WHERE alias_name='tiny';
SQL
```

### 7.4 Start the model gateway

```bash
sudo systemctl enable --now maludb-modeld
systemctl status maludb-modeld --no-pager
```

Expected (truncated):

```text
● maludb-modeld.service - MaluDB Model Gateway Daemon (R1.0)
     Loaded: loaded (/etc/systemd/system/maludb-modeld.service; enabled; ...)
     Active: active (running) since ...
   Main PID: 12345 (bash)
      CGroup: /system.slice/maludb-modeld.service
             ├─12345 bash /usr/local/sbin/maludb_modeld
             └─12399 sleep 5

... maludb_modeld ... info maludb_modeld starting (poll=5s, llama=/usr/local/bin/llama-cli)
```

Pass criterion: `Active: active (running)`. `Main PID: ... (bash)` is
normal; `maludb_modeld` is a shell daemon. A child `sleep 5` process is
also normal while the daemon is idle between database polls.

If `systemctl status` says some lines were ellipsized, use `-l` or
read the journal:

```bash
systemctl status -l maludb-modeld --no-pager
sudo journalctl -u maludb-modeld -n 50 --no-pager
```

### 7.5 End-to-end test through the listener

```bash
set -euo pipefail

# Match the listener mode selected in §6.4/§6.5.
TLS_ENABLED=$(sudo awk -F= '/^TLS=/{print tolower($2)}' /etc/maludb/maludb-mc2dbd.conf | tail -n1)
if [ "$TLS_ENABLED" = "true" ]; then
  MALUDB_URL=https://127.0.0.1:5329/
  CURL_TLS=(-k)     # bootstrap cert is self-signed
else
  MALUDB_URL=http://127.0.0.1:5329/
  CURL_TLS=()
fi

TOKEN=$(sudo sed -n 's/^BEARER_TOKEN=//p' /etc/maludb/maludb-mc2dbd.conf | tail -n1 | sed 's/^"//; s/"$//')
if [ -n "${TOKEN:-}" ]; then
  AUTH_ARGS=(-H "Authorization: Bearer $TOKEN")
else
  AUTH_ARGS=()
fi

call_tool() {
  local id="$1"
  local name="$2"
  local args_json="$3"

  curl "${CURL_TLS[@]}" -fsS -X POST "$MALUDB_URL" \
    "${AUTH_ARGS[@]}" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n \
      --argjson id "$id" \
      --arg name "$name" \
      --argjson arguments "$args_json" \
      '{jsonrpc:"2.0", id:$id, method:"tools/call",
        params:{name:$name, arguments:$arguments}}')"
}

SID=$(call_tool 1 maludb.sessions.create \
  '{"account_name":"fieldtest","alias_name":"tiny","template_name":"r10-greet"}' \
  | jq -er '.result.structuredContent.session_id')
echo "session_id=$SID"

RID=$(call_tool 2 maludb.prompts.render \
  "$(jq -n --argjson sid "$SID" \
    '{session_id:$sid, template_name:"r10-greet", variables:{name:"world"}}')" \
  | jq -er '.result.structuredContent.render_id')
echo "render_id=$RID"

SUBMIT=$(call_tool 3 maludb.models.submit \
  "$(jq -n --argjson rid "$RID" '{render_id:$rid, alias_name:"tiny"}')")
echo "$SUBMIT" | jq '.result.structuredContent'

REQ=$(echo "$SUBMIT" | jq -er '.result.structuredContent.request_id')
echo "request_id=$REQ"

# Give maludb_modeld a polling interval or two to claim and complete it.
sleep 10

call_tool 4 maludb.responses.get \
  "$(jq -n --argjson req "$REQ" '{request_id:$req}')" \
  | jq '.result.structuredContent'
```

Pass criterion: the final JSON has `"pending": false` and a `response`
object with model output text.

If the response stays pending, check:

```bash
systemctl status -l maludb-modeld --no-pager
sudo journalctl -u maludb-modeld -n 80 --no-pager
```

If `curl` reports `Empty reply from server`, you are probably sending
plain HTTP to a listener that was switched to native TLS in §6.5. The
pasteable block above reads `TLS=true` from
`/etc/maludb/maludb-mc2dbd.conf` and uses `https://...` plus `-k`
automatically.

---

## 8. Logs

| Service | Log location |
|---|---|
| PostgreSQL 17 | `/var/log/postgresql/postgresql-17-main.log` |
| `maludb-mc2dbd` | `journalctl -u maludb-mc2dbd` |
| `maludb-modeld` | `journalctl -u maludb-modeld` |
| MaluDB invocation audit (DB) | `SELECT * FROM maludb_core.malu$mc2db_invocation ORDER BY started_at DESC LIMIT 10;` |
| MaluDB model run audit (DB) | `SELECT * FROM maludb_core.model_run_audit ORDER BY rendered_at DESC LIMIT 10;` |

---

## 9. Uninstall

There is no automated uninstall. Manual:

```bash
sudo systemctl disable --now maludb-mc2dbd maludb-modeld 2>/dev/null
sudo rm -f /etc/systemd/system/maludb-mc2dbd.service /etc/systemd/system/maludb-modeld.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/sbin/maludb_mc2dbd /usr/local/sbin/maludb_modeld
sudo rm -rf /etc/maludb /var/log/maludb
sudo userdel maludb_mc2dbd 2>/dev/null
sudo userdel maludb_modeld 2>/dev/null
sudo groupdel maludb       2>/dev/null
sudo -u postgres psql <<'SQL'
DROP DATABASE IF EXISTS maludb;
DROP ROLE IF EXISTS maludb_mc2dbd;
DROP ROLE IF EXISTS maludb_modeld;
SQL
sudo make -C ~/maludb-core uninstall PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config 2>/dev/null
```

PG 17 itself stays installed; if you need to remove it too:

```bash
sudo apt-get -y purge postgresql-17 postgresql-17-pgvector postgresql-17-pgaudit postgresql-17-partman postgresql-server-dev-17
sudo apt-get -y autoremove
```

---

## What this guide deliberately does NOT cover

- Backup and restore — operator's existing infra layer.
- High-availability / replication / failover — out of scope for the
  single-host install path; see `docs/v3/` for replication notes.
- PG performance tuning (`shared_buffers`, `work_mem`, etc.) — workload-specific.
- Cloud provider adapter configuration beyond the local llama path —
  see `docs/runtime.md`.
- Multi-tenant per-account authorization tuning — see the SVPOR
  registries and `malu$object_grant` patterns in `docs/admin-guide.md`.

For the field-test sign-off procedure that wraps this guide, see
[`field-test.md`](field-test.md).
