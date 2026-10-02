# gpulander

**Opportunistic AWS GPU grabber.** Point it at the GPU you want; it polls `run-instances` across
regions and availability zones (spot by default), and the instant capacity appears it lands one box,
writes `launched.json`, and **exits 0**. That's the whole trick: the exit is a *signal*. Run it under an
agent's background-task runner and the exit wakes the agent to SSH in, provision, and train — so a
multi-hour "wait for a scarce GPU" costs zero model tokens until there's actually something to do.

New Blackwell/Hopper SKUs (g7e, H200) are routinely `InsufficientInstanceCapacity` on **both** spot and
on-demand across every US region. gpulander exists to wait that out without you babysitting the console.

```bash
pip install gpulander

gpulander --list                              # the GPU SKU catalog
gpulander check --gpu rtxpro6000              # read-only: placement score, offered AZs, live spot $/hr
gpulander grab  --gpu rtxpro6000 --name job   # poll + grab (spot); writes launched.json; exit 0 on win
```

Needs the **AWS CLI** configured (a profile, env creds, or an instance role) and **bash**. Nothing is
launched by `--list` or `check`.

## Pick a GPU

Three ways to say what you want (choose one); the resolved list is tried cheapest / fewest-GPU first:

| selector | example | meaning |
|---|---|---|
| `--gpu NAME` | `--gpu rtxpro6000` | by GPU family (see table below) |
| `--min-vram GB` | `--min-vram 48` | cheapest single-GPU type with ≥ that per-GPU VRAM |
| `--instance T[,T2]` | `--instance g7e.2xlarge,g7e.4xlarge` | exact instance type(s), in priority order |

`--gpu` names: `rtxpro6000` · `l40s` · `l4` · `a10g` · `h100` · `h200` · `a100-80` · `a100-40` · `t4` · `v100`.

### SKU catalog (`gpulander --list`)

| instance | GPU | VRAM | #GPU | ~$OD/hr | note |
|---|---|---|---|---|---|
| g7e.2xlarge | RTX PRO 6000 Blackwell | 96 GB | 1 | 3.36 | cheapest single 96 GB |
| g6e.2xlarge | L40S | 48 GB | 1 | 2.24 | great mid-size |
| g6.2xlarge | L4 | 24 GB | 1 | 0.98 | cheap |
| g5.2xlarge | A10G | 24 GB | 1 | 1.21 | cheap |
| g4dn.xlarge | T4 | 16 GB | 1 | 0.53 | tiny/cheap |
| p5.48xlarge | H100 | 80 GB | 8 | 98.3 | 8×H100, 640 GB total |
| p5e.48xlarge | H200 | 141 GB | 8 | ~110 | 8×H200, 1128 GB total — the only H200 SKU on AWS |
| p4de.24xlarge | A100-80 | 80 GB | 8 | 40.9 | 8×A100-80 |

> There is **no single-GPU H200 on AWS** — `--gpu h200` resolves to the 8×H200 `p5e.48xlarge` (big and
> pricey; ~$25/hr on spot, ~$110/hr on-demand). For a single big GPU, `--gpu rtxpro6000` (96 GB) is it.

## Commands

### `gpulander check` — read-only availability
For each resolved instance type: the **spot placement score** per region/AZ (1 = low … 10 = high chance
of actually getting spot), which **AZs offer** the type, and the **latest spot $/hr** (cheapest first).
Launches nothing, spends nothing. Use it to pick market + region before you `grab`.

### `gpulander grab` — poll until one lands, then exit
Loops `run-instances` across the chosen regions/AZs for the resolved type(s). On the first success it
writes `$GPULANDER_HOME/runs/<name>/launched.json` and **exits 0**. Every launched box carries a
user-data self-terminate (`--cap-hours`, default 4h) and `instance-initiated-shutdown-behavior=terminate`,
so it can never run forever even if nothing tears it down.

```bash
gpulander grab --gpu rtxpro6000 --name gemma --spot --deadline 240 --cap-hours 3
gpulander grab --gpu h200 --regions us-east-2 --name ornith --spot      # ~$25/hr 8×H200
gpulander grab --min-vram 48 --either --max-price 3.00 --name midsize
gpulander grab --instance g7e.2xlarge --dry-run                         # see the plan, launch nothing
```

### Options (grab)

| flag | default | meaning |
|---|---|---|
| `--spot` / `--on-demand` / `--either` | `--spot` | market (`--either` tries spot then on-demand per AZ) |
| `--max-price X` | 1.25× the catalog on-demand hint | spot ceiling $/hr |
| `--regions r1,r2` | `us-east-1,us-east-2,us-west-2` | where to hunt |
| `--name TAG` | `grab` | instance Name tag + runtime dir |
| `--deadline MINS` | `240` | give up after N minutes → exit 7 |
| `--cap-hours H` | `4` | box self-terminates after H hours (cost guard) |
| `--profile P` | `$AWS_PROFILE` / `$GPULANDER_PROFILE` / default chain | AWS profile |
| `--dry-run` | off | resolve + print the plan; launch nothing |

## The background-exit pattern (why `grab` exits instead of training)

`grab` deliberately does **only** the grab, then exits — it does not run the training. That keeps the
wait dumb and token-free, and makes the win an *event*:

```
Bash(run_in_background):  gpulander grab --gpu rtxpro6000 --name gemma --spot
   └─ detached shell polls across turns, spending no model tokens
   └─ on the first i-… it writes launched.json and `exit 0`
   └─ the EXIT re-invokes the agent (same stream as a task notification)
   └─ the agent reads launched.json and does the smart part: SSH, provision, train, hand off
```

Exit codes double as typed wake reasons so the woken agent can branch without parsing logs:

| code | meaning |
|---|---|
| `0` | grabbed — see `launched.json` (`{id, region, az, instance, market, key}`) |
| `7` | deadline reached, no capacity |
| `2` | bad args / setup error |

## Agent skill

The package ships a `SKILL.md` card (trigger-phrase description + the recipe) for Claude Code / Codex /
other agent runtimes. Install or inspect it straight from the CLI:

```bash
gpulander --skill            # print the SKILL.md card
gpulander --skill list       # one-line name + summary
gpulander --skill export     # tar of a gpulander/ skill dir (SKILL.md + the script) to stdout
gpulander --skill install    # install into ~/.claude/skills, ~/.codex/skills, ~/.agents/skills
```

`install` is hash-guarded: if you've edited an installed `SKILL.md`, an upgrade leaves it alone.

## Environment

| var | default | meaning |
|---|---|---|
| `GPULANDER_HOME` | `~/.gpulander` | runtime/state root (`runs/<name>/` holds the SSH key, `launched.json`, `status`) |
| `GPULANDER_PROFILE` | — | default AWS profile when `--profile` isn't given |

Per-run state (an ed25519 keypair, `launched.json`, `status`) lives in `$GPULANDER_HOME/runs/<name>/`.
The keypair and SG (`gpulander-<name>`) are created per region on demand; SSH ingress is opened only from
the caller's current public IP (`/32`).

## Requirements

- **AWS CLI v2**, configured with credentials that can `ec2 run-instances` / `describe-*` /
  `get-spot-placement-scores` and `ssm get-parameter` (for the Deep Learning base AMI).
- **bash** and **ssh-keygen** on `PATH`.
- Enough **vCPU service quota** for G/P spot or on-demand in your target regions (one `*.2xlarge` = 8 vCPU).

## License

MIT.
