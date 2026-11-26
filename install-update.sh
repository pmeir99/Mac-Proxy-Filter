#!/bin/bash
set -eu
fresh=$1
app=$2
pid=$3
while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
backup="$fresh.previous"
mv "$app" "$backup"
if mv "$fresh" "$app" && /usr/bin/open "$app"; then
    rm -rf "$backup"
else
    if [[ -e "$app" ]]; then mv "$app" "$fresh"; fi
    mv "$backup" "$app"
    /usr/bin/open "$app"
fi
