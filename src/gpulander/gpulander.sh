#!/bin/bash
# gpulander — opportunistic AWS GPU grabber for training (and other short GPU jobs).
#
# Polls run-instances across ACCOUNTS/regions/AZs (spot and/or on-demand) for a GPU instance that
# matches what you asked for, and EXITS 0 the moment it lands one (writing launched.json). The exit is
# the signal: when this runs under an agent's `run_in_background`, the exit re-invokes the agent to do
# the intelligent part (provision + train + hand off). It never does the training itself.
#
# Modes:
#   gpulander --list                 # print the GPU SKU catalog (instance -> GPU / VRAM / vCPU / #GPUs)
#   gpulander accounts               # list your configured AWS profiles + which account each maps to
#   gpulander --help | --skill       # usage for an LLM/agent to invoke it
#   gpulander check [selectors]      # READ-ONLY availability
#   gpulander grab [selectors] [opts]
#
# Selectors (pick ONE; priority order of the resolved instance list is cheapest/fewest-GPU first):
#   --instance t1[,t2...]   exact instance type(s), tried in the given order
#   --gpu NAME              rtxpro6000 | l40s | l4 | a10g | h100 | h200 | a100-80 | a100-40 | t4 | v100
#   --min-vram GB          any single-GPU type with per-GPU VRAM >= GB (prefers cheapest)
#
# Options:
#   --spot (default) | --on-demand | --either     market (either = try spot then on-demand per AZ)
#   --max-price X          spot ceiling $/hr (default: 1.25x the catalog on-demand hint)
#   --regions r1,r2        default: us-east-1,us-east-2,us-west-2
#   --profile p1[,p2,...]  AWS profile(s) = account(s) to poll. One, or a comma list to sweep several.
#                          Default: env AWS_PROFILE / GPULANDER_PROFILE, else the AWS default chain.
#   --name TAG             instance Name tag + runtime dir (default: grab)
#   --deadline MINS        give up after N minutes -> exit 7 (default: 240)
#   --cap-hours H          box self-terminates after H hours (cost guard; default: 4)
#   --dry-run              resolve + print what it WOULD launch, don't call run-instances
#
# Env:
#   GPULANDER_HOME     runtime/state root (default: ~/.gpulander)
#   GPULANDER_PROFILE  default AWS profile(s) if --profile is not given (comma list ok)
#
# Exit codes:  0 grabbed (see launched.json) · 7 deadline/no-capacity · 2 bad args/error
set -uo pipefail

GPULANDER_HOME="${GPULANDER_HOME:-$HOME/.gpulander}"

# ---------------- SKU catalog ----------------  instance | gpu | vram(GB,per-GPU) | vcpu | #gpus | ~ondemand$/hr/instance | note
read -r -d '' CATALOG <<'EOF'
g7e.2xlarge    RTX_PRO_6000_Blackwell  96   8    1   3.36   96GB Blackwell; cheapest single 96GB
g7e.4xlarge    RTX_PRO_6000_Blackwell  96   16   1   4.00   more host vCPU/RAM, same 1 GPU
g7e.8xlarge    RTX_PRO_6000_Blackwell  96   32   1   5.27   same 1 GPU
g7e.16xlarge   RTX_PRO_6000_Blackwell  96   64   1   10.5   same 1 GPU
g6e.2xlarge    L40S                    48   8    1   2.24   48GB, great mid-size
g6e.4xlarge    L40S                    48   16   1   3.00   48GB
g6.2xlarge     L4                      24   8    1   0.98   24GB, cheap
g5.2xlarge     A10G                    24   8    1   1.21   24GB, cheap
g4dn.xlarge    T4                      16   4    1   0.53   16GB, tiny/cheap
p3.2xlarge     V100                    16   8    1   3.06   16GB, legacy
p4d.24xlarge   A100                    40   96   8   32.8   8xA100-40 (320GB total)
p4de.24xlarge  A100                    80   96   8   40.9   8xA100-80 (640GB total)
p5.48xlarge    H100                    80   192  8   98.3   8xH100 (640GB total)
p5e.48xlarge   H200                    141  192  8   ~110   8xH200 (1128GB total) — only H200 SKU on AWS
p5en.48xlarge  H200                    141  192  8   ~115   8xH200, newer networking
EOF

