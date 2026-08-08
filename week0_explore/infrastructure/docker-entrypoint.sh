#!/bin/sh
set -eu

LIB=/opt/circlemud/lib

if [ ! -e "$LIB/.initialized" ]; then
  cp -a /opt/circlemud/lib.dist/. "$LIB/"
  touch "$LIB/.initialized"
fi

# tbaMUD only recognizes existing characters it finds listed in
# plrfiles/index at boot; it never scans plrfiles/*/*.plr directly. If that
# one file is ever lost or truncated (seen in practice across container
# restarts on this host's bind mount) while .plr save files still exist,
# every real character looks "new" and logging in under an existing name
# overwrites the old save. Rebuild the index from the save files themselves
# so a lost index file can't cause data loss.
INDEX="$LIB/plrfiles/index"
if [ ! -s "$INDEX" ]; then
  plrs=$(find "$LIB/plrfiles" -mindepth 2 -maxdepth 2 -name '*.plr' 2>/dev/null || true)
  if [ -n "$plrs" ]; then
    echo "docker-entrypoint: $INDEX missing/empty but player files exist; rebuilding index" >&2
    tmp="$INDEX.rebuild.$$"
    : > "$tmp"
    echo "$plrs" | while IFS= read -r f; do
      awk '
        BEGIN { levl = 0; last = 0 }
        /^Name: / { name = tolower(substr($0, 7)) }
        /^Id  : / { id = substr($0, 7) }
        /^Levl: / { levl = substr($0, 7) }
        /^Last: / { last = substr($0, 7) }
        END { if (name != "" && id != "") printf "%s %s %s 0 %s\n", id, name, levl, last }
      ' "$f" >> "$tmp"
    done
    echo '~' >> "$tmp"
    mv "$tmp" "$INDEX"
  fi
fi

exec "$@"
