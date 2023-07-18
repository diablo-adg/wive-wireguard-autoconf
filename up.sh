#!/bin/sh

LOG="logger -t wireguard"

. /etc/scripts/global.sh

iface="wgcli0"
included_routes="/pss/wg_client_included_routes"

$LOG "WireGuard custom routes script: started"

$LOG "Waiting for $iface"
until ip addr show $iface up; do sleep 1; done

$LOG "Adding routes"
if [ -s "$included_routes" ]; then
  dos2unix -u "$included_routes"
  filtered_included_routes="/tmp/$(basename $included_routes).$(date +%s)"
  grep -oE '^([0-9]+\.){3}[0-9]+(/[0-9]+)?' "$included_routes" > "$filtered_included_routes"

  while IFS= read -r dest; do
    [ -z "$dest" ] && continue
    $LOG -p debug "route replace $dest dev $iface metric $wgmetric"
    ip -4 route replace "$dest" dev "$iface" metric "$wgmetric"
  done < "$filtered_included_routes"

  $LOG "Added total $(wc -l $filtered_included_routes) routes"
  rm -f "$filtered_included_routes"
fi

$LOG "WireGuard custom routes script: finished"
