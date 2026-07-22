"""
Sehat MG — refresh data.json from Snowflake (via Metabase /api/dataset).

    python refresh.py

Writes data.json = { "meta": {...}, "data": { "<cspId>": {ok, all, sok, stot, cn, tr, op0} } }
Those are the RAW inputs. Every displayed number (Optical Power %, SLA %, gap to 80,
RAG band, bar width) is derived from them client-side in index.html, so the CSP sees
exactly the numerator/denominator behind their grade.

  ok / all   Optical Power  = ok / all * 100     (TELEMETRY_ROLLUP_RECORDS, rolling 15 telemetry days)
  sok / stot Service SLA    = sok / stot * 100   (COMPLAINT_RESOLUTION_LEDGER, CSP's own 60-day lookback)
  cn         active connections            op0  Optical Power at month start (track is locked off this)
  tr         'A' (op0 < 75) | 'B' (op0 >= 75) | 'U' (no optical telemetry)

NOTE ON THE FORMULA — this is the one thing to not get wrong:
  % Optical Power = OPTICAL_NUMERATOR / OPTICAL_DENOMINATOR  (share of IN-RANGE pings).
  The column T1_OOR_RATE is an OK-rate despite its name. Proof: the service's own
  T1_BAND assigns VG at 95-100 and GOOD at 90-95, banding identically to
  T2_SPEED_OK_RATE, whose direction is unambiguous. Reading it as "out of range"
  (i.e. 100 - rate) inverts every CSP and puts 986/1053 into Track A.
"""
import json, os, sys, urllib.request
from datetime import datetime, timezone, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
ENV  = r"C:\credentials\.env"
SQL  = os.path.join(HERE, "query.sql")
WEAK = os.path.join(HERE, "weak_query.sql")     # Track-A worst-first weak connections
TKTS = os.path.join(HERE, "ticket_query.sql")   # Track-B still-open service tickets
OUT  = os.path.join(HERE, "data.json")

key = os.environ.get("METABASE_API_KEY")
if not key and os.path.exists(ENV):
    for line in open(ENV, encoding="utf-8"):
        if line.startswith("METABASE_API_KEY"):
            key = line.split("=", 1)[1].strip().strip('"').strip("'")
if not key:
    sys.exit("METABASE_API_KEY not found (env var or C:\\credentials\\.env)")

def run(sql_path):
    req = urllib.request.Request(
        "https://metabase.wiom.in/api/dataset",
        data=json.dumps({"database": 113, "type": "native",
                         "native": {"query": open(sql_path, encoding="utf-8").read()}}).encode(),
        headers={"X-API-KEY": key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=600) as r:
        res = json.loads(r.read().decode())
    if res.get("status") == "failed":
        sys.exit("query failed (" + os.path.basename(sql_path) + "): " + str(res.get("error"))[:400])
    cols = [c["name"] for c in res["data"]["cols"]]
    return [dict(zip(cols, row)) for row in res["data"]["rows"]]

rows = run(SQL)

data, tracks = {}, {"A": 0, "B": 0, "U": 0}
for r in rows:
    cid = r["CSP_ID"]
    if not cid:
        continue
    tracks[r["TRACK"]] = tracks.get(r["TRACK"], 0) + 1
    rec = {"tr": r["TRACK"], "cn": r["CONNS"] or 0}
    if r["ALL_PINGS"]:
        rec["ok"], rec["all"] = int(r["OK_PINGS"]), int(r["ALL_PINGS"])
    if r["SLA_TOT"]:
        rec["sok"], rec["stot"] = int(r["SLA_OK"]), int(r["SLA_TOT"])
    if r["OP_MONTH_START"] is not None:
        rec["op0"] = round(float(r["OP_MONTH_START"]), 1)
    data[cid.lower()] = rec

# Track-A weak-connection lists (whom to treat) — merge worst-first ONTs into each record.
weak_rows, weak_csps = run(WEAK), 0
for r in weak_rows:
    cid = (r["CSP_ID"] or "").lower()
    if cid not in data:
        continue
    worst = r["WORST"]
    if isinstance(worst, str):
        worst = json.loads(worst)
    data[cid]["wn"] = int(r["WEAK_N"] or 0)                       # total weak connections
    data[cid]["wk"] = [{"d": w["d"], "v": int(w["v"]), "a": (w.get("a") or "")}
                       for w in worst]                            # worst 3: device + dBm + coarse area
    weak_csps += 1

# Track-B still-open service tickets (whom to resolve) — merge into each record.
tkt_rows, tkt_csps = run(TKTS), 0
for r in tkt_rows:
    cid = (r["CSP_ID"] or "").lower()
    if cid not in data:
        continue
    tk = r["TICKETS"]
    if isinstance(tk, str):
        tk = json.loads(tk)
    data[cid]["tn"] = int(r["OPEN_N"] or 0)                       # total open tickets
    data[cid]["tk"] = [{"a": (t.get("a") or ""), "g": int(t.get("g") or 0)}
                       for t in tk]                               # most-overdue 3: area + age(days)
    tkt_csps += 1

ist = datetime.now(timezone.utc) + timedelta(minutes=330)
out = {
    "meta": {
        "generated_at": ist.strftime("%Y-%m-%d %H:%M IST"),
        "csps": len(data),
        "tracks": tracks,
        "source": "PROD_DB.CSP_QUALITY_SERVICE_CSP_QUALITY_SERVICE",
        "optical_window_days": 15,
        "sla_tat_hours": 4,
        "target_pct": 80,
        "track_split_pct": 75,
        "weak_dbm_floor": -25,
        "weak_source": "PROD_DB.PUBLIC.HOURLY_DEVICE_PING_INFLUX",
        "weak_liveness_days": 3,
    },
    "data": data,
}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(out, f, separators=(",", ":"), ensure_ascii=False)

print(f"data.json  {len(data)} CSPs  {os.path.getsize(OUT)/1024:.0f} KB")
print(f"tracks     A(ilaaj) {tracks['A']}  B(fit-rakhna) {tracks['B']}  unclassified {tracks['U']}")
print(f"weak lists {weak_csps} Track-A CSPs got a worst-first connection list")
print(f"open tkts  {tkt_csps} Track-B CSPs got an open-ticket list")

# Keep the sibling Service-SLA deployment in sync (same track-aware app + data).
import shutil
SIB = os.path.join(os.path.dirname(HERE), "wiom-sehat-service-sla")
if os.path.isdir(SIB) and os.path.abspath(SIB) != os.path.abspath(HERE):   # not self
    for f in ("index.html", "404.html", "data.json"):
        shutil.copyfile(os.path.join(HERE, f), os.path.join(SIB, f))
    print(f"synced     index.html + data.json -> {SIB}  (commit & push that repo too)")
