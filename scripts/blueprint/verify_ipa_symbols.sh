#!/usr/bin/env bash
# MASTER_HANDOVER_BLUEPRINT.md checklist test 6: the shipped IPA must contain the code paths the
# workflow depends on. Looks in the Mach-O symbol table, Swift reflection metadata and string
# literals, so it works on an unstripped Release build.
#
# Usage: scripts/blueprint/verify_ipa_symbols.sh path/to/OpenVision.ipa
set -euo pipefail

IPA="${1:?usage: $0 path/to/OpenVision.ipa}"
REQUIRED=(
  RecentPhotoScanner      # lesson 6: temple-shutter photos from Camera Roll
  cleanSpokenAudio        # lesson 5: LaTeX-free speech
  conversationHistory     # lesson 7: follow-up context
  PhotoPayload            # full-resolution glasses photos
  streamGenerateContent   # streamed answers (no idle timeouts)
  SolverIntent            # free-form routing / stop words
)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unzip -q "$IPA" -d "$work"
binary="$(find "$work/Payload" -maxdepth 2 -type f -name OpenVision | head -n 1)"
if [ -z "$binary" ]; then
  echo "::error::OpenVision binary not found inside $IPA"
  exit 1
fi

haystack="$work/haystack.txt"
{ nm -a "$binary" 2>/dev/null || true; strings -a "$binary"; } > "$haystack"

missing=0
for symbol in "${REQUIRED[@]}"; do
  if grep -q "$symbol" "$haystack"; then
    echo "✓ $symbol"
  else
    echo "::error::$symbol not found in the IPA binary"
    missing=1
  fi
done
size=$(wc -c < "$binary" | tr -d ' ')
echo "Binary: $(basename "$binary") ($((size / 1024 / 1024)) MB)"
exit "$missing"
