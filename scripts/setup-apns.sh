#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_XCCONFIG="$REPO_ROOT/Config/Local.xcconfig"
# Fixed path matching APNsLocalDirectoryConfig.appConfigDirectoryURL in the Mac app
# (Finder-launched macOS GUI apps do not inherit shell XDG_CONFIG_HOME).
DEFAULT_APNS_DIR="$HOME/.config/chromascan/apns"

KEY_PATH=""
KEY_ID=""
TEAM_ID=""
BUNDLE_ID=""
TARGET_DIR="$DEFAULT_APNS_DIR"

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-apns.sh <path-to-AuthKey_XXXXXXXXXX.p8> [options]

Installs an Apple APNs P-256 .p8 private key into ~/.config/chromascan/apns/ with
strict permissions (chmod 600) so ChromaScan can send lock-screen scan alerts and
Live Activity updates directly from your Mac to Apple's APNs servers without storing
keys in git.

Options:
  --key-id <KEY_ID>       10-character Key ID (auto-extracted from AuthKey_<KEYID>.p8)
  --team-id <TEAM_ID>     10-character Apple Team ID (auto-read from Config/Local.xcconfig)
  --bundle-id <BUNDLE_ID> iOS Companion Bundle ID (auto-read from Config/Local.xcconfig)
  --dir <DIR>             Destination directory (default: ~/.config/chromascan/apns)
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-id)
      KEY_ID="${2:-}"
      shift 2
      ;;
    --team-id)
      TEAM_ID="${2:-}"
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      shift 2
      ;;
    --dir)
      TARGET_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$KEY_PATH" ]]; then
        KEY_PATH="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$KEY_PATH" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
  echo "Error: APNs key file not found: $KEY_PATH" >&2
  exit 1
fi

if ! grep -q "BEGIN PRIVATE KEY" "$KEY_PATH"; then
  echo "Error: $KEY_PATH does not look like a PKCS#8 PEM private key (.p8)." >&2
  exit 1
fi

if command -v openssl >/dev/null 2>&1; then
  KEY_TEXT="$(openssl pkey -in "$KEY_PATH" -text -noout 2>/dev/null || true)"
  if [[ -z "$KEY_TEXT" ]]; then
    echo "Error: openssl failed to parse $KEY_PATH as a valid private key." >&2
    exit 1
  fi
  if ! printf '%s\n' "$KEY_TEXT" | grep -qE 'ASN1 OID:[[:space:]]*prime256v1|NIST CURVE:[[:space:]]*P-256'; then
    echo "Error: $KEY_PATH is not an EC P-256 (prime256v1) private key required by APNs." >&2
    exit 1
  fi
fi

KEY_BASENAME="$(basename "$KEY_PATH")"
FILENAME_KEY_ID=""
if [[ "$KEY_BASENAME" =~ ^AuthKey_([A-Za-z0-9]{10})(\.p8)?$ ]]; then
  FILENAME_KEY_ID="${BASH_REMATCH[1]}"
fi

