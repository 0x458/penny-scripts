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
   After SGLang answers `GET /health`, the running ref is stored in `/cache/penny-ref-good` and the script tree is
   copied to `/cache/penny-vast-good`. That ref is the `.penny-ref` file inside the script tree (written on a
   successful fetch, or `embedded` for the embedded fallback). A cache fallback keeps the cached tree's
   `.penny-ref`; it does not copy the tag that failed to fetch out of `/cache/penny-ref`. A later ref that exits
   or never becomes healthy is put back automatically (see Recovery). The model directory is not part of that copy.
   SGLang in this image allows `/health` without the API key (`auth.py` prefixes `/health`), so the check sends no key.
3. `boot.sh` checks sha256 of the vendored upstream start files (`upstream/`, identical to tag pennyroyal-v3.0.2),
   patches them (model dir from `$PENNY_MODEL_DIR`, `NIXL=off`, HiCache and context from the environment,
   `--host` from `PENNY_BIND_HOST`, `--served-model-name flash-next --api-key`,
   YaRN only when context is 524288, server reasoning default `xhigh`),
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
  (`/cache` and the model stay). If that ref does not get SGLang healthy, boot rolls back to `/cache/penny-ref-good`
  (see Recovery). Tag `v5.2` on the default-branch merge commit of this release. Do not tag the PR
  branch, and do not move `v5.1` or any older tag. The next release is a new tag on its own merge commit.
- `NIXL=off`. Default HiCache is 48 GB, then `min(wanted, PENNY_RAM_GB-100)`. Boot refuses to start below 108 GB
  rented RAM, and refuses to start when PENNY_RAM_GB is missing. `POST /config` uses that same ceiling, so a 189 GB
  rental can set HiCache above 48. With `PENNY_RAM_GB` unset, ctl keeps the ceiling at 48.
- Tailscale (optional, userspace, no TUN): every step checked; "ok" only after `tailscale status --json` reports
  BackendState=Running and both `serve`s succeeded. Then SGLang and ctl bind **127.0.0.1** only, and the tailnet gets
  tcp/8000 → 127.0.0.1:8001 and tcp/8002 → 127.0.0.1:8002. `PENNY_PUBLIC_BIND=1` keeps the old 0.0.0.0 bind.
  No `TS_AUTHKEY`: bind 0.0.0.0 and print `WARN ports 8001/8002 are public plain HTTP`. If `tailscale up` or `serve`
  does not succeed within the timeout, boot stays on 0.0.0.0 and prints one `WARN tailscale` line (see Recovery).
  `TAILNET=1` publishes no `-p`, so that fallback is not reachable from outside the container.
  `TS_TAGS` defaults to empty. `tailscale up` gets `--advertise-tags` only when `TS_TAGS` is non-empty, because the
  auth key is not tagged. `TS_HOSTNAME` defaults to `vast-penny`.
  Before you create or rebuild, delete any offline node that still holds that hostname in the Tailscale admin
  console. If it is still registered, Tailscale renames the new node (for example `vast-penny-1`) and clients that
  hardcode the old name cannot connect. Boot does not exit: it prints `WARN tailscale hostname` with the actual name
  and the tailnet IP. Use that IP, or delete the old node and reboot.
  PENNY_RAM_GB must be the offer's RAM (gVisor cgroup showed 538 GB on a 189 GB rental).
- Default `plain` (Chinese ~46% faster without FR-Spec); `POST /mode?m=frspec` for English/code. FR-Spec is refused if
  the model's tokenizer.json sha256 is not 0997f410... (all three whitelisted models pass).
- Flash-Next's native context is 262144. Upstream always passes YaRN factor 2.0
  (`original_max_position_embeddings` 262144) to reach 524288. At 262144 that override rescales RoPE and hurts
  short text, so the generated start file adds `--json-model-override-args` only when `CONTEXT_LENGTH` is 524288.
  Contexts 65536, 131072, and 262144 launch with no YaRN override. `POST /config` changes context on the next
  SGLang start; the same start file picks the arm from `PENNY_CONTEXT_LENGTH`, so no reboot is required.
- Pennyroyal `reasoning-effort.sh` defaults to medium. Generated start files set `PENNY_REASONING_EFFORT` to
  `xhigh` when it is unset, which becomes `--default-chat-template-kwargs` with `reasoning_effort=xhigh`.
  A request that sends `reasoning_effort` still overrides that server default. An explicit
  `PENNY_REASONING_EFFORT` in the environment (for example `low`) still wins over `xhigh`.
- Mode `27b` writes `start-27b.sh` only. `start-plain.sh` and `start-frspec.sh` stay the Flash-Next
  scripts, and Flash-Next still refuses rented RAM under 108 GB. See below.
