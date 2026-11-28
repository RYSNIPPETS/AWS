#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: inventory.sh [--output table|json|text]

List Lambda functions in the configured region. The default output is a table.
Requires lambda:ListFunctions and lambda:GetFunctionConfiguration.
EOF
}

output=table
while (( $# > 0 )); do
  case "$1" in
    --output) [[ $# -ge 2 ]] || die "--output requires a value"; output="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

validate_output "$output"
require_aws
require_jq
region="$(require_region)"

names="$(aws lambda list-functions --region "$region" --query 'Functions[].FunctionName' \
  --output json | jq -r '.[]')"
inventory="$(
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    aws lambda get-function-configuration --region "$region" --function-name="$name" \
      --query '{Function:FunctionName,Runtime:Runtime,Architectures:join(`,`,Architectures || `[]`),MemoryMiB:MemorySize,TimeoutSeconds:Timeout,CodeSizeBytes:CodeSize,Modified:LastModified,State:State,PackageType:PackageType}' \
      --output json || exit
  done <<<"$names" | jq -s '.'
)"

if [[ "$output" == json ]]; then
  printf '%s\n' "$inventory"
  exit 0
fi
rows="$(jq -r '.[] | [.Architectures, .CodeSizeBytes, .Function, .MemoryMiB, .Modified,
          .PackageType, .Runtime, .State, .TimeoutSeconds] | map(. // "-") | @tsv' <<<"$inventory")"
[[ -n "$rows" ]] || exit 0
if [[ "$output" == text ]]; then
  printf '%s\n' "$rows"
else
  {
    printf 'Architectures\tCodeSizeBytes\tFunction\tMemoryMiB\tModified\tPackageType\tRuntime\tState\tTimeoutSeconds\n'
    printf '%s\n' "$rows"
  } | awk -F '\t' '
    {
      lines[NR] = $0
      for (i = 1; i <= NF; i++) if (length($i) > widths[i]) widths[i] = length($i)
    }
    END {
      for (row = 1; row <= NR; row++) {
        count = split(lines[row], fields, FS)
        for (i = 1; i < count; i++) printf "%-*s  ", widths[i], fields[i]
        print fields[count]
      }
    }'
fi
