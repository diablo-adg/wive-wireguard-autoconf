#!/bin/sh

wg_config="/tmp/wg-client-autoconf"
fw_min_date="20220601"

wg_up_dir="/pss/wg-up.d"
repo="https://github.com/shvchk/wive-wireguard-autoconf"
raw_files_url="${repo}/raw/main"
custom_routes_script_path="${wg_up_dir}/10-custom-routes"
custom_routes_script_url="${raw_files_url}/up.sh"
included_routes_path="/pss/wg_client_included_routes"
included_routes_url="${raw_files_url}/included_routes"

ping_test_target="1.1.1.1"
dns_test_target="icanhazip.com"
ip_discovery_provider="$dns_test_target"

wget="wget -T 5 --no-check-certificate"
iface="wgcli0"

die() {
  echo "${1:-}"
  echo "Завершение работы"
  exit 1
}

yes_or_no() {
  echo
  while true; do
    read -p "$* [ введите + или - ]: " yn < /dev/tty || die "No tty"
    case "$yn" in
      "+") return 0 ;;
      "-") return 1 ;;
    esac
  done
}

# Dumb filter for IPv4 or FQDN addresses (has dot),
# since we don't support IPv6 yet
get_valid_addrs() {
  addrs="$(echo "$1" | sed 's/,/ /g')"
  for addr in $addrs; do
    if echo "$addr" | grep -q '\.'; then
      echo -n "$addr "
    fi
  done
}

is_fw_ok() {
  fw_date="$(cat /share/version | sed -nE '/^VERSIONPKG/{s/.*\.([0-9]{2})([0-9]{2})([0-9]{4})"$/\3\2\1/;p}')"
  [ "$fw_date" -gt "$fw_min_date" ]
}

parse_wg_config() {
  [ -s "$1" ] || die "Файл конфигурации WireGuard не найден"
  echo "Обработка файла конфигурации WireGuard"

  dos2unix -u "$1"
  local line key val err

  while read -r line || [ -n "$line" ]; do
    [ -z "$line" ] ||
    [ "${line:0:1}" = "#" ] && continue

    line="$(echo "$line" | sed 's/ //g')"
    key="$(echo "$line" | cut -d '=' -f 1)"
    val="$(echo "$line" | cut -d '=' -f 2-)"

    case "$key" in
      Address)
        [ -n "$Address" ] && continue
        Address="$(get_valid_addrs "$val" | cut -d ' ' -f 1)"
        ;;

      Endpoint)
        [ -n "$Endpoint" ] && continue
        Endpoint="$(get_valid_addrs "$val" | cut -d ' ' -f 1)"
        EndpointAddr="$(echo "$Endpoint" | cut -d ':' -f 1)"
        EndpointPort="$(echo "$Endpoint" | cut -d ':' -f 2)"
        ;;

      AllowedIPs)
        AllowedIPs="$AllowedIPs $(get_valid_addrs "$val")"
        ;;

      PrivateKey)
        PrivateKey="$val"
        ;;

      PublicKey)
        PublicKey="$val"
        ;;

      *)
        continue
        ;;
    esac
  done < "$1"

  AllowedIPs="$(echo "$AllowedIPs" | sed -E 's/^ +//;s/ +$//;s/ +/,/g')"

  err=""
  [ -z "$Address" ] && err="No valid client address in config file"
  [ -z "$Endpoint" ] && err="No valid server address in config file"
  [ -z "$AllowedIPs" ] && err="No valid allowed IPs in config file"
  [ -z "$PrivateKey" ] && err="No valid private key in config file"
  [ -z "$PublicKey" ] && err="No valid server public key in config file"
  [ -n "$err" ] && die "$err"
}

