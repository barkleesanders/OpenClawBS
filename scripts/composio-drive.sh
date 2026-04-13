#!/bin/bash
# Composio-backed Google Drive helper
# Replaces rclone with Composio-managed OAuth (auto-refreshes, never expires)
#
# Requires env var: COMPOSIO_API_KEY
#
# Functions:
#   drive_upload FILE PARENT_FOLDER_ID [REMOTE_NAME]  - upload file to folder
#   drive_list PARENT_FOLDER_ID                       - list files in folder (id<TAB>name<TAB>createdTime)
#   drive_delete FILE_ID                              - delete file by id
#   drive_purge_folder PARENT_FOLDER_ID                - delete all children (non-recursive)
#   drive_delete_older_than PARENT_FOLDER_ID DAYS     - delete files older than N days
#   drive_upload_tree LOCAL_DIR PARENT_FOLDER_ID      - recursively upload dir contents

: "${COMPOSIO_API_KEY:?COMPOSIO_API_KEY not set}"

_COMPOSIO_HOST="backend.composio.dev"
_TOKEN_CACHE=""

# Fetch a fresh Google Drive OAuth token from Composio.
# Composio auto-refreshes — token is always valid at fetch time.
drive_get_token() {
  if [ -n "$_TOKEN_CACHE" ]; then
    echo "$_TOKEN_CACHE"
    return 0
  fi
  local token
  token=$(curl -sS --max-time 15 -H "X-API-Key: ${COMPOSIO_API_KEY}" \
    "https://${_COMPOSIO_HOST}/api/v3/connected_accounts?toolkit_slug=googledrive&limit=100" \
    | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
for a in d.get('items', []):
    if a.get('toolkit', {}).get('slug') == 'googledrive' and a.get('status') == 'ACTIVE':
        tok = a.get('data', {}).get('access_token', '')
        if tok:
            print(tok); sys.exit(0)
sys.exit(1)
" 2>/dev/null)
  if [ -z "$token" ]; then
    echo "drive_get_token: failed to retrieve token from Composio" >&2
    return 1
  fi
  _TOKEN_CACHE="$token"
  echo "$token"
}

# Upload a file using Drive API multipart upload.
# Handles files up to ~5MB in one shot; larger files use resumable upload.
drive_upload() {
  local file="$1"
  local parent="$2"
  local remote_name="${3:-$(basename "$file")}"
  [ -f "$file" ] || { echo "drive_upload: $file not found" >&2; return 1; }

  local token; token=$(drive_get_token) || return 1
  local size; size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null)

  # Guess mime type from extension
  local mime="application/octet-stream"
  case "$file" in
    *.gz)  mime="application/gzip" ;;
    *.sql) mime="application/sql" ;;
    *.json) mime="application/json" ;;
    *.txt) mime="text/plain" ;;
    *.pdf) mime="application/pdf" ;;
    *.jpg|*.jpeg) mime="image/jpeg" ;;
    *.png) mime="image/png" ;;
  esac

  # Use resumable upload for files > 5MB; multipart for small files
  if [ "${size:-0}" -gt 5242880 ]; then
    _drive_upload_resumable "$file" "$parent" "$remote_name" "$mime" "$token"
  else
    _drive_upload_multipart "$file" "$parent" "$remote_name" "$mime" "$token"
  fi
}

_drive_upload_multipart() {
  local file="$1" parent="$2" name="$3" mime="$4" token="$5"
  local boundary="==composio-$(date +%s%N)=="
  local body=$(mktemp)
  {
    printf -- "--%s\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n" "$boundary"
    printf '{"name":"%s","parents":["%s"]}' "$name" "$parent"
    printf "\r\n--%s\r\nContent-Type: %s\r\n\r\n" "$boundary" "$mime"
    cat "$file"
    printf "\r\n--%s--\r\n" "$boundary"
  } > "$body"

  local response http_code
  response=$(curl -sS -w "\n__HTTP__%{http_code}" -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: multipart/related; boundary=${boundary}" \
    --data-binary @"$body" \
    --max-time 300 \
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,name,size")
  rm -f "$body"

  http_code=$(echo "$response" | grep -oE '__HTTP__[0-9]+' | tail -1 | cut -d_ -f5)
  local payload; payload=$(echo "$response" | sed 's/__HTTP__[0-9]*$//')
  if [ "$http_code" != "200" ]; then
    echo "drive_upload failed ($http_code): $payload" >&2
    return 1
  fi
  local id; id=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  echo "$id"
}

