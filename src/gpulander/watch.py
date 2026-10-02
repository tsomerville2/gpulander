"""gpulander watch: READ-ONLY availability observatory. Never launches, reserves or buys anything.

Records, on an interval, into SQLite (default ~/.gpulander/watch/availability.sqlite):
  spot_score   spot placement score 1..10 per region/AZ-id          (get-spot-placement-scores)
  spot_price   current spot $/hr per AZ                              (describe-spot-price-history)
  cb_offer     Capacity Block offering for 1 instance x 24h: upfront fee + start date
  cb_none      no Capacity Block offering returned
  offered      instance type is sold in that AZ at all (static)
  error        API error text (quota, unsupported, ...)
On-demand capacity has NO read-only API (run-instances --dry-run says "would have succeeded" even for
sold-out types), so on-demand is deliberately not probed: Capacity Blocks are the buyable-now signal.
"""
import argparse, json, os, sqlite3, statistics, subprocess, sys, time
from datetime import datetime, timezone

SKUS = {
    "g7e.2xlarge": "RTX PRO 6000 96GB x1", "g7e.12xlarge": "RTX PRO 6000 x4 (384GB)", "g7e.48xlarge": "RTX PRO 6000 x8 (768GB)",
    "g6e.2xlarge": "L40S 48GB x1", "g6.xlarge": "L4 24GB x1", "g5.xlarge": "A10G 24GB x1",
    "p5.4xlarge": "H100 80GB x1", "p5.48xlarge": "H100 x8", "p5e.48xlarge": "H200 x8", "p5en.48xlarge": "H200 x8 (EFAv3)",
    "p4d.24xlarge": "A100 40GB x8", "p4de.24xlarge": "A100 80GB x8",
    "p6-b200.48xlarge": "B200 x8", "p6-b300.48xlarge": "B300 x8", "p6e-gb200.36xlarge": "GB200 x4 (UltraServer)",
    "trn2.48xlarge": "Trainium2 x16", "trn1.32xlarge": "Trainium1 x16", "inf2.48xlarge": "Inferentia2 x12",
}
CB_TYPES = ["p5.48xlarge", "p5e.48xlarge", "p5en.48xlarge", "p4d.24xlarge", "p4de.24xlarge",
            "p6-b200.48xlarge", "p6-b300.48xlarge", "p6e-gb200.36xlarge", "trn1.32xlarge", "trn2.48xlarge"]
DEF_REGIONS = "us-east-1,us-east-2,us-west-1,us-west-2,eu-west-1,eu-central-1,ap-northeast-1,ap-southeast-2"
CB_REGIONS = "us-east-1,us-east-2,us-west-2,eu-west-1"
DEF_DB = os.path.expanduser("~/.gpulander/watch/availability.sqlite")
SCHEMA = """create table if not exists obs(ts text, cycle integer, acct text, kind text, itype text, region text, az text,
  value real, text text, extra text);
create index if not exists obs_i on obs(itype, kind, ts);"""


def aws(args, profile, region):
    cmd = ["aws", "ec2", *args, "--output", "json", "--region", region]
    if profile:
        cmd += ["--profile", profile]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        return None, (r.stderr.strip().splitlines() or ["error"])[-1][:300]
    return (json.loads(r.stdout) if r.stdout.strip() else {}), None


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Rec:
    def __init__(self, db, cycle):
        self.c = sqlite3.connect(db)
        self.c.executescript(SCHEMA)
        self.cycle = cycle

    def add(self, acct, kind, itype, region="", az="", value=None, text="", extra=""):
        self.c.execute("insert into obs values(?,?,?,?,?,?,?,?,?,?)",
                       (now(), self.cycle, acct, kind, itype, region, az, value, text, extra))


