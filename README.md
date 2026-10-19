# penny-vast v5: Penny Royal v3.0.2 + Orca NVFP4 on one Vast RTX PRO 6000

Image `ghcr.io/jpezzulli/sglang-rtxpro6000:v3.0.2` (Fedora 44, user penny, has git + curl-minimal, no sshd/apt-get/sudo).
Model pinned: `jpezzulli/OrcaRouter-Qwen3.8-Flash-Next-Uncensored-ModelOpt-NVFP4@f24d2b68ff2814f24455ae86717be276619b5664` (135.25 GB).

## Flow
1. Vast Entrypoint args decode `PENNY_BOOTSTRAP_B64` -> `/cache/bootstrap.sh`.
2. `bootstrap.sh` shallow-fetches this repo (`PENNY_REPO_URL`, `PENNY_REPO_REF`; private repo via `GH_TOKEN`, sent as an
   HTTP header through `GIT_CONFIG_*` env, never in argv/URL/.git/config/logs). 3 tries; then cached copy from the last
   boot (`/cache/penny-vast`); then embedded `PENNY_BOOT_B64`+`PENNY_CTL_B64`; else `FATAL` + exit 1. Unsets GH_TOKEN.
3. `boot.sh` checks sha256 of the vendored upstream start files (`upstream/`, identical to tag pennyroyal-v3.0.2),
   patches them (model dir from `$PENNY_MODEL_DIR`, `NIXL=off`, HiCache, `--served-model-name flash-next --api-key`),
   verifies each patch landed exactly once, optional Tailscale, then execs `ctl.py`.
4. `ctl.py` (:8002) checks HF metadata (revision must match, size), checks disk, downloads with `hf download --revision`
   (4 tries on network errors or an incomplete result), writes `.complete`, then starts SGLang (:8001) in `PENNY_MODE`
   (default **plain**). If SGLang exits on its own it is restarted up to `PENNY_MAX_RESTARTS` (3) times, 20 s apart;
   stops caused by /switch or /mode do not count, and each manual launch resets the budget.

## Pitfalls handled
- Entrypoint mode only: args start with `exec`, `--raw` before `--args`, `--args` last. No `--ssh --direct` (apt-get missing -> stopped).
- env/args frozen at create, so the instance pins `PENNY_REPO_REF` to a **release tag** (`v5.1`); bootstrap logs the fetched sha.
  `vastai reboot instance <id>` re-runs bootstrap on the same tag (/cache and model kept).
  **Upgrade**: commit, tag `v5.2` (never move an existing tag), then create a new instance with `PENNY_REPO_REF=v5.2`
  (or `vastai recycle`, which applies the new env but wipes the disk -> model re-download, ~9 min for 135 GB).
- `NIXL=off`. HiCache = min(PENNY_HICACHE_GB=48, PENNY_RAM_GB-100); refuses to start below 108 GB rented RAM, and
  refuses to start when PENNY_RAM_GB is missing.
- Tailscale (optional): every step checked; "ok" only after `tailscale status --json` reports BackendState=Running and
  `serve` succeeded; any failure is a WARN and Penny still starts.
  PENNY_RAM_GB must be the offer's RAM (gVisor cgroup showed 538 GB on a 189 GB rental).
- Default `plain` (Chinese ~46% faster without FR-Spec); `POST /mode?m=frspec` for English/code. FR-Spec is refused if
  the model's tokenizer.json sha256 is not 0997f410... (all three whitelisted models pass).
- API key: SGLang prints server_args with `api_key` in clear. ctl.py reads SGLang stdout/stderr through a pipe and replaces
  the key with `<API_KEY>` before it reaches the container log (`vastai logs`), /cache/logs or /log. Residual: the key is
  in SGLang's argv inside the container and in the Vast instance env (visible to whoever holds the Vast account).

## ctl.py (Bearer PENNY_API_KEY on every endpoint)
GET `/status`, `/models`, `/log?f=server|download|boot|bootstrap|server-frspec|server-plain&n=80`, `/smi`;
POST `/mode?m=frspec|plain`, `/switch?model=<org/repo@40-hex>[&m=plain|frspec]` (must be in `models.allow`; strict regex,
model dir confined to the models root; disk checked before download; old server keeps serving until the new model is ready).
No arbitrary exec: subprocess only with fixed arg lists, never shell=True.

## Env
Required: PENNY_API_KEY, PENNY_REPO_URL, PENNY_REPO_REF (tag), PENNY_BOOTSTRAP_B64, PENNY_RAM_GB. Optional: GH_TOKEN,
PENNY_MODE (plain), PENNY_HICACHE_GB (48), PENNY_MODEL (whitelisted spec), TS_AUTHKEY + TS_TAGS, HF_TOKEN, PENNY_BOOT_B64/PENNY_CTL_B64.
Create command: `vast/create-instance.sh.example`.

## Risks (read before renting)
- **Ports 8001 (SGLang) and 8002 (ctl) are public plain HTTP.** The Bearer key and all prompts/answers cross the
  internet unencrypted; anyone on the path can read the key and then use/stop/switch the server. Prefer Tailscale
  (8000 over the tailnet, WireGuard-encrypted) for real use, rotate the key per instance, and destroy the instance when done.
- **The API key is stored in the Vast instance env** (visible to anyone with the Vast account/API key, e.g. `vastai show
  instance`), and **in SGLang's process arguments** inside the container (`--api-key`, visible to `ps` in the container).
  Logs are masked (`<API_KEY>`), but those two places cannot be.
- GH_TOKEN (read-only PAT) also sits in the Vast env; scope it to this repo, Contents read-only, short expiry.
- ctl.py has no rate limiting; a leaked key allows downloads of the whitelisted models (disk-checked) and restarts.

## Tests (no GPU / no real model)
`bash test/run_sim.sh <fakeroot> <tokenizer.json>` - fakeroot = upstream `configs/pennyroyal/` of pennyroyal-v3.0.2 in a git
repo; the real patched upstream start files run end to end with stub `sglang`/`python`/`hf` and a fake HF API.
`bash test/ts_test.sh boot.sh` - Tailscale block with stub tailscale/tailscaled (ok / up fail / not Running / serve fail / download fail).