_drive_upload_resumable() {
  local file="$1" parent="$2" name="$3" mime="$4" token="$5"
  local size; size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null)

  # Initiate resumable session: capture headers with -D to a file; body discarded
  local headers_file; headers_file=$(mktemp)
  local init_body
  init_body=$(python3 -c "
import json, sys
print(json.dumps({'name': sys.argv[1], 'parents': [sys.argv[2]]}))
" "$name" "$parent")

  local http_code
  http_code=$(curl -sS -o /dev/null -D "$headers_file" -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json; charset=UTF-8" \
    -H "X-Upload-Content-Type: $mime" \
    -H "X-Upload-Content-Length: $size" \
    --data-raw "$init_body" \
    --max-time 30 \
    "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id")

  if [ "$http_code" != "200" ]; then
    echo "drive_upload resumable init failed: HTTP $http_code" >&2
    cat "$headers_file" >&2
    rm -f "$headers_file"
    return 1
  fi

  local session_url
  session_url=$(grep -i '^location:' "$headers_file" | head -1 | sed 's/^[Ll]ocation: *//I' | tr -d '\r\n')
  rm -f "$headers_file"

  if [ -z "$session_url" ]; then
    echo "drive_upload resumable: init returned 200 but no Location header" >&2
    return 1
  fi

  local response put_code
  response=$(curl -sS -w "\n__HTTP__%{http_code}" -X PUT \
    -H "Content-Type: $mime" \
    -H "Content-Length: $size" \
    --data-binary @"$file" \
    --max-time 900 \
    "$session_url")
  put_code=$(echo "$response" | grep -oE '__HTTP__[0-9]+' | tail -1 | cut -d_ -f5)
  if [ "$put_code" != "200" ] && [ "$put_code" != "201" ]; then
    echo "drive_upload resumable PUT failed ($put_code): $(echo "$response" | sed 's/__HTTP__[0-9]*$//' | head -c 400)" >&2
    return 1
  fi
  local id; id=$(echo "$response" | sed 's/__HTTP__[0-9]*$//' | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
  echo "$id"
}

# List files in a folder. Output: <id>\t<name>\t<createdTime>
drive_list() {
  local parent="$1"
  local token; token=$(drive_get_token) || return 1
  local page_token=""
  while :; do
    local url="https://www.googleapis.com/drive/v3/files?q=%27${parent}%27+in+parents+and+trashed%3Dfalse&fields=nextPageToken,files(id,name,createdTime)&pageSize=1000"
    [ -n "$page_token" ] && url="${url}&pageToken=${page_token}"
    local resp; resp=$(curl -sS -H "Authorization: Bearer $token" --max-time 30 "$url")
    echo "$resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for f in d.get('files', []):
    print(f\"{f['id']}\t{f['name']}\t{f.get('createdTime','')}\")
"
    page_token=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('nextPageToken',''))" 2>/dev/null)
    [ -z "$page_token" ] && break
  done
}

drive_delete() {
  local id="$1"
  local token; token=$(drive_get_token) || return 1
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X DELETE \
    -H "Authorization: Bearer $token" --max-time 30 \
    "https://www.googleapis.com/drive/v3/files/${id}")
  if [ "$code" != "204" ]; then
    echo "drive_delete $id failed ($code)" >&2
    return 1
  fi
}

# Delete all files in a folder (non-recursive).
drive_purge_folder() {
  local parent="$1"
  drive_list "$parent" | while IFS=$'\t' read -r id name created; do
    [ -z "$id" ] && continue
    drive_delete "$id" || echo "purge: failed to delete $name" >&2
  done
}

# Delete files in folder older than N days (by createdTime).
drive_delete_older_than() {
  local parent="$1"
  local days="$2"
  local cutoff; cutoff=$(date -u -d "$days days ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -v-${days}d '+%Y-%m-%dT%H:%M:%SZ')
  drive_list "$parent" | while IFS=$'\t' read -r id name created; do
    [ -z "$id" ] && continue
    if [[ "$created" < "$cutoff" ]]; then
      drive_delete "$id" && echo "deleted (old): $name"
    fi
  done
}

# Recursively upload all files in a local directory to a Drive folder.
# Subdirectories are created as Drive folders.
# Robust under `set -euo pipefail` in callers.
drive_upload_tree() {
  local local_dir="$1"
  local parent="$2"
  local token; token=$(drive_get_token) || return 1
  [ -d "$local_dir" ] || { echo "drive_upload_tree: $local_dir not a directory" >&2; return 1; }

  # Save + relax shell options for associative-array lookups in this function
  local _prev_u; _prev_u=$(set +o | grep nounset)
  set +u

  declare -A FOLDER_MAP
  FOLDER_MAP["."]="$parent"

  # Collect sorted list of subdirs (shortest paths first)
  local tree_plan="/tmp/_drive_tree_plan_$$.txt"
  (cd "$local_dir" && find . -mindepth 1 -type d | sort) > "$tree_plan"

  # Create each folder in Drive, building the map serially
  local rel parent_rel parent_id basename resp fid
  while IFS= read -r rel; do
    rel="${rel#./}"
    parent_rel=$(dirname "$rel")
    [ "$parent_rel" = "." ] || parent_rel="${parent_rel}"
    parent_id="${FOLDER_MAP[$parent_rel]:-$parent}"
    basename=$(basename "$rel")
    resp=$(curl -sS -X POST \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --max-time 30 \
      -d "$(printf '{"name":"%s","mimeType":"application/vnd.google-apps.folder","parents":["%s"]}' "$basename" "$parent_id")" \
      "https://www.googleapis.com/drive/v3/files?fields=id")
    fid=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
    if [ -n "$fid" ]; then
      FOLDER_MAP["$rel"]="$fid"
    else
      echo "upload_tree: failed to create Drive folder '$rel'" >&2
    fi
  done < "$tree_plan"
  rm -f "$tree_plan"

  # Upload files (with 1 retry on transient failure, visible errors)
  local uploaded=0 failed=0 file subdir folder_id upload_err
  while IFS= read -r file; do
    rel="${file#$local_dir/}"
    subdir=$(dirname "$rel")
    [ "$subdir" = "." ] && subdir="."
    folder_id="${FOLDER_MAP[$subdir]:-$parent}"
    upload_err=$(drive_upload "$file" "$folder_id" 2>&1 >/dev/null)
    if [ -z "$upload_err" ]; then
      uploaded=$((uploaded + 1))
      continue
    fi
    # Retry once after a short delay
    sleep 2
    upload_err=$(drive_upload "$file" "$folder_id" 2>&1 >/dev/null)
    if [ -z "$upload_err" ]; then
      uploaded=$((uploaded + 1))
    else
      failed=$((failed + 1))
      echo "upload_tree: failed $rel -- $upload_err" >&2
    fi
  done < <(find "$local_dir" -type f)

  # Restore shell options
  eval "$_prev_u"

  echo "drive_upload_tree: uploaded=$uploaded failed=$failed"
  [ "$failed" -eq 0 ]
}

# CLI mode
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    token)         drive_get_token ;;
    upload)        drive_upload "$@" ;;
    list)          drive_list "$@" ;;
    delete)        drive_delete "$@" ;;
    purge)         drive_purge_folder "$@" ;;
    delete-older)  drive_delete_older_than "$@" ;;
    upload-tree)   drive_upload_tree "$@" ;;
    *) echo "Usage: $0 {token|upload|list|delete|purge|delete-older|upload-tree} [args]" >&2; exit 2 ;;
  esac
fi