- API key: SGLang prints server_args with `api_key` in clear. ctl.py reads SGLang stdout/stderr through a pipe and replaces
  the key with `<API_KEY>` before it reaches the container log (`vastai logs`), /cache/logs or /log. Residual: the key is
  in SGLang's argv inside the container and in the Vast instance env (visible to whoever holds the Vast account).

## ctl.py (Bearer PENNY_API_KEY on every endpoint)
GET `/status`, `/models`, `/log?f=server|download|boot|bootstrap|server-frspec|server-plain|server-27b&n=80`, `/smi`;
POST `/mode?m=frspec|plain|27b`, `/switch?model=<org/repo@40-hex>[&m=plain|frspec|27b]`,
`/config?m=plain|frspec|27b&hicache_gb=8..(PENNY_RAM_GB-100)&context=65536|131072|262144|524288&model=<org/repo@40-hex>`,
`/upgrade?ref=vN.N` (optional patch, `vN.N.N`).
Model must be in `models.allow` (strict regex, model dir confined to the models root, disk checked before download;
the old server keeps serving until the new model is ready). HiCache above `PENNY_RAM_GB-100` is rejected
(`hicache_gb must be 8..<cap>`). With `PENNY_RAM_GB` unset the ceiling stays 48.
`/upgrade` accepts only a release-tag shape. When ctl can see the remote without `GH_TOKEN` it also requires the tag
to exist; otherwise the next reboot's bootstrap checks `refs/tags/<ref>` and fetches it (ctl never sees `GH_TOKEN`).
`verified=true` means that `git ls-remote` showed the exact `refs/tags/<ref>`. `verified=false` means the tag text
was saved and ctl did not get that proof: the remote did not answer (private repo, network, or timeout) or
`PENNY_REPO_URL` is not https. It is not a rejection. A tag ls-remote can see and that is missing is HTTP 400, and
`/cache/penny-ref` stays unchanged. On the next reboot, bootstrap (it has `GH_TOKEN`) checks the tag and fetches it.
A failed fetch keeps the cached scripts and the model.
No arbitrary exec: subprocess only with fixed arg lists, never shell=True. `/cache/mode` and `/cache/active` are
replaced with `rename`, same as `config.json`.

## Env
First boot, required: PENNY_API_KEY, PENNY_REPO_URL, PENNY_REPO_REF (tag), PENNY_BOOTSTRAP_B64, PENNY_RAM_GB.
First boot, optional: GH_TOKEN, PENNY_MODE (plain), PENNY_HICACHE_GB (48), PENNY_MODEL (whitelisted spec),
TS_AUTHKEY, TS_HOSTNAME (vast-penny), TS_TAGS (empty), PENNY_PUBLIC_BIND (unset), HF_TOKEN, PENNY_BOOT_B64/PENNY_CTL_B64.
Kept in `/cache` after that (edit with the API, not a new instance): mode, HiCache, context length, model, script tag,
and `/cache/penny-ref-good` (last ref that brought SGLang up).
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

## Recovery

Container stdout is what `vastai logs <instance_id>` prints. The same lines are in `/cache/logs/boot.log` and
`/cache/logs/bootstrap.log`.

**Tailscale did not come up.** `up` or `serve` missed its timeout. Boot binds **0.0.0.0** and prints one line,
`WARN tailscale up/serve failed within the timeout`. Read it with `vastai logs <instance_id>`. **`TAILNET=1` does not
pass `-p`**, and Vast cannot add that publish later, so the 0.0.0.0 bind is reachable only inside the container.
Nothing on the public internet or the tailnet can open 8001 or 8002 until Tailscale is up. Fix the auth key or the
tailnet, then `vastai reboot instance <id>`. The reboot retries Tailscale. The disk and the model stay. A new
instance with `TAILNET=0` is what publishes `-p 8001:8001 -p 8002:8002`; that is a different machine and downloads
the model again.

**Tailscale renamed the node.** `tailscale up` asks for `TS_HOSTNAME` (default `vast-penny`). An offline node that
still holds that name makes Tailscale assign another one, such as `vast-penny-1`. Clients that hardcode
`vast-penny` then cannot connect. Boot does not exit. It prints `WARN tailscale hostname` with the name it actually
got and the tailnet IP. Delete the old node in the Tailscale admin console before you rebuild, or point clients at
that tailnet IP. After the old node is gone, a reboot lets this machine take the expected name.

**No sshd in this image.** `ghcr.io/jpezzulli/sglang-rtxpro6000:v3.0.2` does not ship sshd (and has no apt-get, so
Vast cannot inject one). You manage the machine over the tailnet and ctl (`tcp/8002`, Bearer `PENNY_API_KEY`):
`/status`, `/log`, `/config`, `/upgrade`. When the tailnet is down, the only remaining controls are
`vastai logs <instance_id>` and `vastai reboot instance <id>`.