catalog_table () {
  printf "%-15s %-24s %6s %6s %6s %8s  %s\n" INSTANCE GPU VRAM vCPU GPUs "\$OD/hr" NOTE
  echo "$CATALOG" | while read -r it gpu vram vcpu gpus od note; do
    [ -z "$it" ] && continue
    printf "%-15s %-24s %5sG %6s %6s %8s  %s\n" "$it" "$gpu" "$vram" "$vcpu" "$gpus" "$od" "$(echo "$note" | cut -c1-48)"
  done
}

SKILL_DIRNAME="gpulander"
SKILL_SUMMARY="Grab an AWS GPU (spot by default) across accounts/regions/AZs for a training run; polls until one lands, then exits."

help_main () {
cat <<'H'
gpulander — opportunistically grab an AWS GPU for a training run.

Polls run-instances across accounts/regions/AZs and lands the FIRST available matching GPU, then exits
(so an agent's run_in_background wakes to provision + train). Spot by default; on-demand is opt-in.

USAGE
  gpulander <command> [selector] [options]
  gpulander --help | --list | accounts | --skill [list|export|install]

COMMANDS
  check     READ-ONLY: availability (spot-placement score, offered AZs, live spot $/hr). No launch.
  grab      poll until a matching GPU launches; writes launched.json and exits 0.
  accounts  list your configured AWS profiles + which 12-digit account each maps to (read-only).
  --list    print the GPU SKU catalog (what you can hunt: instance -> GPU / VRAM / #GPU / $).

SELECTORS  (choose ONE; resolved list is cheapest / fewest-GPU first)
  --gpu NAME        rtxpro6000 | l40s | l4 | a10g | h100 | h200 | a100-80 | a100-40 | t4 | v100
  --min-vram GB     any SINGLE-GPU type with per-GPU VRAM >= GB
  --instance T[,T2] exact instance type(s), in priority order

OPTIONS
  --spot            spot only (DEFAULT)
  --on-demand       on-demand only
  --either          try spot then on-demand, per AZ
  --max-price X     spot ceiling $/hr                    (default: 1.25x the catalog on-demand hint)
  --regions r1,r2   comma list                           (default: us-east-1,us-east-2,us-west-2)
  --profile p1,p2   AWS profile(s) = account(s) to poll  (default: $AWS_PROFILE / $GPULANDER_PROFILE / default chain)
  --name TAG        instance Name tag + runtime dir       (default: grab)
  --deadline MINS   give up after N minutes -> exit 7     (default: 240)
  --cap-hours H     box self-terminates after H hours     (default: 4)  cost guard
  --dry-run         (grab) resolve + print what it WOULD try; launch nothing

MULTIPLE ACCOUNTS
  Each AWS profile in ~/.aws (SSO or keys) = one account/role. Name several with a comma list and
  gpulander sweeps them all each round; the FIRST account to land a box wins (launched.json records it).
    gpulander accounts                                        # discover your profiles + account ids
    gpulander grab --gpu rtxpro6000 --profile dev,prod,admin  # hunt across 3 accounts at once
  Set up a profile:  aws configure --profile NAME   (keys)  |  aws configure sso   (SSO)
  Refresh SSO creds: aws sso login --profile NAME

EXIT CODES
  0  grabbed a box  -> $GPULANDER_HOME/runs/<name>/launched.json {id,region,az,instance,market,profile,key}
  7  deadline reached, no capacity
  2  bad args / setup error

EXAMPLES
  gpulander --list                                           # the SKU menu (what you can hunt)
  gpulander accounts                                         # your profiles -> account ids
  gpulander check --gpu rtxpro6000 --profile dev,prod        # available? price? across 2 accounts
  gpulander grab  --gpu rtxpro6000 --name gemma --spot       # cheap 96GB Blackwell, spot
  gpulander grab  --gpu h200 --regions us-east-2 --name big  # 8xH200 spot (~$25/hr)
  gpulander grab  --min-vram 48 --either --max-price 3.00    # anything >=48GB, spot-or-ondemand
  gpulander grab  --instance g7e.2xlarge --dry-run           # see the plan, launch nothing

Per-command detail:  gpulander grab --help   ·   gpulander check --help   ·   gpulander accounts --help
Runtime/state lives under $GPULANDER_HOME (default ~/.gpulander).
H
echo; catalog_table
}

help_grab () {
cat <<'H'
gpulander grab — poll until a matching GPU launches, then exit.

WHAT IT DOES
  Loops run-instances across the chosen accounts/regions/AZs for the resolved instance type(s). The
  instant one launches it writes $GPULANDER_HOME/runs/<name>/launched.json and EXITS 0. Under an agent's
  run_in_background, that exit wakes the agent to SSH in, provision, and train. The box carries a
  user-data self-terminate (--cap-hours) so it can never run forever.

SELECTOR (choose one)
  --gpu NAME         --gpu rtxpro6000 (96GB)  |  --gpu h200 (8xH200 141GB)  | l40s|l4|a10g|h100|a100-80|...
  --min-vram GB      --min-vram 48            (cheapest single-GPU with >= 48GB)
  --instance T[,T2]  --instance g7e.2xlarge,g7e.4xlarge   (exact, priority order)

OPTIONS  (spot is default)
  --spot | --on-demand | --either · --max-price X · --regions r1,r2 ·
  --profile p1,p2,p3 (sweep several accounts) · --name TAG ·
  --deadline MINS (->exit 7) · --cap-hours H · --dry-run

EXAMPLES
  gpulander grab --gpu rtxpro6000 --name gemma --spot --deadline 240 --cap-hours 3
  gpulander grab --gpu h200 --regions us-east-2 --name ornith --spot          # ~$25/hr 8xH200
  gpulander grab --gpu rtxpro6000 --profile dev,prod,admin --name gemma       # across 3 accounts
  gpulander grab --min-vram 48 --either --max-price 3.00 --name midsize
  gpulander grab --instance g7e.2xlarge --dry-run

AGENT FLOW
  Bash(run_in_background): gpulander grab --gpu rtxpro6000 --name gemma --spot
    -> detached poll; on grab it exits 0 -> the agent is re-invoked, reads launched.json, provisions.

EXIT: 0 grabbed (launched.json) · 7 deadline/no-capacity · 2 error
H
}

help_check () {
cat <<'H'
gpulander check — READ-ONLY availability. Launches nothing, spends nothing.

For each account x instance type it prints:
  * spot placement score per region/AZ   (1 = low .. 10 = high chance of actually getting spot)
  * which AZs OFFER the type
  * the latest spot $/hr                  (cheapest AZs first)
Use it to pick spot-vs-on-demand, the best region, and which account BEFORE you 'grab'.

SELECTOR (one): --gpu NAME | --min-vram GB | --instance T[,T2]
OPTIONS:        --regions r1,r2 · --profile p1,p2 (check several accounts)

EXAMPLES
  gpulander check --gpu rtxpro6000
  gpulander check --gpu h200 --regions us-east-2,us-west-2
  gpulander check --instance g7e.2xlarge,p5e.48xlarge --profile dev,prod

Reads: get-spot-placement-scores, describe-instance-type-offerings, describe-spot-price-history.
H
}

help_accounts () {
cat <<'H'
gpulander accounts — list the AWS profiles you have configured and which account each maps to.

Runs 'aws configure list-profiles', then 'aws sts get-caller-identity' per profile (read-only). Shows
the 12-digit account id and whether the profile's creds currently work (ok / NEEDS AUTH).

Use the names it prints with --profile — one, or a comma list to poll several accounts at once:
  gpulander grab --gpu rtxpro6000 --profile syrenity-dev
  gpulander grab --gpu rtxpro6000 --profile syrenity-dev,syrenity-prod,syra-admin
Add a profile:  aws configure --profile NAME  (keys)  |  aws configure sso  (SSO)
If a row says NEEDS AUTH (SSO):  aws sso login --profile NAME
H
}

skill_card () { cat <<'CARD'
---
name: gpulander
description: Grab an AWS GPU (spot/on-demand) across one or several AWS accounts and US regions/AZs for a training run, waiting out capacity shortages. Use when the user says grab/rent/spin up/land a GPU, needs an H200/H100/RTX-PRO-6000/L40S/A10G box, wants cheap spot GPU for training, asks to check AWS GPU availability or price, or asks which AWS accounts/GPUs are available.
---
<!-- managed by gpulander: updated on upgrade; edit freely and it will be left alone -->
# gpulander (opportunistic AWS GPU grabber)

## The recipe
```bash
gpulander --list                              # 0. the GPU menu you can hunt (instance -> GPU/VRAM/#GPU/$)
gpulander accounts                            # 0. which AWS profiles/accounts you can poll
gpulander check --gpu rtxpro6000              # 1. available? price? (score/AZs/spot$ — no launch)
gpulander grab  --gpu rtxpro6000 --name job   # 2. poll+grab (spot); writes launched.json; exit 0 on win
```
Run step 2 under an agent's `run_in_background` — the EXIT on grab re-invokes the agent to SSH in,
provision, and train. Full manual: `gpulander --help`; per-command: `grab|check|accounts --help`.

## Pick a GPU  (full menu: `gpulander --list`)
- `--gpu rtxpro6000` 96GB (~$1.92 spot) · `--gpu l40s` 48GB · `--gpu a10g|l4` 24GB · `--gpu h200` = 8xH200 141GB (~$25 spot).
- or `--min-vram 48` (cheapest single-GPU ≥48GB) · or `--instance g7e.2xlarge`.
- Names: rtxpro6000 | l40s | l4 | a10g | h100 | h200 | a100-80 | a100-40 | t4 | v100.

## Pick the account(s)  (list them: `gpulander accounts`)
- Each AWS profile in ~/.aws = one account. Target one: `--profile NAME`. Sweep several at once:
  `--profile dev,prod,admin` (first account to land a box wins; launched.json records which).
- No `--profile` → uses `$AWS_PROFILE` / `$GPULANDER_PROFILE` / the AWS default chain.
- Set up: `aws configure --profile NAME` (keys) or `aws configure sso`; refresh SSO: `aws sso login --profile NAME`.

## Narrow or widen
- spot is the default; add `--on-demand` or `--either` to widen · `--regions us-east-2,us-west-2` ·
  `--max-price 3.00` · `--deadline 240` (exit 7 if none) · `--cap-hours 3` (box self-terminates).

## Good to know
- Scarce new GPUs (g7e, H200) can be `InsufficientInstanceCapacity` on BOTH spot and on-demand — `check` first.
- No single-GPU H200 on AWS; `--gpu h200` = 8xH200 p5e.48xlarge (big/pricey). 96GB single-GPU = g7e.
- Exit codes: 0 grabbed (launched.json) · 7 deadline/no-capacity · 2 error.
- State lives under $GPULANDER_HOME (default ~/.gpulander); no creds are stored by gpulander.

## When to use
Whenever a GPU box is needed for a quick/cheap training run and you'd rather wait out AWS capacity than
babysit the console — across however many accounts you have.
CARD
}

skill_cmd () {
  case "${1:-show}" in
    show|"") skill_card ;;
    list) printf '%s\t%s\n' "$SKILL_DIRNAME" "$SKILL_SUMMARY" ;;
    export) local t; t=$(mktemp -d); mkdir -p "$t/$SKILL_DIRNAME"
      skill_card > "$t/$SKILL_DIRNAME/SKILL.md"; cp "$0" "$t/$SKILL_DIRNAME/gpulander.sh" 2>/dev/null
      tar -cf - -C "$t" "$SKILL_DIRNAME"; rm -rf "$t" ;;
    install) local base dir f cur rec
      for base in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.agents/skills"; do
        dir="$base/$SKILL_DIRNAME"; f="$dir/SKILL.md"; mkdir -p "$dir"
        if [ -f "$f" ]; then cur=$(shasum "$f" | awk '{print $1}'); rec=$(cat "$dir/.managed-hash" 2>/dev/null)
          [ -n "$rec" ] && [ "$cur" != "$rec" ] && { echo "skip (edited by you): $f"; continue; }; fi
        skill_card > "$f"; shasum "$f" | awk '{print $1}' > "$dir/.managed-hash"; echo "installed: $f"
      done ;;
    *) echo "skill actions: (show) | list | export | install" >&2; return 2 ;;
  esac
}

