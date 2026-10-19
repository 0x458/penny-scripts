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
   (4 tries on network errors), writes `.complete`, then starts SGLang (:8001) in `PENNY_MODE` (default **plain**).

## Pitfalls handled
- Entrypoint mode only: args start with `exec`, `--raw` before `--args`, `--args` last. No `--ssh --direct` (apt-get missing -> stopped).
- env/args frozen at create: scripts live here; change -> push -> `vastai reboot instance <id>` (bootstrap re-pulls; /cache and model kept).
  So use a branch for `PENNY_REPO_REF` (e.g. `main`); the fetched sha is logged. A pinned sha can only change by recreate.
- `NIXL=off`. HiCache = min(PENNY_HICACHE_GB=48, PENNY_RAM_GB-100); refuses to start below 108 GB rented RAM.
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
Required: PENNY_API_KEY, PENNY_REPO_URL, PENNY_BOOTSTRAP_B64, PENNY_RAM_GB. Optional: PENNY_REPO_REF (main), GH_TOKEN,
PENNY_MODE (plain), PENNY_HICACHE_GB (48), PENNY_MODEL (whitelisted spec), TS_AUTHKEY + TS_TAGS, HF_TOKEN, PENNY_BOOT_B64/PENNY_CTL_B64.
Create command: `vast/create-instance.sh.example`.

## Tests (no GPU / no real model)
`bash test/run_sim.sh <fakeroot> <tokenizer.json>` - fakeroot = upstream `configs/pennyroyal/` of pennyroyal-v3.0.2 in a git
repo; the real patched upstream start files run end to end with stub `sglang`/`python`/`hf` and a fake HF API.
