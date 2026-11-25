#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_XCCONFIG="$REPO_ROOT/Config/Local.xcconfig"

TEAM_ID=""
BUNDLE_PREFIX=""
ENABLE_APNS=""
MAC_SIGN_IDENTITY=""
MAC_SIGN_EXPLICIT=false
APNS_KEY_PATH=""
REGENERATE_XCODEPROJ=false

BEGIN_MARKER="// BEGIN CHROMASCAN MANAGED SIGNING"
END_MARKER="// END CHROMASCAN MANAGED SIGNING"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-signing.sh [options]

Generates or updates gitignored Config/Local.xcconfig so you can sign ChromaScan,
ChromaScanRemote, and ChromaScanWidgets with your own Apple Developer account
without editing tracked files.

Options:
  --team-id <TEAM_ID>        10-character Apple Team ID (certificate OU)
  --bundle-prefix <PREFIX>   Unique reverse-DNS prefix (e.g. com.yourname.chromascan)
  --enable-apns              Enable Push Notifications entitlement (requires paid Apple Developer account)
  --no-apns                  Disable Push Notifications entitlement (works with free Apple IDs)
  --mac-ad-hoc               Use ad-hoc signing ("-") for the macOS app instead of Apple Development
  --mac-apple-dev            Use "Apple Development" signing for the macOS app
  --apns-key <PATH>          Optional path to AuthKey_<KEYID>.p8 to install via setup-apns.sh
  --xcodegen                 Re-run 'xcodegen generate' after writing Config/Local.xcconfig
  -h, --help                 Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --bundle-prefix)
      BUNDLE_PREFIX="${2:-}"
      shift 2
      ;;
    --enable-apns)
      ENABLE_APNS="yes"
      shift
      ;;
    --no-apns)
      ENABLE_APNS="no"
      shift
      ;;
    --mac-ad-hoc)
      MAC_SIGN_IDENTITY="-"
      MAC_SIGN_EXPLICIT=true
      shift
      ;;
    --mac-apple-dev)
      MAC_SIGN_IDENTITY="Apple Development"
      MAC_SIGN_EXPLICIT=true
      shift
      ;;
    --apns-key)
      APNS_KEY_PATH="${2:-}"
      shift 2
      ;;
    --xcodegen)
      REGENERATE_XCODEPROJ=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Inspect valid Apple Development signing identities and read their real Team ID
# from each certificate's subject OU (NOT the Team Member ID in CN parentheses).
# Emits tab-separated lines: "<TEAM_ID>\t<IDENTITY_NAME>"
detect_apple_dev_teams() {
  if ! command -v security >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
    return 0
  fi

  local valid_hashes
  valid_hashes="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/"Apple Development:/ { print toupper($2) }' || true)"
  if [[ -z "$valid_hashes" ]]; then
    return 0
  fi

  local tmp_pem
  tmp_pem="$(mktemp -d)"
  trap 'rm -rf "$tmp_pem"' RETURN

  # Split all Apple Development certificates in Keychain into individual PEM files
  security find-certificate -a -c "Apple Development:" -p 2>/dev/null \
    | awk -v dir="$tmp_pem" '
      /-----BEGIN CERTIFICATE-----/ { idx++; out = sprintf("%s/cert-%d.pem", dir, idx) }
      out { print > out }
      /-----END CERTIFICATE-----/ { close(out); out = "" }
    ' || true

  local cert_file sha1 subject team_ou cn
  for cert_file in "$tmp_pem"/cert-*.pem; do
    [[ -f "$cert_file" ]] || continue
    sha1="$(openssl x509 -in "$cert_file" -noout -fingerprint -sha1 2>/dev/null \
      | sed -E 's/^.*=//; s/://g' | tr '[:lower:]' '[:upper:]' || true)"
    if [[ -z "$sha1" ]] || ! printf '%s\n' "$valid_hashes" | grep -qx "$sha1"; then
      continue
    fi
    subject="$(openssl x509 -in "$cert_file" -noout -subject -nameopt RFC2253 2>/dev/null || true)"
    team_ou="$(printf '%s\n' "$subject" | sed -nE 's/.*(,|^|subject=)OU=([A-Za-z0-9]{10})(,|$).*/\2/p' | tr '[:lower:]' '[:upper:]' || true)"
    cn="$(printf '%s\n' "$subject" | sed -nE 's/.*(,|^|subject=)CN=([^,]+)(,|$).*/\2/p' || true)"
    if [[ -n "$team_ou" ]]; then
      printf '%s\t%s\n' "$team_ou" "${cn:-Apple Development}"
    fi
  done | sort -u
}

