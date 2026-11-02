#!/bin/sh

case "$1" in on|off) ;; *) exit 1 ;; esac
# shellcheck source=/dev/null
. /lib/functions/gl_util.sh

fail() {
    logger -t gl-switch "GoodPAS: $*"
    exit 1
}

apply_action() {
    case "$action" in
        on) method=IPRB_secondary_start_connect ;;
        off) method=IPRB_secondary_pause_connect ;;
    esac
    logger -t gl-switch "GoodPAS $action: applying"
    response=$(ubus -t 90 call gl-session call \
        "{\"module\":\"mptun\",\"func\":\"$method\",\"params\":{}}") ||
        fail "$action: RPC transport failed"
    result_type='' error_type='' err_code='' err_msg=''
    json_load "$response" 2>/dev/null || fail "$action: Invalid RPC response"
    json_get_type result_type result
    case "$result_type" in object|array) ;; *) fail "$action: Missing RPC result" ;; esac
    json_get_type error_type error
    [ -z "$error_type" ] || fail "$action: RPC returned an error"
    json_select result
    json_get_var err_code err_code
    json_get_var err_msg err_msg
    if [ -n "$err_code" ] && [ "$err_code" != 0 ]; then
        fail "$action: RPC failed (code=$err_code): $err_msg"
    fi
    [ -z "$err_msg" ] || fail "$action: RPC business error: $err_msg"
    logger -t gl-switch "GoodPAS $action: applied"
}

# The caller holds gl-switch.lock. Events only wake this bounded reconciliation;
# the stable physical position, rather than the queued event, selects the RPC.
previous=
samples=0
changes=0
last_applied=
while [ "$samples" -lt 8 ]; do
    [ "$(uci -q get switch-button.@main[0].func)" = GoodPAS ] || exit 0
    sleep 1
    [ "$(uci -q get switch-button.@main[0].func)" = GoodPAS ] || exit 0
    action=$(get_switch_button_status)
    case "$action" in on|off) ;; *) fail "Cannot read physical switch" ;; esac
    samples=$((samples + 1))
    if [ "$action" != "$previous" ]; then
        previous=$action
        continue
    fi
    if [ "$(uci -q get mptun.global.service_mode)" != IPRB ] ||
        [ "$(uci -q get mptun.IPRB.identity)" != secondary ]; then
        fail "GoodPAS secondary is not configured"
    fi
    disabled=$(uci -q get mptun.IPRB.disabled)
    case "$disabled" in
        ''|0) applied=on ;;
        1) applied=off ;;
        *) fail "Invalid GoodPAS enabled state" ;;
    esac
    [ "$action" != "$applied" ] || exit 0
    [ "$changes" -lt 2 ] || fail "Switch did not converge; stopping"
    [ "$action" != "$last_applied" ] || fail "$action: RPC did not persist requested state"
    apply_action
    last_applied=$action
    changes=$((changes + 1))
    previous=
done
fail "Switch did not stabilize; stopping"
