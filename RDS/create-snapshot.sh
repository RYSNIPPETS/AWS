#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: create-snapshot.sh (--db DB_IDENTIFIER | --cluster CLUSTER_IDENTIFIER)
                          [--snapshot SNAPSHOT_IDENTIFIER] [--execute] [--yes]

Preview a manual DB instance or DB cluster snapshot. Use --snapshot to keep the
same identifier across preview and execution. Otherwise each run generates a
timestamped identifier. Creation requires --execute and can incur storage charges.
--yes skips the interactive confirmation.
EOF
}

db_id=""
cluster_id=""
snapshot_id=""
execute=false
ASSUME_YES=false
while (( $# > 0 )); do
  case "$1" in
    --db) [[ $# -ge 2 ]] || die "--db requires an identifier"; db_id="$2"; shift 2 ;;
    --cluster) [[ $# -ge 2 ]] || die "--cluster requires an identifier"; cluster_id="$2"; shift 2 ;;
    --snapshot) [[ $# -ge 2 ]] || die "--snapshot requires an identifier"; snapshot_id="$2"; shift 2 ;;
    --execute) execute=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

if [[ -n "$db_id" && -z "$cluster_id" ]]; then
  identifier="$db_id"
  resource=instance
  snapshot_option=db-snapshot-identifier
  description_query='DBInstances[0].{Identifier:DBInstanceIdentifier,Engine:Engine,Status:DBInstanceStatus,Class:DBInstanceClass,Cluster:DBClusterIdentifier}'
  snapshot_query='DBSnapshot.{SnapshotId:DBSnapshotIdentifier,DB:DBInstanceIdentifier,Status:Status,Created:SnapshotCreateTime}'
  limit=255
elif [[ -n "$cluster_id" && -z "$db_id" ]]; then
  identifier="$cluster_id"
  resource=cluster
  snapshot_option=db-cluster-snapshot-identifier
  description_query='DBClusters[0].{Identifier:DBClusterIdentifier,Engine:Engine,Status:Status}'
  snapshot_query='DBClusterSnapshot.{SnapshotId:DBClusterSnapshotIdentifier,DB:DBClusterIdentifier,Status:Status,Created:SnapshotCreateTime}'
  limit=63
else
  die "Specify exactly one of --db and --cluster."
fi
if [[ -z "$snapshot_id" ]]; then
  suffix="-manual-$(date -u '+%Y%m%d-%H%M%S')"
  stem_length=$((limit - ${#suffix}))
  stem="${identifier:0:stem_length}"
  snapshot_id="${stem%-}$suffix"
fi
[[ "$snapshot_id" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ && "$snapshot_id" != *--* &&
   "$snapshot_id" != *- && "${#snapshot_id}" -le "$limit" ]] ||
  die "Snapshot identifier must start with a letter, contain at most $limit letters, digits, or hyphens, and contain no consecutive or trailing hyphens."

require_aws
require_jq
region="$(require_region)"

description="$(aws rds "describe-db-${resource}s" --region "$region" \
  "--db-$resource-identifier=$identifier" --query "$description_query" --output json)"
status="$(jq -er '.Status' <<<"$description")" || die "Could not determine status for $identifier."
if jq -e '.Cluster != null' <<<"$description" >/dev/null; then
  die "This instance belongs to a DB cluster. Use --cluster $(jq -r '.Cluster' <<<"$description")."
fi
case "$resource:$status" in
  instance:available | instance:storage-optimization | cluster:available) ;;
  *) die "The DB $resource $identifier is in state $status and is ineligible for a snapshot." ;;
esac
jq . <<<"$description"
info "Proposed snapshot identifier: ${snapshot_id}"

if [[ "$execute" != "true" ]]; then
  warn "Preview only. Re-run with --execute to create the snapshot."
  exit 0
fi

confirm "Create manual snapshot ${snapshot_id} from ${identifier}?"
operation=create-db-snapshot
[[ "$resource" != cluster ]] || operation=create-db-cluster-snapshot
aws rds "$operation" \
  --region "$region" \
  "--db-$resource-identifier=$identifier" \
  "--$snapshot_option=$snapshot_id" \
  --query "$snapshot_query" \
  --output table
