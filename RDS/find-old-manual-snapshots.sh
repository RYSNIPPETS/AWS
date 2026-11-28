#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: find-old-manual-snapshots.sh [--days N] [--type instance|cluster|all]

List manual RDS instance and cluster snapshots created at least N days ago in the
configured region. The defaults are 90 days and both snapshot types. Output is TSV.
EOF
}

days=90
type=all
while (( $# > 0 )); do
  case "$1" in
    --days) [[ $# -ge 2 ]] || die "--days requires a value"; days="$2"; shift 2 ;;
    --type) [[ $# -ge 2 ]] || die "--type requires a value"; type="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

case "$type" in
  all | instance | cluster) ;;
  *) die "--type must be instance, cluster, or all" ;;
esac
days="$(validate_positive_integer "--days" "$days")"
require_aws
require_jq
region="$(require_region)"
snapshots="$(
  if [[ "$type" != cluster ]]; then
    aws rds describe-db-snapshots --region "$region" --snapshot-type manual --output json || exit
  fi
  if [[ "$type" != instance ]]; then
    aws rds describe-db-cluster-snapshots --region "$region" --snapshot-type manual --output json || exit
  fi
)"
rows="$(jq -sr --arg days "$days" "$aws_timestamp_jq"'
  (now - (($days | tonumber) * 86400)) as $cutoff
  | .[]
  | ((.DBSnapshots[]? | [.DBSnapshotIdentifier, .DBInstanceIdentifier,
        .SnapshotCreateTime, .Engine, .AllocatedStorage, .Encrypted, "instance"]),
     (.DBClusterSnapshots[]? | [.DBClusterSnapshotIdentifier, .DBClusterIdentifier,
        .SnapshotCreateTime, .Engine, .AllocatedStorage, .StorageEncrypted, "cluster"]))
  | select(.[2] != null and ((.[2] | aws_timestamp) <= $cutoff))
  | @tsv
' <<<"$snapshots")"
printf 'SNAPSHOT_ID\tDB_IDENTIFIER\tCREATED\tENGINE\tSIZE_GIB\tENCRYPTED\tTYPE\n'
if [[ -n "$rows" ]]; then
  printf '%s\n' "$rows"
fi
