#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: audit-public-access.sh [--object-acls] [--directory-region REGION | --general-only]

Review S3 policy status, bucket ACLs, and public access blocks. --object-acls
checks object version ACLs where ACLs are enabled, with an API call per version.
Without that flag, applicable object ACLs are reported as NOT_SCANNED.
Directory buckets are included in the configured region (default us-east-1).
Account-level blocks and coverage limits are reported separately. Output is TSV.
EOF
}

directory_region=""
include_directory=true
scan_objects=false
while (( $# > 0 )); do
  case "$1" in
    --directory-region) [[ -n "${2:-}" ]] || die "--directory-region requires a region"; directory_region="$2"; shift 2 ;;
    --general-only) include_directory=false; shift ;;
    --object-acls) scan_objects=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

require_aws
require_jq

region="${directory_region:-$(configured_region)}"
region="${region:-us-east-1}"
account_id="$(aws sts get-caller-identity --query Account --output text)"
account_ignores_acls=UNKNOWN
if account_block="$(aws s3control get-public-access-block --account-id "$account_id" \
  --region "$region" --output json 2>&1)"; then
  info "Account-level public access block: $(jq -c '.PublicAccessBlockConfiguration' \
    <<<"$account_block")"
  account_ignores_acls="$(jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls | if . == null then "UNKNOWN" else . end' \
    <<<"$account_block")"
elif [[ "$account_block" == *NoSuchPublicAccessBlockConfiguration* ]]; then
  info "Account-level public access block is not configured."
  account_ignores_acls=false
else
  warn "Account-level public access block could not be read."
fi

acl_has_public_grant() {
  jq -r '
    if (.Grants | type) != "array" then "UNKNOWN"
    else any(.Grants[].Grantee.URI;
      . == "http://acs.amazonaws.com/groups/global/AllUsers" or
      . == "http://acs.amazonaws.com/groups/global/AuthenticatedUsers")
    end'
}

scan_object_acls() {
  local bucket="$1" region="$2" request versions acl value assessment=false
  if ! versions="$(aws s3api list-object-versions --bucket "$bucket" --region "$region" \
    --page-size 1000 --output json | jq -c --arg bucket "$bucket" '
      .Versions[]? | {Bucket: $bucket, Key, VersionId}')"; then
    printf 'UNKNOWN\n'
    return
  fi
  while IFS= read -r request; do
    [[ -n "$request" ]] || continue
    if acl="$(aws s3api get-object-acl --region "$region" --cli-input-json "$request" --output json)" &&
      value="$(acl_has_public_grant <<<"$acl")"; then
      case "$value" in
        true) printf 'true\n'; return ;;
        false) ;;
        *) assessment=UNKNOWN ;;
      esac
    else
      assessment=UNKNOWN
    fi
  done <<<"$versions"
  printf '%s\n' "$assessment"
}

buckets="$(s3_buckets "$region" "$include_directory" | jq -r '
  [.Name, (.BucketRegion // "-"), .BucketType] | @tsv')"
printf 'BUCKET\tPOLICY_PUBLIC\tACL_PUBLIC\tALL_BUCKET_BLOCKS\tASSESSMENT\tOBJECT_ACL_PUBLIC\tTYPE\tREGION\n'
while IFS=$'\t' read -r bucket location type; do
  [[ -n "$bucket" ]] || continue
  if [[ "$type" == directory ]]; then
    printf '%s\tUNSUPPORTED\tDISABLED\ttrue\tBLOCKED_BY_DESIGN\tDISABLED\tdirectory\t%s\n' "$bucket" "$location"
    continue
  fi
  if ! location="$(s3_bucket_region "$bucket" "$location" "$region")"; then
    printf '%s\tUNKNOWN\tUNKNOWN\tUNKNOWN\tINCOMPLETE_DATA\tUNKNOWN\tgeneral\tUNKNOWN\n' "$bucket"
    continue
  fi

  policy_public="UNKNOWN"
  if policy_json="$(aws s3api get-bucket-policy-status --bucket "$bucket" --region "$location" \
    --output json 2>&1)"; then
    policy_public="$(jq -r '.PolicyStatus.IsPublic | if . == null then "UNKNOWN" else . end' <<<"$policy_json")"
  elif [[ "$policy_json" == *NoSuchBucketPolicy* ]]; then
    policy_public="false"
  fi

  all_blocks="UNKNOWN"
  bucket_ignores_acls="UNKNOWN"
  if block_json="$(aws s3api get-public-access-block --bucket "$bucket" --region "$location" \
    --output json 2>&1)"; then
    all_blocks="$(jq -r '[.PublicAccessBlockConfiguration.BlockPublicAcls,
      .PublicAccessBlockConfiguration.IgnorePublicAcls,
      .PublicAccessBlockConfiguration.BlockPublicPolicy,
      .PublicAccessBlockConfiguration.RestrictPublicBuckets]
      | if all(type == "boolean") then all else "UNKNOWN" end' <<<"$block_json")"
    bucket_ignores_acls="$(jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls | if . == null then "UNKNOWN" else . end' \
      <<<"$block_json")"
  elif [[ "$block_json" == *NoSuchPublicAccessBlockConfiguration* ]]; then
    all_blocks="false"
    bucket_ignores_acls="false"
  fi

  ownership="UNKNOWN"
  if controls="$(aws s3api get-bucket-ownership-controls --bucket "$bucket" --region "$location" --output json 2>&1)"; then
    ownership="$(jq -r '.OwnershipControls.Rules[0].ObjectOwnership // "UNKNOWN"' <<<"$controls")"
  elif [[ "$controls" == *OwnershipControlsNotFoundError* ]]; then
    ownership=ObjectWriter
  fi

  acl_public=UNKNOWN
  object_acl_public=NOT_SCANNED
  if [[ "$ownership" == BucketOwnerEnforced ]]; then
    acl_public=DISABLED
    object_acl_public=DISABLED
  elif [[ "$bucket_ignores_acls" == true || "$account_ignores_acls" == true ]]; then
    acl_public=MASKED
    object_acl_public=MASKED
  else
    if acl_json="$(aws s3api get-bucket-acl --bucket "$bucket" --region "$location" --output json 2>/dev/null)"; then
      acl_public="$(acl_has_public_grant <<<"$acl_json")"
    fi
    if [[ "$scan_objects" == true ]]; then
      object_acl_public="$(scan_object_acls "$bucket" "$location")"
    fi
  fi

  assessment=INCOMPLETE_DATA
  if [[ "$policy_public" == true || "$acl_public" == true || "$object_acl_public" == true ]]; then
    if [[ "$all_blocks" == "true" ]]; then
      assessment="PUBLIC_CONFIGURATION_BLOCKED_AT_BUCKET"
    else
      assessment="REVIEW_PUBLIC_ACCESS"
    fi
  elif [[ "$policy_public" == false && "$all_blocks" != UNKNOWN ]] &&
    { [[ "$ownership" == BucketOwnerEnforced ]] ||
      [[ "$acl_public" == false && "$object_acl_public" == false &&
         "$bucket_ignores_acls" == false && "$account_ignores_acls" == false ]]; }; then
    assessment=NO_PUBLIC_GRANTS_OBSERVED
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\tgeneral\t%s\n' \
    "$bucket" "$policy_public" "$acl_public" "$all_blocks" "$assessment" "$object_acl_public" "$location"
done <<<"$buckets"
