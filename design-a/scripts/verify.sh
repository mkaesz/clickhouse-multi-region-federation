#!/usr/bin/env bash
# Smoke + correctness tests for the multi-region federation demo:
#   schema presence, per-DC write isolation, dictionary-driven routing,
#   cross-DC fan-out from every DC, federation health, shard-pruning
#   correctness, and the RBAC write-path matrix.
# Exits non-zero if any assertion fails.
# Run from the repo root: bash scripts/verify.sh

set -euo pipefail

FRA_CTX="kind-clickhouse-multi-region-federation-demo-fra"
MUC_CTX="kind-clickhouse-multi-region-federation-demo-muc"
HAM_CTX="kind-clickhouse-multi-region-federation-demo-ham"

log()  { echo ""; echo "▶  $*"; }
info() { echo "   $*"; }

PASS=0
FAIL=0
pass() { info "PASS: $*"; PASS=$((PASS + 1)); }
fail() { info "FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() { # desc expected actual
    if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_match() { # desc pattern output
    if echo "$3" | grep -qE "$2"; then pass "$1"; else fail "$1 (no /$2/ in: $3)"; fi
}
assert_ok() { # desc output   -- passes when output carries no CH error
    if echo "$2" | grep -qiE "Code: [0-9]+|DB::Exception"; then
        fail "$1 (unexpected error: $2)"
    else
        pass "$1"
    fi
}

ch_pod() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ch_pods CTX NS -> every Running clickhouse-server pod in the DC, one per line,
# sorted (…-0-0-0, …-0-1-0, …). Used by the multi-replica tests.
ch_pods() {
    kubectl get pods --context "$1" -n "$2" \
        -l "clickhouse.com/role=clickhouse-server" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort
}

# chq CTX NS POD QUERY [extra clickhouse-client args...]
# Always returns 0; CH errors are captured as text on stdout (for assert_match).
chq() {
    local ctx="$1" ns="$2" pod="$3" query="$4"; shift 4
    kubectl exec --context "$ctx" -n "$ns" "$pod" -- \
        clickhouse client "$@" --query "$query" 2>&1 || true
}

run_query() { # visible informational query
    local ctx="$1" ns="$2" pod="$3" query="$4"
    info "[$ns] $query"
    kubectl exec --context "$ctx" -n "$ns" "$pod" -- clickhouse client --query "$query" 2>&1 || true
}

ctx_for() { case "$1" in fra) echo "$FRA_CTX";; muc) echo "$MUC_CTX";; ham) echo "$HAM_CTX";; esac; }

POD_FRA=$(ch_pod "$FRA_CTX" fra)
POD_MUC=$(ch_pod "$MUC_CTX" muc)
POD_HAM=$(ch_pod "$HAM_CTX" ham)
pod_for() { case "$1" in fra) echo "$POD_FRA";; muc) echo "$POD_MUC";; ham) echo "$POD_HAM";; esac; }

DCS="fra muc ham"

# ── 1. Schema presence: apply-schemas fully succeeded on every DC ──────────────
log "Schema presence on each DC (3 tables + regionToShard dictionary)"
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    t=$(chq "$ctx" "$dc" "$pod" \
        "SELECT count() FROM system.tables WHERE database='default' AND name IN ('otel_local','otel_regional','otel_global')")
    d=$(chq "$ctx" "$dc" "$pod" \
        "SELECT count() FROM system.dictionaries WHERE database='default' AND name='regionToShard'")
    assert_eq "$dc: 3 core tables present" 3 "$t"
    assert_eq "$dc: regionToShard dictionary present" 1 "$d"
done

# ── 2. Reset + seed one row per DC (writes go to the local MergeTree only) ─────
log "Reset local tables for repeatable results"
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    chq "$ctx" "$dc" "$pod" "TRUNCATE TABLE default.otel_local" >/dev/null
done

log "Insert sample rows into each DC"
run_query "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (1, now(), 'test from FRA')"
run_query "$MUC_CTX" muc "$POD_MUC" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (2, now(), 'test from MUC')"
run_query "$HAM_CTX" ham "$POD_HAM" \
    "INSERT INTO default.otel_local (id, event_time, payload) VALUES (3, now(), 'test from HAM')"