KEY_ID="$(printf '%s' "$KEY_ID" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
if [[ -n "$KEY_ID" ]]; then
  if [[ ! "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Error: --key-id '$KEY_ID' must be a 10-character alphanumeric Apple Key ID." >&2
    exit 1
  fi
  if [[ -n "$FILENAME_KEY_ID" && "$(printf '%s' "$FILENAME_KEY_ID" | tr '[:lower:]' '[:upper:]')" != "$KEY_ID" ]]; then
    echo "Error: --key-id '$KEY_ID' conflicts with filename Key ID '$FILENAME_KEY_ID' ($KEY_BASENAME)." >&2
    exit 1
  fi
elif [[ -n "$FILENAME_KEY_ID" ]]; then
  KEY_ID="$(printf '%s' "$FILENAME_KEY_ID" | tr '[:lower:]' '[:upper:]')"
fi

# Auto-read Team ID and Bundle ID prefix from Config/Local.xcconfig if present
if [[ -f "$LOCAL_XCCONFIG" ]]; then
  if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID="$(sed -nE 's/^[[:space:]]*CHROMASCAN_TEAM_ID[[:space:]]*=[[:space:]]*([^[:space:]\/#]+).*/\1/p' "$LOCAL_XCCONFIG" | tail -n 1 || true)"
  fi
  if [[ -z "$BUNDLE_ID" ]]; then
    PREFIX="$(sed -nE 's/^[[:space:]]*CHROMASCAN_BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]\/#]+).*/\1/p' "$LOCAL_XCCONFIG" | tail -n 1 || true)"
    if [[ -n "$PREFIX" ]]; then
      BUNDLE_ID="${PREFIX}.remote"
    fi
  fi
fi

TEAM_ID="$(printf '%s' "$TEAM_ID" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "Error: --team-id '$TEAM_ID' must be a 10-character alphanumeric Apple Team ID." >&2
  exit 1
fi

# Use a canonical .p8 filename so discovery always finds and matches it cleanly
if [[ -n "$KEY_ID" ]]; then
  CANONICAL_KEY_FILENAME="AuthKey_${KEY_ID}.p8"
else
  STEM="${KEY_BASENAME%.*}"
  CANONICAL_KEY_FILENAME="${STEM:-apns-key}.p8"
fi

mkdir -p "$TARGET_DIR"
chmod 700 "$TARGET_DIR"

SRC_DIR_REAL="$(cd "$(dirname "$KEY_PATH")" && pwd -P)"
DEST_DIR_REAL="$(cd "$TARGET_DIR" && pwd -P)"
SRC_REAL="$SRC_DIR_REAL/$KEY_BASENAME"
DEST_KEY="$DEST_DIR_REAL/$CANONICAL_KEY_FILENAME"

# Stage key safely (avoiding copying a file onto itself)
if [[ "$SRC_REAL" != "$DEST_KEY" ]]; then
  TMP_KEY="$(mktemp "$DEST_DIR_REAL/.AuthKey.XXXXXX")"
  trap 'rm -f "$TMP_KEY"' EXIT
  cp "$KEY_PATH" "$TMP_KEY"
  chmod 600 "$TMP_KEY"
  mv -f "$TMP_KEY" "$DEST_KEY"
  trap - EXIT
else
  chmod 600 "$DEST_KEY"
fi

# Atomically publish apns.env referencing the exact installed key file and Key ID
ENV_FILE="$DEST_DIR_REAL/apns.env"
TMP_ENV="$(mktemp "$DEST_DIR_REAL/.apns.env.XXXXXX")"
trap 'rm -f "$TMP_ENV"' EXIT
{
  echo "# ChromaScan local APNs configuration (outside git)"
  echo "APNS_KEY_FILE=$CANONICAL_KEY_FILENAME"
  if [[ -n "$KEY_ID" ]]; then
    echo "APNS_KEY_ID=$KEY_ID"
  fi
  if [[ -n "$TEAM_ID" ]]; then
    echo "APNS_TEAM_ID=$TEAM_ID"
  fi
  if [[ -n "$BUNDLE_ID" ]]; then
    echo "APNS_BUNDLE_ID=$BUNDLE_ID"
  fi
} > "$TMP_ENV"
chmod 600 "$TMP_ENV"
mv -f "$TMP_ENV" "$ENV_FILE"
trap - EXIT

echo "Installed APNs key to $DEST_KEY (chmod 600)"
echo "Wrote $ENV_FILE (chmod 600):"
echo "  Key File:  $CANONICAL_KEY_FILENAME"
echo "  Key ID:    ${KEY_ID:-<enter in UI or set APNS_KEY_ID>}"
echo "  Team ID:   ${TEAM_ID:-<auto-detected from signed build / paired iPhone>}"
echo "  Bundle ID: ${BUNDLE_ID:-<auto-detected from paired iPhone>}"

DEFAULT_REAL="$([[ -d "$DEFAULT_APNS_DIR" ]] && (cd "$DEFAULT_APNS_DIR" && pwd -P) || echo "$DEFAULT_APNS_DIR")"
LEGACY_REAL="$([[ -d "$HOME/.apns" ]] && (cd "$HOME/.apns" && pwd -P) || echo "$HOME/.apns")"
if [[ "$DEST_DIR_REAL" != "$DEFAULT_REAL" && "$DEST_DIR_REAL" != "$LEGACY_REAL" ]]; then
  echo ""
  echo "Note: ChromaScan auto-discovers keys from ~/.config/chromascan/apns/ (and legacy ~/.apns/)."
  echo "Because --dir was set to a custom path, select $DEST_KEY in ChromaScan -> Configure APNs... or install to the default path."
fi

echo ""
echo "Launch ChromaScan on your Mac, open iPhone Companion, and click 'Send Test Push' to verify."