list_accounts () {   # READ-ONLY: your configured profiles + the account each maps to
  local profs p out acct arn
  profs=$(aws configure list-profiles 2>/dev/null | sort -u)
  echo "Configured AWS profiles (from ~/.aws/config & ~/.aws/credentials):"
  if [ -z "$profs" ]; then
    echo "  (none found — add one:  aws configure --profile NAME   or   aws configure sso)"
    return 0
  fi
  printf "  %-26s %-14s %s\n" PROFILE ACCOUNT STATUS
  while read -r p; do
    [ -z "$p" ] && continue
    out=$(aws sts get-caller-identity --profile "$p" --query '[Account,Arn]' --output text 2>&1)
    if printf '%s' "$out" | grep -qE '^[0-9]{12}[[:space:]]'; then
      acct=$(printf '%s' "$out" | awk '{print $1}'); arn=$(printf '%s' "$out" | awk '{print $2}')
      printf "  %-26s %-14s ok   %s\n" "$p" "$acct" "$arn"
    else
      printf "  %-26s %-14s NEEDS AUTH (%s)\n" "$p" "-" "$(printf '%s' "$out" | grep -oE 'ExpiredToken|SSO session|Token has expired|Unable to locate|AccessDenied|not authorized|InvalidClientTokenId|could not be found' | head -1)"
    fi
  done <<< "$profs"
  echo
  echo "Poll one or several:  gpulander grab --gpu rtxpro6000 --profile p1,p2,p3"
  echo "Refresh SSO creds:    aws sso login --profile <name>"
}