# Seeds were inserted on one replica per DC. With >1 replica the cross-DC reads
# below fan out through each region's NodePort, which can land on the OTHER
# replica -- so force every replica to catch up before asserting counts, or a
# read could race replication and see a short row. Harmless on single-replica.
log "Sync all replicas so cross-DC reads don't race replication"
for dc in $DCS; do
    ctx=$(ctx_for "$dc")
    for p in $(ch_pods "$ctx" "$dc"); do
        chq "$ctx" "$dc" "$p" "SYSTEM SYNC REPLICA default.otel_local" >/dev/null
    done
done

# ── 3. Write isolation: each DC's local table holds only its own region ───────
log "Write isolation: each DC's otel_local holds exactly its own region"
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc"); reg=$(echo "$dc" | tr '[:lower:]' '[:upper:]')
    cnt=$(chq "$ctx" "$dc" "$pod" "SELECT count() FROM default.otel_local")
    only=$(chq "$ctx" "$dc" "$pod" "SELECT count() FROM default.otel_local WHERE region != '$reg'")
    assert_eq "$dc: otel_local has 1 row"          1 "$cnt"
    assert_eq "$dc: otel_local has no foreign rows" 0 "$only"
done

# ── 4. Dictionary-driven routing map is correct (linchpin of sharding) ────────
log "regionToShard dictionary maps FRA->0, MUC->1, HAM->2"
chq "$FRA_CTX" fra "$POD_FRA" "SYSTEM RELOAD DICTIONARY default.regionToShard" >/dev/null
map_ok=$(chq "$FRA_CTX" fra "$POD_FRA" "SELECT toUInt8(
    dictGet('default.regionToShard','shardID',tuple('FRA'))=0 AND
    dictGet('default.regionToShard','shardID',tuple('MUC'))=1 AND
    dictGet('default.regionToShard','shardID',tuple('HAM'))=2)")
dict_rows=$(chq "$FRA_CTX" fra "$POD_FRA" "SELECT count() FROM default.regionToShard")
assert_eq "dictionary has 3 entries"           3 "$dict_rows"
assert_eq "dictionary maps every region right" 1 "$map_ok"

# ── 5. Cross-DC fan-out works from EVERY DC (not just FRA) ─────────────────────
# is_local (localhost:9001) and TLS certs are per-node; only querying from FRA
# would hide a broken MUC/HAM. otel_global must return all 3 regions everywhere.
log "Cross-DC fan-out: otel_global sees all 3 regions from every DC"
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    tot=$(chq "$ctx" "$dc" "$pod" "SELECT count() FROM default.otel_global")
    reg=$(chq "$ctx" "$dc" "$pod" "SELECT uniqExact(region) FROM default.otel_global")
    assert_eq "$dc: otel_global returns 3 rows"    3 "$tot"
    assert_eq "$dc: otel_global returns 3 regions" 3 "$reg"
done

# ── 6. Federation health: remote shards reachable, exactly one local shard ────
log "Federation health via system.clusters (cluster='global')"
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    err=$(chq "$ctx" "$dc" "$pod" \
        "SELECT sum(errors_count) FROM system.clusters WHERE cluster='global' AND is_local=0")
    loc=$(chq "$ctx" "$dc" "$pod" \
        "SELECT count() FROM system.clusters WHERE cluster='global' AND is_local=1")
    assert_eq "$dc: 0 errors on remote federated shards" 0 "$err"
    assert_eq "$dc: exactly 1 local shard in global"     1 "$loc"
done

# ── 6b. Replica topology: each region runs a healthy 2-replica set ────────────
# otel_local is ReplicatedMergeTree; scaling spec.replicas adds a physical
# replica that Keeper keeps in sync. This is the precondition for the read/write
# tests below: the region's NodePort load-balances reads across exactly these pods.
log "Replica topology: 2 in-sync replicas of otel_local per region"
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    npods=$(ch_pods "$ctx" "$dc" | grep -c .)
    read -r tot act ro < <(chq "$ctx" "$dc" "$pod" \
        "SELECT total_replicas, active_replicas, is_readonly FROM system.replicas WHERE table='otel_local'" \
        --format TSV | tr '\t' ' ')
    assert_eq "$dc: 2 clickhouse-server pods Running"   2 "$npods"
    assert_eq "$dc: otel_local total_replicas = 2"      2 "$tot"
    assert_eq "$dc: otel_local active_replicas = 2"     2 "$act"
    assert_eq "$dc: otel_local not read-only (Keeper ok)" 0 "$ro"
done