def observe_offered(rec, profile, regions, types):
    for r in regions:
        d, e = aws(["describe-instance-type-offerings", "--location-type", "availability-zone", "--filters",
                    "Name=instance-type,Values=" + ",".join(types)], profile, r)
        if e:
            rec.add(profile, "error", "*", r, text="offered: " + e); continue
        seen = {}
        for o in d.get("InstanceTypeOfferings", []):
            seen.setdefault(o["InstanceType"], []).append(o["Location"])
        for t in types:
            for az in seen.get(t, []):
                rec.add(profile, "offered", t, r, az, 1)
            if t not in seen:
                rec.add(profile, "offered", t, r, "", 0)
    rec.c.commit()


def observe_scores(rec, profile, regions, types):
    for t in types:
        d, e = aws(["get-spot-placement-scores", "--instance-types", t, "--target-capacity", "1",
                    "--single-availability-zone", "--region-names", *regions], profile, regions[0])
        if e:
            rec.add(profile, "unsupported" if "not valid" in e else "error", t, text="spot_score: " + e); continue
        got = d.get("SpotPlacementScores", [])
        for s in got:
            rec.add(profile, "spot_score", t, s["Region"], s.get("AvailabilityZoneId", ""), s["Score"])
        for r in regions:  # a region absent from the reply = AWS returned no placement for it
            if not any(s["Region"] == r for s in got):
                rec.add(profile, "spot_score", t, r, "", 0, "absent")
    rec.c.commit()


def observe_prices(rec, profile, regions, types):
    start = now()
    for r in regions:
        d, e = aws(["describe-spot-price-history", "--instance-types", *types, "--product-descriptions", "Linux/UNIX",
                    "--start-time", start], profile, r)
        if e:
            rec.add(profile, "error", "*", r, text="spot_price: " + e); continue
        latest = {}
        for p in d.get("SpotPriceHistory", []):
            k = (p["InstanceType"], p["AvailabilityZone"])
            if k not in latest or p["Timestamp"] > latest[k]["Timestamp"]:
                latest[k] = p
        for (t, az), p in latest.items():
            rec.add(profile, "spot_price", t, r, az, float(p["SpotPrice"]))
    rec.c.commit()


def observe_blocks(rec, profile, regions, types):
    for t in types:
        for r in regions:
            d, e = aws(["describe-capacity-block-offerings", "--instance-type", t, "--instance-count", "1",
                        "--capacity-duration-hours", "24"], profile, r)
            if e:
                if "Unsupported" in e or "not supported" in e or "InvalidParameter" in e or "InvalidAction" in e:
                    continue
                rec.add(profile, "error", t, r, text="cb: " + e); continue
            offs = d.get("CapacityBlockOfferings", [])
            if not offs:
                rec.add(profile, "cb_none", t, r); continue
            for o in offs:
                hrs = (datetime.fromisoformat(o["StartDate"]) - datetime.now(timezone.utc)).total_seconds() / 3600
                rec.add(profile, "cb_offer", t, r, o["AvailabilityZone"], float(o["UpfrontFee"]), o["StartDate"],
                        json.dumps({"hours_until_start": round(hrs, 1), "usd_per_hr": round(float(o["UpfrontFee"]) / 24, 2)}))
    rec.c.commit()


def heartbeat(db, cycle):
    c = sqlite3.connect(db)
    out = [f"cycle {cycle} {now()}"]
    for t in ("g7e.2xlarge", "p5en.48xlarge", "p6-b200.48xlarge"):
        r = c.execute("select max(value) from obs where cycle=? and kind='spot_score' and itype=?", (cycle, t)).fetchone()[0]
        out.append(f"{t.split('.')[0]}:score={r}")
    err = c.execute("select count(*) from obs where cycle=? and kind='error'", (cycle,)).fetchone()[0]
    out.append(f"errors={err}")
    print("  ".join(out), flush=True)


