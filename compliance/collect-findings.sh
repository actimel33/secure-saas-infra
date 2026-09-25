#!/usr/bin/env bash
# Снимает замер Security Hub: активные проваленные контроли, сгруппированные
# по уровню. Первый аргумент — метка замера (before / after).
#
#   ./collect-findings.sh before
#
# Учётные данные берутся из окружения, регион — из AWS_DEFAULT_REGION.
set -euo pipefail

LABEL="${1:-snapshot}"
OUT_DIR="$(dirname "$0")/snapshots"
mkdir -p "$OUT_DIR"
RAW="$OUT_DIR/$LABEL.json"

echo "Собираю находки..."
aws securityhub get-findings \
  --filters '{
    "RecordState":      [{"Value":"ACTIVE",  "Comparison":"EQUALS"}],
    "ComplianceStatus": [{"Value":"FAILED",  "Comparison":"EQUALS"}],
    "WorkflowStatus":   [{"Value":"NEW",     "Comparison":"EQUALS"},
                         {"Value":"NOTIFIED","Comparison":"EQUALS"}]
  }' \
  --max-items 400 \
  --output json > "$RAW"

python3 - "$RAW" "$LABEL" <<'PY'
import json, sys, collections

raw, label = sys.argv[1], sys.argv[2]
findings = json.load(open(raw)).get("Findings", [])

# одна находка на контроль и ресурс; для сводки считаем уникальные контроли
by_control = {}
for f in findings:
    cid = f.get("Compliance", {}).get("SecurityControlId") or f.get("GeneratorId", "")[:60]
    sev = f.get("Severity", {}).get("Label", "UNKNOWN")
    res = [r.get("Id", "") for r in f.get("Resources", [])]
    entry = by_control.setdefault(cid, {"sev": sev, "title": f.get("Title", ""), "resources": set()})
    entry["resources"].update(res)

order = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "INFORMATIONAL", "UNKNOWN"]
counts = collections.Counter(v["sev"] for v in by_control.values())

print(f"\nЗамер: {label}")
print(f"Проваленных контролей: {len(by_control)}   находок всего: {len(findings)}")
print("По уровням: " + ", ".join(f"{s}={counts[s]}" for s in order if counts[s]))
print()

for sev in order:
    rows = [(c, v) for c, v in by_control.items() if v["sev"] == sev]
    if not rows:
        continue
    print(f"--- {sev} ({len(rows)}) ---")
    for cid, v in sorted(rows):
        n = len(v["resources"])
        short = next(iter(sorted(v["resources"])), "")
        short = short.split("/")[-1][:40]
        print(f"  {cid:28} {v['title'][:70]}")
        print(f"  {'':28} ресурсов: {n}  например: {short}")
    print()
PY

echo "Сырой ответ: $RAW"