# ── 6c. Write path across replicas: write one replica, read it on the other ───
# All writes target otel_local (never a Distributed table). Insert on replica 0,
# SYSTEM SYNC on replica 1, and assert the row is present there -- proving
# ReplicatedMergeTree replicates writes across the region's replicas.
# Uses a unique probe id and cleans it up so the seed invariant (1 row) holds.
log "Write path: insert on replica 0 replicates to replica 1"
PROBE_ID=7777
for dc in $DCS; do
    ctx=$(ctx_for "$dc")
    pods=()
    while IFS= read -r line; do [ -n "$line" ] && pods+=("$line"); done < <(ch_pods "$ctx" "$dc")
    if [ "${#pods[@]}" -lt 2 ]; then
        info "SKIP: $dc has <2 replicas (single-replica deployment)"
        continue
    fi
    p0="${pods[0]}"; p1="${pods[1]}"
    chq "$ctx" "$dc" "$p0" \
        "INSERT INTO default.otel_local (id,event_time,payload) VALUES ($PROBE_ID, now(), 'replica probe on $p0')" >/dev/null
    chq "$ctx" "$dc" "$p1" "SYSTEM SYNC REPLICA default.otel_local" >/dev/null
    seen=$(chq "$ctx" "$dc" "$p1" "SELECT count() FROM default.otel_local WHERE id=$PROBE_ID")
    assert_eq "$dc: write on $p0 replicated to $p1" 1 "$seen"
    # Cleanup on p0; the delete replicates back to p1 and restores the 1-row seed.
    chq "$ctx" "$dc" "$p0" "DELETE FROM default.otel_local WHERE id=$PROBE_ID" >/dev/null
    chq "$ctx" "$dc" "$p1" "SYSTEM SYNC REPLICA default.otel_local" >/dev/null
done

# ── 6d. Read path from every replica: any replica serves cross-DC reads ───────
# The region NodePort can route a federated read to EITHER replica, and each
# replica carries its own copy of the global remote_servers config + TLS certs +
# cluster secret. Query otel_global directly on every pod: all must return the
# full 3-region fan-out, or a read routed to that replica would fail.
log "Read path: otel_global returns all 3 regions from EVERY replica"
for dc in $DCS; do
    ctx=$(ctx_for "$dc")
    for p in $(ch_pods "$ctx" "$dc"); do
        reg=$(chq "$ctx" "$dc" "$p" "SELECT uniqExact(region) FROM default.otel_global")
        assert_eq "$dc/$p: otel_global returns 3 regions" 3 "$reg"
    done
done

# ── 7. Shard pruning ──────────────────────────────────────────────────────────
log "Pruning: profile defaults active (no inline SETTINGS needed)"
# Bool settings render as true/false; toUInt8 -> 1/0 for a clean comparison.
defaults=$(chq "$FRA_CTX" fra "$POD_FRA" "SELECT toUInt8(
    getSetting('optimize_skip_unused_shards') AND
    getSetting('allow_nondeterministic_optimize_skip_unused_shards'))")
assert_eq "optimize_skip_unused_shards + allow_nondeterministic default on" 1 "$defaults"

# The sharding key is dictGet(...) (non-deterministic); force_ turns the silent
# "did not prune" no-op into a hard UNABLE_TO_SKIP_UNUSED_SHARDS error.
log "Pruning: single-DC filter prunes (force = hard error if it can't)"
out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "SELECT count() FROM default.otel_global WHERE region = 'MUC' SETTINGS force_optimize_skip_unused_shards = 1")
if echo "$out" | grep -qE "UNABLE_TO_SKIP_UNUSED_SHARDS|not deterministic"; then
    fail "single-DC filter did not prune — $out"
else
    pass "single-DC filter pruned to 1 shard (count=$out)"
fi

# Pruning must not change results: a pruned read and a full fan-out must agree.
# Guards against a wrong region->shard mapping silently returning wrong rows.
log "Pruning correctness: pruned result == full fan-out result"
pruned=$(chq "$FRA_CTX" fra "$POD_FRA" "SELECT count() FROM default.otel_global WHERE region = 'MUC'")
full=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "SELECT count() FROM default.otel_global WHERE region = 'MUC' SETTINGS optimize_skip_unused_shards = 0")
assert_eq "region=MUC returns exactly the MUC row" 1 "$pruned"
assert_eq "pruned count matches full-fanout count" "$full" "$pruned"