def run(a):
    os.makedirs(os.path.dirname(a.db), exist_ok=True)
    profiles = [p for p in a.profile.split(",") if p]
    regions = a.regions.split(","); types = a.types.split(",") if a.types else list(SKUS)
    cbtypes = [t for t in CB_TYPES if t in types]
    end = time.time() + a.hours * 3600
    cycle = 0
    print(f"watch: READ-ONLY. {len(types)} types, {len(regions)} regions, accounts={profiles}, every {a.interval}s for {a.hours}h -> {a.db}", flush=True)
    while True:
        t_cycle = time.time()
        rec = Rec(a.db, cycle)
        key = types[:1] + [t for t in ("g7e.2xlarge", "p5e.48xlarge", "p5en.48xlarge", "p6-b200.48xlarge") if t in types]
        if cycle == 0:
            observe_offered(rec, profiles[0], regions, types)
        for i, pf in enumerate(profiles):
            observe_scores(rec, pf, regions, types if i == 0 else sorted(set(key)))
        observe_prices(rec, profiles[0], regions, types)
        if cycle % a.cb_every == 0:
            observe_blocks(rec, profiles[0], CB_REGIONS.split(","), cbtypes)
        heartbeat(a.db, cycle)
        cycle += 1
        if a.once or time.time() + a.interval > end:
            break
        time.sleep(max(0, a.interval - (time.time() - t_cycle)))
    print("watch: done", flush=True)
    return 0


def report(a):
    c = sqlite3.connect(a.db)
    cycles = c.execute("select count(distinct cycle) from obs").fetchone()[0]
    t0, t1 = c.execute("select min(ts), max(ts) from obs").fetchone()
    print(f"# AWS GPU availability, {t0} -> {t1} ({cycles} cycles, read-only)\n")
    print("type | what | % cycles score>=3 | % cycles score>=6 | best score | spot $/hr min..median | capacity block 24h ($/hr, soonest start)")
    for t, label in SKUS.items():
        sc = c.execute("select cycle, max(value) from obs where kind='spot_score' and itype=? and acct=(select acct from obs where kind='spot_score' limit 1) group by cycle", (t,)).fetchall()
        if not sc and not c.execute("select 1 from obs where itype=? limit 1", (t,)).fetchone():
            continue
        n = len(sc) or 1
        p3 = 100 * sum(1 for _, v in sc if v is not None and v >= 3) / n
        p6 = 100 * sum(1 for _, v in sc if v is not None and v >= 6) / n
        best = max((v for _, v in sc if v is not None), default=None)
        pr = [r[0] for r in c.execute("select value from obs where kind='spot_price' and itype=?", (t,))]
        price = f"{min(pr):.2f}..{statistics.median(pr):.2f}" if pr else "no quote"
        cb = c.execute("select min(value), min(json_extract(extra,'$.hours_until_start')), count(*) from obs where kind='cb_offer' and itype=?", (t,)).fetchone()
        cbs = f"{cb[0]/24:.2f}/hr, in {cb[1]}h" if cb[2] else ("none offered" if t in CB_TYPES else "n/a")
        print(f"{t} | {label} | {p3:.0f}% | {p6:.0f}% | {best} | {price} | {cbs}")
    errs = c.execute("select text, count(*) from obs where kind='error' group by text order by 2 desc limit 5").fetchall()
    if errs:
        print("\ntop errors:"); [print(f"  {n}x {t}") for t, n in errs]
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="gpulander watch", description=__doc__.split("\n")[0])
    s = p.add_subparsers(dest="cmd")
    r = s.add_parser("run", help="observe on an interval (read-only)")
    r.add_argument("--hours", type=float, default=24)
    r.add_argument("--interval", type=int, default=600, help="seconds between cycles")
    r.add_argument("--cb-every", type=int, default=6, help="capacity-block poll every N cycles")
    r.add_argument("--profile", default=os.environ.get("GPULANDER_PROFILE") or os.environ.get("AWS_PROFILE", ""),
                   help="comma list; first = full set, others = key SKUs only")
    r.add_argument("--regions", default=DEF_REGIONS)
    r.add_argument("--types", default="")
    r.add_argument("--once", action="store_true")
    r.add_argument("--db", default=DEF_DB)
    q = s.add_parser("report", help="summarize the DB (markdown)")
    q.add_argument("--db", default=DEF_DB)
    a = p.parse_args(argv)
    if a.cmd == "run":
        return run(a)
    if a.cmd == "report":
        return report(a)
    p.print_help()
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