EXISTING_TEAM=""
EXISTING_PREFIX=""
EXISTING_MAC_SIGN=""
EXISTING_APNS="no"
if [[ -f "$LOCAL_XCCONFIG" ]]; then
  EXISTING_TEAM="$(sed -nE 's/^[[:space:]]*CHROMASCAN_TEAM_ID[[:space:]]*=[[:space:]]*([^[:space:]\/#]+).*/\1/p' "$LOCAL_XCCONFIG" | tail -n 1 || true)"
  EXISTING_PREFIX="$(sed -nE 's/^[[:space:]]*CHROMASCAN_BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]\/#]+).*/\1/p' "$LOCAL_XCCONFIG" | tail -n 1 || true)"
  EXISTING_MAC_SIGN="$(sed -nE 's/^[[:space:]]*CHROMASCAN_MAC_CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*([^[:space:]](.*[^[:space:]])?)[[:space:]]*$/\1/p' "$LOCAL_XCCONFIG" | tail -n 1 || true)"
  if grep -qE '^[[:space:]]*CHROMASCAN_IOS_ENTITLEMENTS[[:space:]]*=[[:space:]]*Resources/ChromaScanRemote\.entitlements' "$LOCAL_XCCONFIG"; then
    EXISTING_APNS="yes"
  fi
fi

DETECTED_ENTRIES="$(detect_apple_dev_teams)"
UNIQUE_TEAMS="$(printf '%s\n' "$DETECTED_ENTRIES" | awk -F '\t' 'NF && $1 != "" { print $1 }' | sort -u || true)"
UNIQUE_TEAM_COUNT="$(printf '%s\n' "$UNIQUE_TEAMS" | awk 'NF { c++ } END { print c+0 }')"

if [[ -z "$TEAM_ID" ]]; then
  echo "Detected Apple Development signing certificates (Team ID from certificate OU):"
  if [[ -n "$DETECTED_ENTRIES" ]]; then
    while IFS=$'\t' read -r det_team det_cn; do
      [[ -n "$det_team" ]] || continue
      echo "  - $det_cn  (Team ID: $det_team)"
    done <<< "$DETECTED_ENTRIES"
  else
    echo "  (none found — sign in via Xcode -> Settings -> Accounts first if building for iOS)"
  fi
  echo ""

  DEFAULT_TEAM=""
  if [[ -n "$EXISTING_TEAM" ]]; then
    DEFAULT_TEAM="$EXISTING_TEAM"
  elif [[ "$UNIQUE_TEAM_COUNT" -eq 1 ]]; then
    DEFAULT_TEAM="$UNIQUE_TEAMS"
  fi

  if [[ -n "$DEFAULT_TEAM" ]]; then
    read -r -p "Apple Team ID [$DEFAULT_TEAM]: " INPUT_TEAM
    TEAM_ID="${INPUT_TEAM:-$DEFAULT_TEAM}"
  else
    if [[ "$UNIQUE_TEAM_COUNT" -gt 1 ]]; then
      echo "Multiple Apple Teams detected; enter the 10-character Team ID you want to use."
    fi
    read -r -p "Apple Team ID (10 characters, or leave blank for ad-hoc Mac-only): " TEAM_ID
  fi
fi

TEAM_ID="$(printf '%s' "$TEAM_ID" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Error: '$TEAM_ID' is not a valid 10-character alphanumeric Apple Team ID." >&2
  exit 1
fi

if [[ -z "$BUNDLE_PREFIX" ]]; then
  DEFAULT_USER="$(id -un | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  DEFAULT_PREFIX="${EXISTING_PREFIX:-com.${DEFAULT_USER:-example}.chromascan}"
  read -r -p "Unique Bundle ID prefix [$DEFAULT_PREFIX]: " INPUT_PREFIX
  BUNDLE_PREFIX="${INPUT_PREFIX:-$DEFAULT_PREFIX}"
fi
BUNDLE_PREFIX="$(printf '%s' "$BUNDLE_PREFIX" | tr -d '[:space:]')"
if [[ ! "$BUNDLE_PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "Error: '$BUNDLE_PREFIX' is not a valid reverse-DNS bundle ID prefix (e.g. com.yourname.chromascan)." >&2
  exit 1
fi

if [[ -z "$ENABLE_APNS" ]]; then
  DEFAULT_HINT="y/N"
  [[ "$EXISTING_APNS" == "yes" ]] && DEFAULT_HINT="Y/n"
  echo ""
  echo "APNs lock-screen push notifications require a PAID Apple Developer Program membership."
  echo "Free Apple IDs ('Personal Teams') must choose No here (local notifications & Live Activities still work)."
  read -r -p "Enable Push Notifications entitlement (aps-environment)? [$DEFAULT_HINT]: " INPUT_APNS
  INPUT_APNS_LOWER="$(printf '%s' "$INPUT_APNS" | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$INPUT_APNS_LOWER" ]]; then
    ENABLE_APNS="$EXISTING_APNS"
  elif [[ "$INPUT_APNS_LOWER" == "y" || "$INPUT_APNS_LOWER" == "yes" ]]; then
    ENABLE_APNS="yes"
  else
    ENABLE_APNS="no"
  fi
fi

