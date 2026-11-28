#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: month-to-date.sh [--billing-view-arn ARN]

Show month-to-date unblended cost grouped by AWS service. Cost Explorer's end date is
exclusive, so the report covers the first of the month through the last completed UTC
day. Output is TSV, sorted from highest to lowest amount.
EOF
}

billing_view=""
while (( $# > 0 )); do
  case "$1" in
    --billing-view-arn) [[ -n "${2:-}" ]] || die "--billing-view-arn requires an ARN"; billing_view="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

require_aws
require_jq
start="$(utc_first_day_of_month)"
end="$(utc_date)"
if [[ "$start" == "$end" ]]; then
  die "No completed UTC day exists in the current month yet; retry tomorrow."
fi

args=(--time-period "Start=${start},End=${end}" --granularity MONTHLY
  --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE)
if [[ -n "$billing_view" ]]; then
  args+=(--billing-view-arn "$billing_view")
fi
costs="$(cost_explorer_periods "${args[@]}" | jq -s '.')"

printf 'SERVICE\tAMOUNT\tUNIT\tPERIOD_START\tPERIOD_END_EXCLUSIVE\n'
jq -r '
  [.[] as $period
   | $period.Groups[]
   | {service: .Keys[0], amount: .Metrics.UnblendedCost.Amount,
      unit: .Metrics.UnblendedCost.Unit, start: $period.TimePeriod.Start,
      end: $period.TimePeriod.End}]
  | sort_by(.amount | tonumber) | reverse[]
  | [.service, .amount, .unit, .start, .end]
  | @tsv
' <<<"$costs"
