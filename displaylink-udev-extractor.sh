#!/bin/bash
file=$1

# Get systemd_start_stop_functions()
startline=$(grep -n "systemd_start_stop_functions()" "$file" | cut -d: -f1 | head -1)
endline=$(grep -n "displaylink_bootstrapper_code()" "$file" | cut -d: -f1 | head -1)

source <(
	tail -n +$startline $file | head -n +$(($endline - $startline - 1))
)

# Get displaylink_bootstrapper_code()
startline=$(grep -n "displaylink_bootstrapper_code()" "$file" | cut -d: -f1 | head -1)
endline=$(grep -n "chmod 0744 \"\$filename\"" "$file" | cut -d: -f1 | head -1)

source <(
	tail -n +$startline $file | head -n +$(($endline - $startline + 2))
)

COREDIR=$(mktemp -d)
create_bootstrap_file "systemd" "$COREDIR/udev.sh"

sed -i -e '1 s/^.*$/\#!\/usr\/bin\/bash/' "$COREDIR/udev.sh"
sed -i -e 's/systemctl start displaylink-driver/systemctl start displaylink-driver --no-block/g' "$COREDIR/udev.sh"

# The upstream script uses 'return 0' inside the top-level case statement.
# When udev runs the script as a standalone command (not sourced), 'return'
# outside a function fails with exit code 2. Replace top-level returns with
# exit so the script works correctly when invoked by udev.
awk '
BEGIN { depth = 0 }
/^[a-zA-Z_][a-zA-Z_0-9]*\(\)/ { infunc = 1 }
infunc && /^\{/ { depth++ }
infunc && /^\}/ { depth--; if (depth == 0) infunc = 0 }
!infunc && /^[[:space:]]*return[[:space:]]*[0-9]*[[:space:]]*$/ {
    sub(/return/, "exit")
}
{ print }
' "$COREDIR/udev.sh" > "$COREDIR/udev.sh.tmp" && mv "$COREDIR/udev.sh.tmp" "$COREDIR/udev.sh"

# Patch stop_service(): do not stop the daemon during the suspend/resume window.
# The sleep hook writes /run/displaylink-suspending on pre-suspend and removes
# it after resume. On platforms where the xHCI controller reinitialises on wake
# (e.g. Apple Silicon), the USB dock momentarily disconnects and fires a udev
# remove event that would otherwise kill DisplayLinkManager; this guard prevents
# that. The service is restarted by the sleep hook's background job instead.
awk '
/^stop_service\(\)$/ {
    print
    print "{"
    print "  # Do not stop the service during the suspend/resume window."
    print "  # /run/displaylink-suspending is written by the systemd-sleep hook"
    print "  # on pre-suspend and removed on post-resume. While it exists, USB"
    print "  # disconnect events (e.g. from xHCI reinit on Apple Silicon) are"
    print "  # transient and should not cause the daemon to be stopped."
    print "  if [ -f /run/displaylink-suspending ]; then"
    print "    return 0"
    print "  fi"
    # skip the original function body up to and including the closing brace
    do { getline } while ($0 != "}")
    print "  systemctl stop displaylink-driver"
    print "}"
    next
}
{ print }
' "$COREDIR/udev.sh" > "$COREDIR/udev.sh.tmp" && mv "$COREDIR/udev.sh.tmp" "$COREDIR/udev.sh"

cat "$COREDIR/udev.sh"

rm -rf "$COREDIR"
