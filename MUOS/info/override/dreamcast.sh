#!/bin/sh
# muOS launch override for the "dreamcast" folder - see sp-controls/launch.sh
exec "$(dirname "$0")/sp-controls/launch.sh" "$@"
