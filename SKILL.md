---
name: gpulander
description: Grab an AWS GPU (spot/on-demand) across US regions/AZs for a training run, waiting out capacity shortages. Use when the user says grab/rent/spin up/land a GPU, needs an H200/H100/RTX-PRO-6000/L40S/A10G box, wants cheap spot GPU for training, or asks to check AWS GPU availability or price.
---
<!-- managed by gpulander: updated on upgrade; edit freely and it will be left alone -->
# gpulander (opportunistic AWS GPU grabber)

## The recipe
```bash
gpulander check --gpu rtxpro6000              # 1. available? price? (score/AZs/spot$ — no launch)
gpulander grab  --gpu rtxpro6000 --name job   # 2. poll+grab (spot); writes launched.json; exit 0 on win
```
Run step 2 under an agent's `run_in_background` — the EXIT on grab re-invokes the agent to SSH in,
provision, and train. Full manual: `gpulander --help`; per-command: `grab --help` / `check --help`.

## Pick a GPU
- `--gpu rtxpro6000` 96GB (~$1.92 spot) · `--gpu l40s` 48GB · `--gpu a10g|l4` 24GB · `--gpu h200` = 8xH200 141GB (~$25 spot).
- or `--min-vram 48` (cheapest single-GPU ≥48GB) · or `--instance g7e.2xlarge`. `gpulander --list` = full catalog.

## Narrow or widen
- spot is the default; add `--on-demand` or `--either` to widen · `--regions us-east-2,us-west-2` ·
  `--max-price 3.00` · `--deadline 240` (exit 7 if none) · `--cap-hours 3` (box self-terminates).

## Good to know
- Scarce new GPUs (g7e, H200) can be `InsufficientInstanceCapacity` on BOTH spot and on-demand — `check` first.
- No single-GPU H200 on AWS; `--gpu h200` = 8xH200 p5e.48xlarge (big/pricey). 96GB single-GPU = g7e.
- Exit codes: 0 grabbed (launched.json) · 7 deadline/no-capacity · 2 error.
- State lives under $GPULANDER_HOME (default ~/.gpulander); set --profile or $AWS_PROFILE for creds.

## When to use
Whenever a GPU box is needed for a quick/cheap training run and you'd rather wait out AWS capacity than
babysit the console.