get_wg_config_from_user() {
  echo "Введите параметры подключения из файла конфигурации WireGuard:"
  echo
  read -rp '[Interface] Address: '     Address     < /dev/tty || die "No tty"
  read -rp '[Interface] PrivateKey: '  PrivateKey  < /dev/tty || die "No tty"
  read -rp '[Peer] Endpoint: '         Endpoint    < /dev/tty || die "No tty"
  read -rp '[Peer] PublicKey: '        PublicKey   < /dev/tty || die "No tty"
  read -rp '[Peer] AllowedIPs: '       AllowedIPs  < /dev/tty || die "No tty"

  EndpointAddr="$(echo "$Endpoint" | cut -d ':' -f 1)"
  EndpointPort="$(echo "$Endpoint" | cut -d ':' -f 2)"
}

configure_wg_client() {
  echo "$PrivateKey" > /pss/wg_cli_client_private_key
  echo "$PublicKey" > /pss/wg_cli_client_public_key
  fs saveps

  nvram_set wireguard_cli_netaddress "$Address"
  nvram_set wireguard_cli_endpoint "$EndpointAddr"
  nvram_set wireguard_cli_endpoint_port "$EndpointPort"
  nvram_set wireguard_cli_allowedips "$AllowedIPs"
}

check_wg_connection() {
  service wireguard stop
  oldIP="$($wget -qO- "$ip_discovery_provider")"
  echo "Внешний IP адрес до подключения: $oldIP"
  service wireguard start

  if ping -c 3 -W 1 "$ping_test_target"; then
    echo
    echo "Тестовый узел доступен"

    if nslookup "$dns_test_target"; then
      echo "DNS работает"
      newIP="$($wget -qO- "$ip_discovery_provider")"

      if [ "$oldIP" = "$newIP" ]; then
        echo "Внешний IP адрес не изменился!"
        echo "В некоторых случаях это нормально, но всё же имейте ввиду"
      else
        echo "Новый внешний IP адрес: $newIP"
        echo "Похоже, всё в порядке"
      fi
    else
      echo "Похоже, есть проблемы с DNS"
    fi
  else
    echo "Тестовый узел недоступен"
    echo "Это может свидетельствовать о некорректной настройке соединения или сервера"
  fi
}

setup_custom_routing() {
  mkdir "$wg_up_dir"
  $wget "$custom_routes_script_url" -qO "$custom_routes_script_path"
  $wget "$included_routes_url" -qO "$included_routes_path"
  chmod +x "$custom_routes_script_path"
  fs saveps

  if ip link show $iface &> /dev/null; then
    service wireguard restart
  fi

  echo
  echo "Рекомендуем добавить на роутере следующие локальные записи DNS:"
  echo
  cat "$included_routes_path" | sed -n '/# Hosts/,/# ---*/{/^#/d;s/#//;/^[0-9]/p}'
  echo
  echo "Сделать это можно по ссылке http://$(nvram_get lan_ipaddr)/#services/dns.asp"
  echo "или в разделе Сервисы > Службы DNS > Локальные записи DNS"
}

echo

if ! is_fw_ok; then
  echo "ПО роутера устарело"
  echo "Обновите его по ссылке http://$(nvram_get lan_ipaddr)/#adm/management.asp"
  echo "или в разделе Администрирование > Управление > Обновление ПО"
  die
fi

if [ -s "$wg_config" ] && [ "$1" != "-m" ]; then
  parse_wg_config "$wg_config"
else
  get_wg_config_from_user
fi

configure_wg_client

if yes_or_no "Настройка завершена, проверить соединение WireGuard?"; then

  check_wg_connection

  if yes_or_no "Оставить WireGuard включенным?"; then
    echo "В случае необходимости соединение можно выключить командой service wireguard stop"
  else
    service wireguard stop
    echo "Готово"
  fi
fi

if yes_or_no "Включить автозапуск WireGuard при включении роутера?"; then
  nvram_set wireguard_cli_enabled 1
  echo "В случае необходимости автозапуск можно отключить командой nvram_set wireguard_cli_enabled 0"
else
  nvram_set wireguard_cli_enabled 0
  echo "В случае необходимости автозапуск можно включить командой nvram_set wireguard_cli_enabled 1"
fi

if yes_or_no "Настроить выборочную маршрутизацию для обхода блокировок?"; then
  setup_custom_routing
  echo "Готово"
fi
