#!/bin/sh
# 10-custom-routes — маршруты YouTube в WireGuard (github.com/diablo-adg/wive-wireguard-autoconf)
#   без аргументов — вызывается прошивкой при поднятии wgcli0: ждёт интерфейс (до 120 с), берёт свежий список, ставит маршруты
#   refresh       — из cron (раз в 6 ч): если wgcli0 поднят — свежий список и только разница (новые добавить, ушедшие снять)
# Список (included_routes) собирается автоматически из geosite:youtube и публикуется в репозитории; копия в /pss —
# резерв на случай, если скачать не удалось (флеш при обновлении не пишется).

LOG="logger -t wireguard"

. /etc/scripts/global.sh

iface="wgcli0"
url="https://github.com/diablo-adg/wive-wireguard-autoconf/raw/main/included_routes"
saved="/pss/wg_client_included_routes"
fresh="/tmp/wg_client_included_routes"
applied="/tmp/wg_client_routes_applied"
self="/pss/wg-up.d/10-custom-routes"
crontab="/etc/crontabs/root"
min_routes=50

is_up() { ip link show "$iface" 2> /dev/null | grep -qE '[<,]UP[,>]'; }

$LOG "WireGuard custom routes: started${1:+ ($1)}"

if [ "$1" = "refresh" ]; then
  is_up || { $LOG "$iface is down, nothing to refresh"; exit 0; }
else
  $LOG "Waiting for $iface"
  n=0
  until is_up; do
    sleep 1; n=$((n + 1))
    [ "$n" -ge 120 ] && { $LOG "$iface is not up after 120 s, giving up"; exit 1; }
  done
  rm -f "$applied"                    # интерфейс только что поднялся — маршрутов на нём нет, ставим все
fi

# 1. свежий список (не скачался или подозрительно короткий — прошлый скачанный, иначе копия из /pss)
if wget -T 15 --no-check-certificate -qO "$fresh.new" "$url" &&
   [ "$(grep -cE '^([0-9]+\.){3}[0-9]+' "$fresh.new")" -ge "$min_routes" ]; then
  mv -f "$fresh.new" "$fresh"
  src="$fresh"
else
  rm -f "$fresh.new"
  $LOG "Failed to download a valid routes list, using the previous one"
  if [ -s "$fresh" ]; then src="$fresh"; else src="$saved"; fi
fi
[ -s "$src" ] || { $LOG "No routes list"; exit 1; }

want="/tmp/wg_client_routes_want"
dos2unix -u "$src" 2> /dev/null
grep -oE '^([0-9]+\.){3}[0-9]+(/[0-9]+)?' "$src" | sort -u > "$want"
touch "$applied"

# 2. новые маршруты — добавить, ушедшие из списка — снять
added=0; removed=0
for dest in $(grep -vxFf "$applied" "$want"); do
  ip -4 route replace "$dest" dev "$iface" metric "$wgmetric" && added=$((added + 1))
done
for dest in $(grep -vxFf "$want" "$applied"); do
  ip -4 route del "$dest" dev "$iface" 2> /dev/null && removed=$((removed + 1))
done
mv -f "$want" "$applied"
$LOG "Routes: added $added, removed $removed, total $(wc -l < "$applied")"

# 3. обновление списка раз в 6 ч: задание cron (файл заданий прошивка может пересоздать — ставим при каждом запуске)
if ! grep -qF "$self refresh" "$crontab" 2> /dev/null; then
  echo "41 */6 * * * $self refresh" >> "$crontab"
  $LOG "Cron job added"
  [ "$(nvram_get CrondEnable)" = "1" ] || nvram_set CrondEnable 1
  service crontab restart > /dev/null 2>&1
elif ! pidof crond > /dev/null; then
  [ "$(nvram_get CrondEnable)" = "1" ] || nvram_set CrondEnable 1
  service crontab restart > /dev/null 2>&1
fi

$LOG "WireGuard custom routes: finished"
