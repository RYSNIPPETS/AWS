#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: whoami.sh

Show the active AWS identity, account alias, configured region, and profile. This is
a read-only preflight check to run before operating on an account.
EOF
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  '') ;;
  *) usage >&2; die "Unknown argument: $1" ;;
esac

require_aws
require_jq

identity="$(aws sts get-caller-identity --output json)"
if aliases="$(aws iam list-account-aliases --output json)"; then
  alias_name="$(jq -r '.AccountAliases[0] // empty' <<<"$aliases")"
  alias_status=absent
  [[ -z "$alias_name" ]] || alias_status=present
else
  alias_name=""
  alias_status=unreadable
  warn "Could not read the IAM account alias."
fi
region="$(configured_region)"
profile="${AWS_DEFAULT_PROFILE:-${AWS_PROFILE:-default credential chain}}"

jq -n \
  --argjson identity "$identity" \
  --arg alias "$alias_name" \
  --arg alias_status "$alias_status" \
  --arg region "$region" \
  --arg profile "$profile" \
  '{
    account_id: $identity.Account,
    account_alias: (if $alias == "" then null else $alias end),
    account_alias_status: $alias_status,
    principal_arn: $identity.Arn,
    user_id: $identity.UserId,
    region: (if $region == "" then null else $region end),
    profile: $profile
  }'
