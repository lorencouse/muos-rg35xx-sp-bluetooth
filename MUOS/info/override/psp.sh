#!/bin/sh
# muOS launch override for the "psp" folder - see sp-controls/launch.sh
exec "$(dirname "$0")/sp-controls/launch.sh" "$@"