gpu_to_instances () {   # $1 = gpu name -> space-separated instance types (priority order)
  local g; g=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$g" in
    rtxpro6000|blackwell|rtx|g7e)        echo "g7e.2xlarge g7e.4xlarge g7e.8xlarge" ;;
    l40s|g6e)                            echo "g6e.2xlarge g6e.4xlarge" ;;
    l4|g6)                               echo "g6.2xlarge" ;;
    a10g|g5)                             echo "g5.2xlarge" ;;
    h100)                                echo "p5.48xlarge" ;;
    h200)                                echo "p5e.48xlarge p5en.48xlarge" ;;
    a100-80|a100)                        echo "p4de.24xlarge" ;;
    a100-40)                             echo "p4d.24xlarge" ;;
    t4)                                  echo "g4dn.xlarge" ;;
    v100)                                echo "p3.2xlarge" ;;
    *) return 1 ;;
  esac
}

minvram_to_instances () {   # $1 = GB -> single-GPU types with per-GPU VRAM>=GB, cheapest first
  echo "$CATALOG" | awk -v want="$1" '$5==1 && $3+0>=want {print $6, $1}' | sort -n | awk '{print $2}' | tr '\n' ' '
}

od_hint () { echo "$CATALOG" | awk -v it="$1" '$1==it{print $6}' | head -1; }

