# penny-vast v5: Penny Royal v3.0.2 + Orca NVFP4 on one Vast RTX PRO 6000

Image `ghcr.io/jpezzulli/sglang-rtxpro6000:v3.0.2` (Fedora 44, user penny, has git + curl-minimal, no sshd/apt-get/sudo).
Model pinned: `jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664` (135.25 GB).

## Flow
1. Vast Entrypoint args decode `PENNY_BOOTSTRAP_B64` -> `/cache/bootstrap.sh`.
2. `bootstrap.sh` shallow-fetches this repo. First boot uses `PENNY_REPO_REF`. Later boots use `/cache/penny-ref` when
   that file is a release tag (`POST /upgrade`). Private repo via `GH_TOKEN`, sent as an HTTP header through
   `GIT_CONFIG_*` env, never in argv/URL/.git/config/logs. A `vN.N` ref must exist as `refs/tags/…` before checkout.
   3 tries; then cached copy from the last boot (`/cache/penny-vast`); then embedded `PENNY_BOOT_B64`+`PENNY_CTL_B64`;
   else `FATAL` + exit 1. Unsets GH_TOKEN. A failed fetch keeps the cached scripts and the model.
3. `boot.sh` checks sha256 of the vendored upstream start files (`upstream/`, identical to tag pennyroyal-v3.0.2),
   patches them (model dir from `$PENNY_MODEL_DIR`, `NIXL=off`, HiCache and context from the environment,
   `--host` from `PENNY_BIND_HOST`, `--served-model-name flash-next --api-key`),
   verifies each patch landed exactly once, optional Tailscale, then execs `ctl.py`.
4. `ctl.py` (:8002) checks HF metadata (revision must match, size), checks disk, downloads with `hf download --revision`
   (4 tries on network errors or an incomplete result), writes `.complete`, then starts SGLang (:8001) in `PENNY_MODE`
   (default **plain**). If SGLang exits on its own it is restarted up to `PENNY_MAX_RESTARTS` (3) times, 20 s apart;
   stops caused by /switch, /mode, or /config do not count, and each manual launch resets the budget.

## Pitfalls handled
- Entrypoint mode only: args start with `exec`, `--raw` before `--args`, `--args` last. No `--ssh --direct` (apt-get missing -> stopped).
- Vast env/args are frozen at create. First boot reads `PENNY_REPO_REF` (this release: **v5.2**), `PENNY_MODE`,
  `PENNY_HICACHE_GB`, `PENNY_MODEL`. After that, `/cache/config.json` and `/cache/penny-ref` win, and the model stays
  in `/cache/models`. Changing them does not need a new instance or `vastai recycle` (recycle wipes the disk).
  **Change mode, HiCache, context, or model**: `POST /config` (auth). SGLang restarts; the instance stays.
  **Change scripts**: `POST /upgrade?ref=v5.x` records a release tag. `vastai reboot instance <id>` fetches that tag
  (`/cache` and the model stay). Tag `v5.2` on the default-branch merge commit of this release. Do not tag the PR
  branch, and do not move `v5.1` or any older tag. The next release is a new tag on its own merge commit.
- `NIXL=off`. HiCache = min(PENNY_HICACHE_GB=48, PENNY_RAM_GB-100); refuses to start below 108 GB rented RAM, and
  refuses to start when PENNY_RAM_GB is missing.
- Tailscale (optional, userspace, no TUN): every step checked; "ok" only after `tailscale status --json` reports
  BackendState=Running and both `serve`s succeeded. Then SGLang and ctl bind **127.0.0.1** only, and the tailnet gets
  tcp/8000 → 127.0.0.1:8001 and tcp/8002 → 127.0.0.1:8002. `PENNY_PUBLIC_BIND=1` keeps the old 0.0.0.0 bind.
  No `TS_AUTHKEY`: bind 0.0.0.0 and print `WARN ports 8001/8002 are public plain HTTP`. Tailscale failure also stays
  on 0.0.0.0 (reachable from the internet only if the instance was created with `-p`).
  `TS_TAGS` defaults to empty. `tailscale up` gets `--advertise-tags` only when `TS_TAGS` is non-empty, because the
  auth key is not tagged.
  PENNY_RAM_GB must be the offer's RAM (gVisor cgroup showed 538 GB on a 189 GB rental).
- Default `plain` (Chinese ~46% faster without FR-Spec); `POST /mode?m=frspec` for English/code. FR-Spec is refused if
  the model's tokenizer.json sha256 is not 0997f410... (all three whitelisted models pass).
