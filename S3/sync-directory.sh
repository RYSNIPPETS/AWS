#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../Shared/aws.sh
source "$SCRIPT_DIR/../Shared/aws.sh"

usage() {
  cat <<'EOF'
Usage: sync-directory.sh --source DIR --destination s3://BUCKET/PREFIX
                         [--delete] [--execute] [--yes]

Preview an upload from a local directory. Symbolic links are skipped. --delete
previews an exact list of destination keys absent from the source and deletes
only those keys after the upload finishes and if their S3 ETags still match.
--execute starts the sync after the preview. --yes skips interactive confirmation.
EOF
}

source_dir=""
destination=""
delete=false
execute=false
ASSUME_YES=false
while (( $# > 0 )); do
  case "$1" in
    --source) [[ $# -ge 2 ]] || die "--source requires a directory"; source_dir="$2"; shift 2 ;;
    --destination) [[ $# -ge 2 ]] || die "--destination requires an S3 URI"; destination="$2"; shift 2 ;;
    --delete) delete=true; shift ;;
    --execute) execute=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -d "$source_dir" ]] || die "Source directory does not exist: $source_dir"
[[ "$destination" =~ ^s3://([^/]+)(/.*)?$ ]] || die "Destination must be s3://BUCKET or s3://BUCKET/PREFIX"
bucket="${BASH_REMATCH[1]}"
prefix="${BASH_REMATCH[2]:-}"
prefix="${prefix#/}"
if [[ -n "$prefix" && "$prefix" != */ ]]; then
  prefix="$prefix/"
fi
source_dir="$(CDPATH= cd -P -- "$source_dir" && pwd -P)"
require_aws

sync_args=("$source_dir" "$destination" --no-follow-symlinks)
info "Previewing uploads: ${source_dir} -> ${destination}"
aws s3 sync "${sync_args[@]}" --dryrun

# A key can contain newlines. Read the JSON string without stripping any of them.
local_counterpart() {
  local key relative
  key="$(jq -er '.Key + "."' <<<"$1")" || return 2
  key="${key%.}"
  [[ "$key" == "$prefix"* ]] || return 2
  relative="${key#"$prefix"}"
  # Path aliases and directory markers have no unambiguous local file counterpart.
  case "/$relative/" in
    *//* | */./* | */../*) return 0 ;;
  esac
  [[ -e "$source_dir/$relative" || -L "$source_dir/$relative" ]]
}

if [[ "$delete" == "true" ]]; then
  require_jq
  find "$source_dir" -type d -print >/dev/null || die "Could not scan the entire source directory."
  staging="$(mktemp -d "${TMPDIR:-/tmp}/s3-sync.XXXXXXXX")"
  trap 'rm -rf -- "$staging"' EXIT
  aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --page-size 1000 \
    --output json | jq -c '
      (.Contents // [])[]
      | if (.Key | type == "string" and length > 0 and (contains("\u0000") | not))
           and (.ETag | type == "string" and length > 0)
        then {Key, ETag} else error("S3 returned a key or ETag that cannot be checked") end
    ' >"$staging/objects"
  : >"$staging/delete"
  while IFS= read -r object; do
    if local_counterpart "$object"; then
      continue
    elif [[ $? -ne 1 ]]; then
      die "Could not map a destination key to the source directory."
    fi
    printf '%s\n' "$object" >>"$staging/delete"
    printf '(dryrun) delete: %s\n' "$(jq -c '.Key' <<<"$object")"
  done <"$staging/objects"
fi

if [[ "$execute" != "true" ]]; then
  warn "Preview only. Re-run with --execute to perform this sync."
  exit 0
fi

if [[ "$delete" == "true" ]]; then
  confirm "Sync now and delete the previewed destination objects?"
else
  confirm "Sync this directory now?"
fi
aws s3 sync "${sync_args[@]}"
if [[ "$delete" == true ]]; then
  find "$source_dir" -type d -print >/dev/null || die "Could not rescan the entire source directory."
  while IFS= read -r object; do
    if local_counterpart "$object"; then
      warn "Keeping a destination key that now exists in the local source."
      continue
    elif [[ $? -ne 1 ]]; then
      die "Could not recheck a destination key against the local source."
    fi
    request="$(jq -c --arg bucket "$bucket" '{Bucket: $bucket, Key, IfMatch: .ETag}' <<<"$object")"
    aws s3api delete-object --cli-input-json "$request" --output json >/dev/null
    printf 'delete: %s\n' "$(jq -c '.Key' <<<"$object")"
  done <"$staging/delete"
fi
