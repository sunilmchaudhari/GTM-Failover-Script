#!/bin/bash
# Restarts the log-shipping agent when every PDC broker refuses connections.
BROKERS=(pdc-broker1:9092 pdc-broker2:9092 pdc-broker3:9092)
AGENT_SVC="elastic-agent-otel"
CHECK_INTERVAL=5

while true; do
  refused=0
  for b in "${BROKERS[@]}"; do
    err=$(timeout 2 bash -c "echo >/dev/tcp/${b%:*}/${b#*:}" 2>&1)
    [[ "$err" == *refused* ]] && ((refused++))
  done
  (( refused == ${#BROKERS[@]} )) && systemctl restart "$AGENT_SVC"
  sleep "$CHECK_INTERVAL"
done
