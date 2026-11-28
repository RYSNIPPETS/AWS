#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: daily-costs.sh [--days N] [--billing-view-arn ARN]

Show daily unblended cost totals for the last N completed UTC days. The default is
14 days. Cost Explorer data can lag behind current usage. Output is TSV.
EOF
}

days=14
billing_view=""
while (( $# > 0 )); do
  case "$1" in
    --days) [[ $# -ge 2 ]] || die "--days requires a value"; days="$2"; shift 2 ;;
    --billing-view-arn) [[ -n "${2:-}" ]] || die "--billing-view-arn requires an ARN"; billing_view="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

days="$(validate_positive_integer "--days" "$days")"
require_aws
require_jq
start="$(utc_days_ago "$days")"
end="$(utc_date)"

args=(--time-period "Start=${start},End=${end}" --granularity DAILY --metrics UnblendedCost)
if [[ -n "$billing_view" ]]; then
  args+=(--billing-view-arn "$billing_view")
fi
costs="$(cost_explorer_periods "${args[@]}" | jq -s 'sort_by(.TimePeriod.Start)')"

printf 'DATE\tAMOUNT\tUNIT\tESTIMATED\n'
jq -r '.[]
  | [.TimePeriod.Start, .Total.UnblendedCost.Amount,
     .Total.UnblendedCost.Unit, .Estimated]
  | @tsv' <<<"$costs"