if [[ "$MAC_SIGN_EXPLICIT" == false ]]; then
  if [[ -n "$EXISTING_MAC_SIGN" ]]; then
    MAC_SIGN_IDENTITY="$EXISTING_MAC_SIGN"
  elif [[ -n "$TEAM_ID" ]]; then
    MAC_SIGN_IDENTITY="Apple Development"
  else
    MAC_SIGN_IDENTITY="-"
  fi
fi

mkdir -p "$(dirname "$LOCAL_XCCONFIG")"

TMP_CFG="$(mktemp "$(dirname "$LOCAL_XCCONFIG")/.Local.xcconfig.XXXXXX")"
trap 'rm -f "$TMP_CFG"' EXIT

write_managed_block() {
  echo "$BEGIN_MARKER"
  echo "// Generated by scripts/setup-signing.sh (gitignored)."
  echo "CHROMASCAN_TEAM_ID = $TEAM_ID"
  echo "CHROMASCAN_BUNDLE_ID_PREFIX = $BUNDLE_PREFIX"
  echo "CHROMASCAN_MAC_CODE_SIGN_IDENTITY = $MAC_SIGN_IDENTITY"
  if [[ "$ENABLE_APNS" == "yes" ]]; then
    echo "CHROMASCAN_IOS_ENTITLEMENTS = Resources/ChromaScanRemote.entitlements"
  else
    echo "// Uncomment if you have a paid Apple Developer account for lock-screen APNs push:"
    echo "// CHROMASCAN_IOS_ENTITLEMENTS = Resources/ChromaScanRemote.entitlements"
  fi
  echo "$END_MARKER"
}

if [[ -f "$LOCAL_XCCONFIG" ]]; then
  if grep -Fq "$BEGIN_MARKER" "$LOCAL_XCCONFIG" && grep -Fq "$END_MARKER" "$LOCAL_XCCONFIG"; then
    # Replace only the managed block, preserving any user-added custom lines
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
      $0 == begin { in_block = 1; next }
      $0 == end   { in_block = 0; next }
      !in_block   { print }
    ' "$LOCAL_XCCONFIG" > "$TMP_CFG"
    if [[ -s "$TMP_CFG" ]]; then
      echo "" >> "$TMP_CFG"
    fi
    write_managed_block >> "$TMP_CFG"
  else
    # Preserve any custom lines outside the four managed keys
    grep -vE '^[[:space:]]*(// Generated by scripts/setup-signing\.sh|// Uncomment if you have a paid Apple Developer|// CHROMASCAN_IOS_ENTITLEMENTS|CHROMASCAN_(TEAM_ID|BUNDLE_ID_PREFIX|MAC_CODE_SIGN_IDENTITY|IOS_ENTITLEMENTS)[[:space:]]*=)' "$LOCAL_XCCONFIG" > "$TMP_CFG" || true
    if [[ -s "$TMP_CFG" ]]; then
      echo "" >> "$TMP_CFG"
    fi
    write_managed_block >> "$TMP_CFG"
  fi
else
  write_managed_block > "$TMP_CFG"
fi

mv "$TMP_CFG" "$LOCAL_XCCONFIG"
trap - EXIT

echo ""
echo "Wrote $LOCAL_XCCONFIG:"
echo "  Team ID:          ${TEAM_ID:-<none (ad-hoc)>}"
echo "  macOS Bundle:     ${BUNDLE_PREFIX}.app (signing: ${MAC_SIGN_IDENTITY})"
echo "  iOS Bundle:       ${BUNDLE_PREFIX}.remote"
echo "  Widgets Bundle:   ${BUNDLE_PREFIX}.remote.widgets"
echo "  iOS Push (APNs):  $( [[ "$ENABLE_APNS" == "yes" ]] && echo "enabled" || echo "disabled (local notifications only)" )"

if [[ "$REGENERATE_XCODEPROJ" == true ]]; then
  if command -v xcodegen >/dev/null 2>&1; then
    echo ""
    echo "Running xcodegen generate..."
    (cd "$REPO_ROOT" && xcodegen generate)
  else
    echo "xcodegen is not installed; skipping project regeneration (not required for Local.xcconfig changes)."
  fi
fi

if [[ -n "$APNS_KEY_PATH" ]]; then
  echo ""
  "$SCRIPT_DIR/setup-apns.sh" "$APNS_KEY_PATH" \
    ${TEAM_ID:+--team-id "$TEAM_ID"} \
    --bundle-id "${BUNDLE_PREFIX}.remote"
elif [[ "$ENABLE_APNS" == "yes" ]]; then
  echo ""
  echo "Next step for lock-screen push notifications:"
  echo "  1. Create (or reuse an existing) APNs .p8 key in Apple Developer -> Keys"
  echo "     (Note: Apple limits each team to 2 APNs keys; reusing an existing team APNs key works great.)"
  echo "  2. Install it via: ./scripts/setup-apns.sh ~/Downloads/AuthKey_<KEYID>.p8"
  echo "     or choose it in ChromaScan on your Mac -> iPhone Companion -> Configure APNs..."
fi

echo ""
echo "Open ChromaScan.xcodeproj in Xcode and build ChromaScan / ChromaScanRemote."