**A script tag did not start.** `/cache/penny-ref-good` is the last ref whose SGLang answered `/health`, and
`/cache/penny-vast-good` is that script tree. If a fetched ref exits or `/health` does not come up within
`PENNY_HEALTH_TIMEOUT` (default 1800s), bootstrap kills that process, writes the good ref back to `/cache/penny-ref`,
restores the good scripts, and starts them. The log line says `rolled back to <ref>` and `no recycle`. The model
files are not in the script snapshot, so they are not downloaded again. `vastai logs <instance_id>` shows the WARN.
To retry a fixed tag: `POST /upgrade?ref=v5.x`, then `vastai reboot instance <id>`.

## 27B on one RTX 5090

`PENNY_MODE=27b` serves Qwen3.8-27B on one RTX 5090 (sm_120, 32607 MiB, 31.843 GiB). Host RAM on that
offer can be about 31 GB, so the host HiCache pool stays off. Flash-Next is a different mode and still
uses `start-plain.sh` / `start-frspec.sh`.

Pinned target (not TBD): `Ar4ikov/Qwen3.8-27B-Uncensored-AWQ-W4A16-ASYM@d07667d03a5dbfebd02a4eaa55348b97f35d1935`,
AWQ W4A16 asymmetric group 128 (`compressed-tensors`) of `orcarouter/Qwen3.8-27B-Uncensored`. Weight files
19,547,867,688 bytes (18.205 GiB). HF 2026-10-21. Override with `PENNY_27B_MODEL` only when that spec is
in `models.allow`. Draft, downloaded with it and not a `/switch` target:
`incoai/Qwen3.8-27B-DFlash2@015e795645c74b1a0eeef3b570031fb62e769bc5`, unquant BF16, weight files
3,848,817,896 bytes (3.584 GiB). `PENNY_27B_DRAFT` may replace it. `orcarouter` FP8 plus this draft is
32.332 GiB of weights, over the card. The same base as NVFP4 is 26.577 GiB of weights; with the GDN
state and a graph reserve it leaves about 51264 KV tokens, so the AWQ checkpoint is the one that fits.

Budget, binary GiB, fp8 KV = 16 full-attention layers × 2 × 4 KV heads × 256 × 1 = 32768 bytes/token.
GDN state per slot = 48 linear layers × (48×128×128×4 + 10240×3×2) = 146.8125 MiB. Draft KV is the
decode window, 4 requests × 2048 × 10240 = 80 MiB, not the full context.

| piece | size |
| --- | --- |
| card | 32607 MiB = 31.843 GiB |
| static pool at `--mem-fraction-static 0.86` | 27.385 GiB |
| left for graphs | 4.458 GiB |
| AWQ weights + DFlash2 weights | 21.790 GiB |
| 8 GDN slots (`--max-mamba-cache-size 8`) | 1.147 GiB |
| draft KV window | 80 MiB |
| fragmentation slack | 512 MiB |
| left for target KV | 3.870 GiB = 126806 tokens |

Page size is 64, so the context is **126784** (`--context-length` and `--max-total-tokens`). Smaller
allowed values: 32768, 65536, 98304. YaRN factor 2.0 is injected only when context is 524288, which
this card does not use. DFlash stays `--speculative-algorithm DFLASH`, 8 draft tokens, window 2048,
draft quant `unquant`. NIXL stays off. Reasoning default stays `xhigh`.

HiCache: rented RAM under 108 GB, or `PENNY_RAM_GB` missing, forces `PENNY_27B_HICACHE_GB=0` (the
start file's default is 0). At 108 GB or more the cap is `min(96, PENNY_RAM_GB-100)`, and 0 is still
legal. The upstream 96 GB pool is not allocated on a 31 GB machine. Other knobs:
`PENNY_27B_CONTEXT_LENGTH`, `PENNY_27B_QUANTIZATION` (default `compressed-tensors`),
`PENNY_27B_MEM_FRACTION` (default `0.86`), `PENNY_27B_MAMBA_SLOTS` (default `8`).

## Tests (no GPU / no real model)
`bash test/run_sim.sh <fakeroot> <tokenizer.json>` - fakeroot = upstream `configs/pennyroyal/` of pennyroyal-v3.0.2 in a git
repo; the real patched upstream start files run end to end with stub `sglang`/`python`/`hf` and a fake HF API.
`bash test/ts_test.sh boot.sh` - Tailscale block with stub tailscale/tailscaled (ok binds 127.0.0.1 and serves 8000+8002 / up fail / not Running / serve fail / download fail / PENNY_PUBLIC_BIND=1 stays on 0.0.0.0 / renamed hostname WARNs with the real name and tailnet IP and still comes up). A failed up/serve keeps 0.0.0.0 and the WARN names `vastai logs` and `vastai reboot instance`. Both test scripts `unset TS_AUTHKEY TS_TAGS GH_TOKEN` before they set their own fakes.
