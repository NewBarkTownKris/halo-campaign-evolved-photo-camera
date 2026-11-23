#!/bin/sh
package_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
python="$package_dir/.venv/bin/python"
if [ ! -x "$python" ]; then
    python=python3
fi
exec "$python" -B "$package_dir/tools/develop_photos.py" "$@"
