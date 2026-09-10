#!/bin/bash
# gtm-watcher.sh — poor-man's GTM health monitor for the PDC/SDC failover drill.
# Polls every PDC port on 127.0.0.2 in parallel; PDC counts as "up" if ANY port
# answers. After FAIL_THRESHOLD consecutive down checks it flips the GTM
# hostname in /etc/hosts to SDC (127.0.0.3); after RECOVER_THRESHOLD consecutive
# up checks it fails back to PDC automatically.

set -u

PDC_IP="127.0.0.2"
SDC_IP="127.0.0.3"
PDC_PORTS=(9091 9092 9093 9094 9095 9096 9097 9098 9099)
GTM_HOST="cbgm-kafka-id.myorg.com"
HOSTS_FILE="/etc/hosts"
CHECK_INTERVAL=3
FAIL_THRESHOLD=3
RECOVER_THRESHOLD=3
LOG_FILE="/tmp/gtm-watcher.log"
PID_FILE="/tmp/gtm-watcher.pid"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"
}

pdc_is_up() {
    local port tmpdir
    tmpdir=$(mktemp -d)
    for port in "${PDC_PORTS[@]}"; do
        ( timeout 1 bash -c "cat < /dev/null > /dev/tcp/${PDC_IP}/${port}" 2>/dev/null && touch "${tmpdir}/${port}" ) &
    done
    wait
    local found=1
    [[ -n "$(ls -A "${tmpdir}" 2>/dev/null)" ]] && found=0
    rm -rf "${tmpdir}"
    return ${found}
}

current_target() {
    grep -E "^[0-9.]+[[:space:]]+${GTM_HOST}" "${HOSTS_FILE}" | awk '{print $1}'
}

flip_to() {
    local new_ip=$1
    sed -i -E "s#^[0-9.]+([[:space:]]+${GTM_HOST}.*)#${new_ip}\1#" "${HOSTS_FILE}"
}

watch_loop() {
    local down_count=0 up_count=0
    log "gtm-watcher started (pid $$). PDC=${PDC_IP} SDC=${SDC_IP} host=${GTM_HOST} interval=${CHECK_INTERVAL}s fail_threshold=${FAIL_THRESHOLD} recover_threshold=${RECOVER_THRESHOLD}"
    log "Current GTM target: $(current_target)"
    while true; do
        if pdc_is_up; then
            up_count=$((up_count+1)); down_count=0
            if [[ "$(current_target)" == "${SDC_IP}" && ${up_count} -ge ${RECOVER_THRESHOLD} ]]; then
                flip_to "${PDC_IP}"
                log "PDC healthy for ${up_count} consecutive checks -> FAILBACK: ${GTM_HOST} now -> ${PDC_IP}"
                up_count=0
            fi
        else
            down_count=$((down_count+1)); up_count=0
            if [[ "$(current_target)" == "${PDC_IP}" && ${down_count} -ge ${FAIL_THRESHOLD} ]]; then
                flip_to "${SDC_IP}"
                log "PDC unreachable for ${down_count} consecutive checks -> FAILOVER: ${GTM_HOST} now -> ${SDC_IP}"
                down_count=0
            fi
        fi
        sleep "${CHECK_INTERVAL}"
    done
}

case "${1:-start}" in
  __run_loop__)
    watch_loop
    ;;
  start)
    if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null; then
        echo "gtm-watcher already running (PID=$(cat "${PID_FILE}"))"
        exit 0
    fi
    if [[ ${EUID} -ne 0 ]]; then
        echo "This must run as root (it edits ${HOSTS_FILE}). Re-run with sudo." >&2
        exit 1
    fi
    nohup "$0" __run_loop__ >> "${LOG_FILE}" 2>&1 &
    echo $! > "${PID_FILE}"
    echo "gtm-watcher started, PID=$(cat "${PID_FILE}"), log=${LOG_FILE}"
    ;;
  stop)
    if [[ -f "${PID_FILE}" ]] && kill "$(cat "${PID_FILE}")" 2>/dev/null; then
        echo "Stopped gtm-watcher (PID=$(cat "${PID_FILE}"))"
        rm -f "${PID_FILE}"
    else
        echo "gtm-watcher not running"
        rm -f "${PID_FILE}"
    fi
    ;;
  status)
    if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null; then
        echo "gtm-watcher running (PID=$(cat "${PID_FILE}"))"
        echo "Current GTM target: $(current_target)"
        echo "--- last 10 log lines ---"
        tail -10 "${LOG_FILE}" 2>/dev/null
    else
        echo "gtm-watcher not running"
    fi
    ;;
  *)
    echo "Usage: sudo $0 {start|stop|status}"
esac
