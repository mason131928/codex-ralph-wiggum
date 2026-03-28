#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE_PLUGIN_DIR="$ROOT_DIR/plugins/ralph"
TARGET_PLUGIN_DIR="$HOME/plugins/ralph"
MARKETPLACE_FILE="$HOME/.agents/plugins/marketplace.json"

[[ -d "$SOURCE_PLUGIN_DIR" ]] || {
  echo "Source plugin directory not found: $SOURCE_PLUGIN_DIR" >&2
  exit 1
}

mkdir -p "$HOME/plugins"
rm -rf "$TARGET_PLUGIN_DIR.tmp.$$"
mkdir -p "$TARGET_PLUGIN_DIR.tmp.$$"
cp -R "$SOURCE_PLUGIN_DIR"/. "$TARGET_PLUGIN_DIR.tmp.$$"/
rm -rf "$TARGET_PLUGIN_DIR"
mv "$TARGET_PLUGIN_DIR.tmp.$$" "$TARGET_PLUGIN_DIR"

mkdir -p "$(dirname "$MARKETPLACE_FILE")"

if [[ ! -f "$MARKETPLACE_FILE" ]]; then
  cat > "$MARKETPLACE_FILE" <<'EOF'
{
  "name": "local-plugins",
  "interface": {
    "displayName": "Local Plugins"
  },
  "plugins": []
}
EOF
fi

perl -MJSON::PP -e '
use strict;
use warnings;

my ($file) = @ARGV;
open my $fh, "<", $file or die "open: $!";
local $/;
my $json = <$fh>;
close $fh;

my $payload = decode_json($json);
$payload->{name} //= "local-plugins";
$payload->{interface} //= { displayName => "Local Plugins" };
$payload->{plugins} //= [];

my $entry = {
  name => "ralph",
  source => {
    source => "local",
    path => "./plugins/ralph"
  },
  policy => {
    installation => "AVAILABLE",
    authentication => "ON_INSTALL"
  },
  category => "Productivity"
};

my $updated = 0;
for my $plugin (@{$payload->{plugins}}) {
  next unless ref($plugin) eq "HASH";
  next unless ($plugin->{name} // "") eq "ralph";
  %{$plugin} = %{$entry};
  $updated = 1;
}

push @{$payload->{plugins}}, $entry unless $updated;

open my $out, ">", $file or die "write: $!";
print {$out} JSON::PP->new->ascii->pretty->canonical->encode($payload);
close $out;
' "$MARKETPLACE_FILE"

cat <<EOF
Installed Ralph to:
  $TARGET_PLUGIN_DIR

Updated marketplace:
  $MARKETPLACE_FILE

Next:
  1. Restart Codex if it is already open.
  2. In any workspace, use /ralph:start ...
EOF