pkey_of () { printf '%s' "${1:-default}" | tr -c 'A-Za-z0-9._-' '_'; }   # cache-file-safe profile key

# PROFILE_ARGS (global) is rebuilt per profile before each aws-calling helper runs.
set_profile_args () { PROFILE_ARGS=(); [ -n "${1:-}" ] && PROFILE_ARGS=(--profile "$1"); }

check_availability () {   # READ-ONLY: spot placement score + offerings + live spot price. No launch.
  for it in $INSTANCES; do
    local meta; meta=$(echo "$CATALOG" | awk -v i="$it" '$1==i{print $2" "$3"GB x"$5"gpu  ~$"$6"/hr OD"}')
    echo ""; echo "### $it   $meta"
    echo "  spot placement score (1=low .. 10=high chance of getting spot):"
    aws ec2 get-spot-placement-scores "${PROFILE_ARGS[@]}" --region us-east-1 \
      --instance-types "$it" --target-capacity 1 --single-availability-zone \
      --region-names $REGIONS \
      --query 'SpotPlacementScores[].[Region,AvailabilityZoneId,Score]' --output text 2>&1 \
      | awk 'NF{printf "    %-12s %-16s score=%s\n",$1,$2,$3}' | sort -t= -k2 -rn | head -12
    echo "  offered-in AZs + latest spot \$/hr:"
    for r in $REGIONS; do
      local azs sp
      azs=$(aws ec2 describe-instance-type-offerings "${PROFILE_ARGS[@]}" --region "$r" --location-type availability-zone --filters Name=instance-type,Values=$it --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null)
      sp=$(aws ec2 describe-spot-price-history "${PROFILE_ARGS[@]}" --region "$r" --instance-types "$it" --product-descriptions "Linux/UNIX" --start-time "$(date -u +%FT%TZ)" --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>/dev/null | sort -k2 -n | head -3 | awk '{printf "%s=$%s ",$1,$2}')
      printf "    %-12s offered:[%s]  spot:[%s]\n" "$r" "${azs:-none}" "${sp:-n/a}"
    done
  done
}

