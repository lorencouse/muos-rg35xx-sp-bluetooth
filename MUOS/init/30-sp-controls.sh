#!/bin/sh
# muOS user-init hook: SP control pack.
#
# 1. Make muOS's launch overrides work. launch.sh looks for them in
#    /opt/muos/share/info/override, which does not exist on the 2601 rootfs,
#    while the card's MUOS/info/override is bound at
#    /run/muos/storage/info/override. Bind the latter over the former.
# 2. Controller defaults for the stick-less SP (RetroArch per-core options,
#    on the rootfs, so re-applied every boot):
#    - Mupen64Plus-Next "Independent C-button Controls": B=A Y=B A=C-Down
#      X=C-Up L1/R1=C-Left/Right L2=Z R2=R SELECT=L, instead of holding R2
#      to reach the C-buttons.
#    - PCSX-ReARMed pad type "analog" so the D-pad-as-stick mode moves the
#      character in analog games instead of being ignored.

. /opt/muos/script/var/func.sh

LOG="$(GET_VAR "device" "storage/rom/mount")/MUOS/log/controls.log"
mkdir -p "$(dirname "$LOG")"
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG")" -gt 400 ]; then
	tail -n 300 "$LOG" >"$LOG.tmp" && mv -f "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') sp-controls init ==="

SRC="$MUOS_STORE_DIR/info/override"
DST="$MUOS_SHARE_DIR/info/override"
if grep -qs " $DST " /proc/mounts; then
	echo "override bind already present"
elif [ -d "$DST" ] && [ -n "$(ls -A "$DST" 2>/dev/null)" ]; then
	echo "rootfs $DST exists and is not empty - leaving it alone (newer muOS?)"
elif [ -d "$SRC" ]; then
	mkdir -p "$DST"
	if mount --bind "$SRC" "$DST"; then
		echo "bound $SRC -> $DST ($(ls "$SRC" | grep -c '\.sh$') override scripts)"
	else
		echo "FAILED to bind $SRC -> $DST"
	fi
else
	echo "no $SRC on the card; nothing to bind"
fi

# key = "value" in a RetroArch per-core .opt file (create the file if needed)
SET_OPT() {
	F="$1"; K="$2"; V="$3"
	mkdir -p "$(dirname "$F")"
	if grep -q "^$K = " "$F" 2>/dev/null; then
		grep -q "^$K = \"$V\"$" "$F" || {
			sed -i "s|^$K = .*|$K = \"$V\"|" "$F" && echo "set $K=$V in ${F##*/}"
		}
	else
		printf '%s = "%s"\n' "$K" "$V" >>"$F" && echo "added $K=$V to ${F##*/}"
	fi
}
CFG="$MUOS_SHARE_DIR/info/config"
SET_OPT "$CFG/Mupen64Plus-Next/Mupen64Plus-Next.opt" "mupen64plus-alt-map" "True"
SET_OPT "$CFG/PCSX-ReARMed/PCSX-ReARMed.opt" "pcsx_rearmed_pad1type" "analog"

echo "=== done ==="
exit 0