- API key: SGLang prints server_args with `api_key` in clear. ctl.py reads SGLang stdout/stderr through a pipe and replaces
  the key with `<API_KEY>` before it reaches the container log (`vastai logs`), /cache/logs or /log. Residual: the key is
  in SGLang's argv inside the container and in the Vast instance env (visible to whoever holds the Vast account).

## ctl.py (Bearer PENNY_API_KEY on every endpoint)
GET `/status`, `/models`, `/log?f=server|download|boot|bootstrap|server-frspec|server-plain&n=80`, `/smi`;
POST `/mode?m=frspec|plain`, `/switch?model=<org/repo@40-hex>[&m=plain|frspec]`,
`/config?m=plain|frspec&hicache_gb=8..48&context=65536|131072|262144|524288&model=<org/repo@40-hex>`,
`/upgrade?ref=vN.N` (optional patch, `vN.N.N`).
Model must be in `models.allow` (strict regex, model dir confined to the models root, disk checked before download;
the old server keeps serving until the new model is ready). HiCache above 48 or above `PENNY_RAM_GB-100` is rejected.
`/upgrade` accepts only a release-tag shape. When ctl can see the remote without `GH_TOKEN` it also requires the tag
to exist; otherwise the next reboot's bootstrap checks `refs/tags/<ref>` and fetches it (ctl never sees `GH_TOKEN`).
No arbitrary exec: subprocess only with fixed arg lists, never shell=True.

## Env
First boot, required: PENNY_API_KEY, PENNY_REPO_URL, PENNY_REPO_REF (tag), PENNY_BOOTSTRAP_B64, PENNY_RAM_GB.
First boot, optional: GH_TOKEN, PENNY_MODE (plain), PENNY_HICACHE_GB (48), PENNY_MODEL (whitelisted spec),
TS_AUTHKEY, TS_TAGS (empty), PENNY_PUBLIC_BIND (unset), HF_TOKEN, PENNY_BOOT_B64/PENNY_CTL_B64.
Kept in `/cache` after that (edit with the API, not a new instance): mode, HiCache, context length, model, script tag.
Create command: `vast/create-instance.sh.example`.

## Risks (read before renting)
- **With Tailscale up, 8001 and 8002 bind 127.0.0.1.** `tailscale serve` publishes them on the tailnet (tcp/8000 → SGLang,
  tcp/8002 → ctl), WireGuard-encrypted. **Vast `-p` cannot do this.** It publishes the public proxy onto the container's
  eth0, and this image runs Tailscale in userspace (`--tun=userspace-networking`), so there is no tailnet address for
  Docker or Vast to bind. A published `-p 8001:8001` while the process listens on 127.0.0.1 is a public port with nothing
  behind it. Tailnet create (default in the example): omit `-p` and set `TS_AUTHKEY`. Public create: `TAILNET=0`, which
  passes `-p 8001:8001 -p 8002:8002` and no `TS_AUTHKEY`; boot binds 0.0.0.0 and prints
  `WARN ports 8001/8002 are public plain HTTP` (the Bearer key and prompts cross the internet unencrypted).
  **Old public bind while Tailscale is still up**: `PENNY_PUBLIC_BIND=1` plus the `-p` flags.
- **No Tailscale means public plain HTTP** on whatever `-p` you published. Rotate the key per instance and destroy the instance when done.
- **The API key is stored in the Vast instance env** (visible to anyone with the Vast account/API key, e.g. `vastai show
  instance`), and **in SGLang's process arguments** inside the container (`--api-key`, visible to `ps` in the container).
  Logs are masked (`<API_KEY>`), but those two places cannot be.
- GH_TOKEN (read-only PAT) also sits in the Vast env; scope it to this repo, Contents read-only, short expiry.
- ctl.py has no rate limiting; a leaked key allows downloads of the whitelisted models (disk-checked) and restarts.

## Tests (no GPU / no real model)
`bash test/run_sim.sh <fakeroot> <tokenizer.json>` - fakeroot = upstream `configs/pennyroyal/` of pennyroyal-v3.0.2 in a git
repo; the real patched upstream start files run end to end with stub `sglang`/`python`/`hf` and a fake HF API.
`bash test/ts_test.sh boot.sh` - Tailscale block with stub tailscale/tailscaled (ok binds 127.0.0.1 and serves 8000+8002 / up fail / not Running / serve fail / download fail / PENNY_PUBLIC_BIND=1 stays on 0.0.0.0).