# ---------------- arg parse ----------------
MODE=""; INSTANCES=""; GPU=""; MINVRAM=""; MARKET=spot; MAXPRICE=""; REGIONS="us-east-1,us-east-2,us-west-2"
NAME="grab"; DEADLINE=240; CAP=4; PROFILE="${GPULANDER_PROFILE:-${AWS_PROFILE:-}}"; DRY=0
[ $# -eq 0 ] && { help_main; exit 2; }
case "$1" in
  --list) catalog_table; exit 0 ;;
  -h|--help) help_main; exit 0 ;;
  --skill) shift; skill_cmd "$@"; exit $? ;;
  accounts) shift; { [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; } && { help_accounts; exit 0; }; list_accounts; exit 0 ;;
  grab)  shift; { [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; } && { help_grab; exit 0; }; MODE=grab ;;
  check) shift; { [ "${1:-}" = -h ] || [ "${1:-}" = --help ]; } && { help_check; exit 0; }; MODE=check ;;
  *) help_main; exit 2 ;;
esac
while [ $# -gt 0 ]; do case "$1" in
  --instance) INSTANCES="${2//,/ }"; shift 2;;
  --gpu) GPU="$2"; shift 2;;
  --min-vram) MINVRAM="$2"; shift 2;;
  --spot) MARKET=spot; shift;; --on-demand) MARKET=ondemand; shift;; --either) MARKET=either; shift;;
  --max-price) MAXPRICE="$2"; shift 2;;
  --regions) REGIONS="${2//,/ }"; shift 2;;
  --profile) PROFILE="$2"; shift 2;;
  --name) NAME="$2"; shift 2;;
  --deadline) DEADLINE="$2"; shift 2;;
  --cap-hours) CAP="$2"; shift 2;;
  --dry-run) DRY=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
REGIONS="${REGIONS//,/ }"   # normalize to space-separated for all loops

# PROFILES: array of account profiles to poll. Empty-string element == the AWS default chain.
if [ -n "$PROFILE" ]; then
  OLDIFS=$IFS; IFS=','; set -f; PROFILES=($PROFILE); set +f; IFS=$OLDIFS
