#!/usr/bin/env sh
set -eu
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec ruby --disable-gems "$source_dir/scripts/manage-install.rb" uninstall "$@"