log "Pruning: IN() filter prunes to exactly 2 shards (FRA skipped)"
out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "SELECT count() FROM default.otel_global WHERE region IN ('MUC','HAM') SETTINGS force_optimize_skip_unused_shards = 1")
if echo "$out" | grep -qE "UNABLE_TO_SKIP_UNUSED_SHARDS|not deterministic"; then
    fail "IN() filter did not prune — $out"
else
    assert_eq "IN('MUC','HAM') returns 2 rows" 2 "$out"
fi

log "Pruning: != predicate cannot prune (documented limitation -> hard error)"
out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "SELECT count() FROM default.otel_global WHERE region != 'FRA' SETTINGS force_optimize_skip_unused_shards = 1")
assert_match "!= predicate is rejected by force pruning" "UNABLE_TO_SKIP_UNUSED_SHARDS" "$out"

# ── 8. RBAC write-path matrix ─────────────────────────────────────────────────
# Invariant: all writes target otel_local; both Distributed tables reject writes.
# Writer: role-based, local-only (writers never read cross-DC). Reader: DIRECT
# grants on the user, created on EVERY DC -- the `global` cluster secret
# propagates the user identity but NOT its roles, so a role-based reader would
# fail on remote shards with ACCESS_DENIED (and a reader missing on a remote DC
# would break the inter-server connection outright).
log "RBAC: set up writer (role, local) + reader (direct grants, all DCs)"
chq "$FRA_CTX" fra "$POD_FRA" "
    CREATE USER IF NOT EXISTS rbac_writer IDENTIFIED WITH no_password;
    GRANT app_writer TO rbac_writer;
" --multiquery >/dev/null
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    chq "$ctx" "$dc" "$pod" "
        CREATE USER IF NOT EXISTS rbac_reader IDENTIFIED WITH no_password;
        GRANT SELECT ON default.otel_global   TO rbac_reader;
        GRANT SELECT ON default.otel_regional TO rbac_reader;
        GRANT SELECT ON default.otel_local    TO rbac_reader;
    " --multiquery >/dev/null
done

log "RBAC: app_writer denied on Distributed tables, allowed on otel_local"
out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.otel_global (id,event_time,payload,region) VALUES (9001, now(),'x','FRA')" --user rbac_writer)
assert_match "app_writer denied INSERT on otel_global" "Code: 497|Not enough privileges" "$out"

out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.otel_regional (id,event_time,payload) VALUES (9001, now(),'x')" --user rbac_writer)
assert_match "app_writer denied INSERT on otel_regional" "Code: 497|Not enough privileges" "$out"

out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.otel_local (id,event_time,payload) VALUES (9002, now(),'writer ok')" --user rbac_writer)
assert_ok "app_writer allowed INSERT on otel_local" "$out"

log "RBAC: reader is read-only"
out=$(chq "$FRA_CTX" fra "$POD_FRA" \
    "INSERT INTO default.otel_local (id,event_time,payload) VALUES (9003, now(),'reader denied')" --user rbac_reader)
assert_match "reader denied INSERT on otel_local" "Code: 497|Not enough privileges" "$out"

# Cross-DC read under the reader's OWN credentials: the secret propagates
# rbac_reader to MUC/HAM and each shard enforces its direct SELECT grants.
# uniqExact(region)=3 proves the fan-out actually reached all 3 DCs (not just a
# no-error local read).
out=$(chq "$FRA_CTX" fra "$POD_FRA" "SELECT uniqExact(region) FROM default.otel_global" --user rbac_reader)
assert_eq "reader reads all 3 regions from otel_global (cross-DC RBAC via secret)" 3 "$out"

chq "$FRA_CTX" fra "$POD_FRA" "DROP USER IF EXISTS rbac_writer" --multiquery >/dev/null
# rbac_reader was created on every DC (cross-DC user), so drop it on every DC.
for dc in $DCS; do
    ctx=$(ctx_for "$dc"); pod=$(pod_for "$dc")
    chq "$ctx" "$dc" "$pod" "DROP USER IF EXISTS rbac_reader" >/dev/null
done
# Delete only the writer-ok test row (id 9002); a TRUNCATE here would wipe FRA's
# seed row too, leaving the cluster asymmetric (FRA empty) after every run.
chq "$FRA_CTX" fra "$POD_FRA" "DELETE FROM default.otel_local WHERE id = 9002" >/dev/null

# ── Summary ───────────────────────────────────────────────────────────────────
log "Verification complete: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