else
  PROFILES=("")
fi

# resolve the target instance list
if [ -n "$INSTANCES" ]; then :;
elif [ -n "$GPU" ]; then INSTANCES=$(gpu_to_instances "$GPU") || { echo "unknown --gpu $GPU (see --list)"; exit 2; };
elif [ -n "$MINVRAM" ]; then INSTANCES=$(minvram_to_instances "$MINVRAM");
else echo "need one of --instance / --gpu / --min-vram"; exit 2; fi
[ -z "${INSTANCES// }" ] && { echo "no instance type matched the selector"; exit 2; }

if [ "$MODE" = check ]; then
  echo "AVAILABILITY CHECK (read-only — nothing launched)  regions=[$REGIONS]  accounts=${#PROFILES[@]}"
  for prof in "${PROFILES[@]}"; do
    set_profile_args "$prof"
    echo ""; echo "========== account/profile: ${prof:-<default chain>} =========="
    check_availability
  done
  exit 0
fi

[ -z "$MAXPRICE" ] && { first=$(echo $INSTANCES | awk '{print $1}'); oh=$(od_hint "$first"); MAXPRICE=$(awk -v o="${oh//[^0-9.]/}" 'BEGIN{printf "%.2f", (o>0?o*1.25:3.0)}'); }

RT="$GPULANDER_HOME/runs/$NAME"; mkdir -p "$RT"
PLABEL=""; for p in "${PROFILES[@]}"; do PLABEL="$PLABEL ${p:-<default>}"; done
echo "gpulander: name=$NAME market=$MARKET max=\$$MAXPRICE regions=[$REGIONS] targets=[$INSTANCES] deadline=${DEADLINE}m cap=${CAP}h"
echo "           accounts=[${PLABEL# }]  runtime dir: $RT"
if [ "$DRY" = 1 ]; then
  echo "DRY-RUN plan (nothing launched, no AWS calls):"
  for prof in "${PROFILES[@]}"; do for r in $REGIONS; do for it in $INSTANCES; do
    case "$MARKET" in
      spot)     echo "  [${prof:-default}] would try $it [spot]                in $r (all default AZs)";;
      ondemand) echo "  [${prof:-default}] would try $it [on-demand]           in $r (all default AZs)";;
      either)   echo "  [${prof:-default}] would try $it [spot then on-demand]  in $r (all default AZs)";;
    esac
  done; done; done
  exit 0
fi
[ -f "$RT/ssh-key" ] || ssh-keygen -t ed25519 -N '' -f "$RT/ssh-key" >/dev/null 2>&1
MYIP=$(curl -s https://checkip.amazonaws.com)
USERDATA=$(printf '#!/bin/bash\nshutdown -P +%d\n' $((CAP*60)) | base64)

# AMI + security-group ids are cached per (profile,region) in $RT/.ami-<pk>-<r> / .sg-<pk>-<r>
# (plain files, not associative arrays — macOS /bin/bash is 3.2 and has no `declare -A`).
# Uses globals: CURPROF (profile name), PK (cache key), PROFILE_ARGS (set by set_profile_args).
setup_region () { local r=$1 amf="$RT/.ami-$PK-$r" sgf="$RT/.sg-$PK-$r" ami sg
  [ -s "$amf" ] && [ -s "$sgf" ] && return 0
  ami=$(aws ssm get-parameter "${PROFILE_ARGS[@]}" --region "$r" --name /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id --query Parameter.Value --output text 2>/dev/null)
  aws ec2 import-key-pair "${PROFILE_ARGS[@]}" --region "$r" --key-name "gpulander-$NAME" --public-key-material "fileb://$RT/ssh-key.pub" >/dev/null 2>&1
  sg=$(aws ec2 create-security-group "${PROFILE_ARGS[@]}" --region "$r" --group-name "gpulander-$NAME" --description "gpulander owner ssh" --query GroupId --output text 2>/dev/null) \
    || sg=$(aws ec2 describe-security-groups "${PROFILE_ARGS[@]}" --region "$r" --group-names "gpulander-$NAME" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  aws ec2 authorize-security-group-ingress "${PROFILE_ARGS[@]}" --region "$r" --group-id "$sg" --protocol tcp --port 22 --cidr "${MYIP}/32" >/dev/null 2>&1
  [ -n "$ami" ] && [ "$ami" != None ] && [ -n "$sg" ] || return 1
  printf '%s' "$ami" > "$amf"; printf '%s' "$sg" > "$sgf"
}

azs_for () { aws ec2 describe-subnets "${PROFILE_ARGS[@]}" --region "$1" --filters Name=default-for-az,Values=true --query 'Subnets[].[AvailabilityZone,SubnetId]' --output text 2>/dev/null; }

try_launch () { local r=$1 az=$2 sn=$3 it=$4 mode=$5 market="" out ami sg
  ami=$(cat "$RT/.ami-$PK-$r" 2>/dev/null); sg=$(cat "$RT/.sg-$PK-$r" 2>/dev/null)
  [ "$mode" = spot ] && market="--instance-market-options={\"MarketType\":\"spot\",\"SpotOptions\":{\"SpotInstanceType\":\"one-time\",\"MaxPrice\":\"$MAXPRICE\",\"InstanceInterruptionBehavior\":\"terminate\"}}"
  out=$(aws ec2 run-instances "${PROFILE_ARGS[@]}" --region "$r" --image-id "$ami" --instance-type "$it" --count 1 \
    --key-name "gpulander-$NAME" --subnet-id "$sn" --security-group-ids "$sg" --associate-public-ip-address $market \
    --user-data "$USERDATA" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":250,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]' \
    --metadata-options HttpTokens=required,HttpEndpoint=enabled --instance-initiated-shutdown-behavior terminate \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=gpulander-$NAME},{Key=Project,Value=gpulander}]" \
    --query 'Instances[0].InstanceId' --output text 2>&1)
  if [[ "$out" == i-* ]]; then
    printf '{"id":"%s","region":"%s","az":"%s","instance":"%s","market":"%s","profile":"%s","key":"%s/ssh-key","at":"%s"}\n' \
      "$out" "$r" "$az" "$it" "$mode" "${CURPROF:-default}" "$RT" "$(date -u +%FT%TZ)" > "$RT/launched.json"
    echo "GRABBED: $it ($mode) $az in account [${CURPROF:-default}] -> $out"; return 0
  fi
  echo "  miss [${CURPROF:-default}] $it/$mode/$az: $(echo "$out" | grep -oE 'InsufficientInstanceCapacity|not offered in|[A-Za-z]*Exceeded|Unsupported' | head -1)"; return 1
}

END=$(( $(date +%s) + DEADLINE*60 )); round=0
while :; do
  round=$((round+1))
  for prof in "${PROFILES[@]}"; do
    CURPROF="$prof"; PK=$(pkey_of "$prof"); set_profile_args "$prof"
    for r in $REGIONS; do
      setup_region "$r" || { echo "  [${prof:-default}] region $r setup failed (skip)"; continue; }
      while read -r az sn; do
        [ -z "$az" ] && continue
        for it in $INSTANCES; do
          [ "$MARKET" = ondemand ] || { try_launch "$r" "$az" "$sn" "$it" spot && exit 0; }
          [ "$MARKET" = spot ] || { try_launch "$r" "$az" "$sn" "$it" ondemand && exit 0; }
        done
      done < <(azs_for "$r")
    done
  done
  if [ "$(date +%s)" -ge "$END" ]; then echo "deadline hit; no capacity" > "$RT/status"; echo "DEADLINE: no capacity in ${DEADLINE}m"; exit 7; fi
  echo "round $round: no capacity yet; sleeping 60s  ($(date +%H:%M:%S))"; sleep 60
done
