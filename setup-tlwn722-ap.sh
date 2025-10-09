#!/usr/bin/env bash
# setup-tlwn722-ap.sh
# One-shot setup for TL-WN722N v2/v3 in AP mode on Kali Linux.
# Creates hostapd + dnsmasq configs, enables NAT + forwarding,
# and installs required packages & driver.

### === Configuration === ###
OUT_IF="eth0"               # outbound (internet) interface
AP_IF="wlan0"               # Wi-Fi interface for Access Point
AP_SUBNET="192.168.50.0/24" # internal AP subnet
AP_GW="192.168.50.1"        # gateway IP on AP interface
AP_SSID="KaliHotspot"       # network SSID
AP_PSK="verysecretpass"     # WPA2 passphrase
AP_CHANNEL="6"              # Wi-Fi channel
#############################

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root (sudo)." >&2
  exit 1
fi

echo "[+] Starting TL-WN722N AP setup..."
echo "    OUT_IF=$OUT_IF  AP_IF=$AP_IF  SUBNET=$AP_SUBNET"

# 1) Packages
apt update
apt install -y build-essential dkms git bc linux-headers-$(uname -r) \
               dnsmasq hostapd iptables-persistent netfilter-persistent

# 2) Drivers
echo "[+] Ensuring proper Realtek 8188eu driver"
echo "blacklist rtl8xxxu" >/etc/modprobe.d/blacklist-rtl8xxxu.conf
rmmod rtl8xxxu 2>/dev/null || true
modprobe 8188eu 2>/dev/null || true
lsmod | egrep '8188eu|rtl8xxxu' || true

# 3) Hostapd config
mkdir -p /etc/hostapd
cat >/etc/hostapd/hostapd.conf <<EOF
interface=${AP_IF}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=${AP_CHANNEL}
ieee80211n=1
wpa=2
wpa_passphrase=${AP_PSK}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# 4) Assign static IP service for AP_IF
cat >/etc/systemd/system/wlan0-ap-ip.service <<EOF
[Unit]
Description=Configure static IP for ${AP_IF}
After=network.target
ConditionPathExists=/sys/class/net/${AP_IF}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/bash -c 'for i in {1..10}; do [ -d /sys/class/net/${AP_IF} ] && exit 0; sleep 2; done; exit 1'
ExecStart=/bin/bash -c 'ip link set ${AP_IF} down || true; ip addr flush dev ${AP_IF}; ip addr add ${AP_GW}/24 dev ${AP_IF}; ip link set ${AP_IF} up; iw dev ${AP_IF} set power_save off || true'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wlan0-ap-ip.service || true

# 5) Hostapd systemd override
mkdir -p /etc/systemd/system/hostapd.service.d
cat >/etc/systemd/system/hostapd.service.d/override.conf <<'EOF'
[Service]
Type=simple
ExecStart=
ExecStart=/usr/sbin/hostapd -P /run/hostapd.pid /etc/hostapd/hostapd.conf
TimeoutStartSec=0
EOF

systemctl daemon-reload
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd || true

# 6) Dnsmasq DHCP config
cat >/etc/dnsmasq.d/kaliap.conf <<EOF
interface=${AP_IF}
bind-interfaces
dhcp-range=${AP_GW%.*}.10,${AP_GW%.*}.200,255.255.255.0,12h
dhcp-option=option:router,${AP_GW}
dhcp-option=option:dns-server,1.1.1.1,8.8.8.8
EOF

systemctl restart dnsmasq
systemctl enable dnsmasq

# 7) Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-kaliap.conf
sysctl --system >/dev/null || true

# 8) NAT + forwarding rules
iptables -t nat -C POSTROUTING -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -o "$OUT_IF" -j MASQUERADE

# add NAT for any other default routes too
while read -r via dev rest; do
  [ -n "$dev" ] && [ "$dev" != "$OUT_IF" ] && \
    iptables -t nat -C POSTROUTING -o "$dev" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$dev" -j MASQUERADE
done < <(ip route show default | awk '{print $2, $4}')

iptables -C FORWARD -i "$OUT_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$OUT_IF" -o "$AP_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -C FORWARD -i "$AP_IF" -o "$OUT_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$AP_IF" -o "$OUT_IF" -j ACCEPT

netfilter-persistent save

# 9) Start AP
systemctl restart wlan0-ap-ip.service
sleep 1
systemctl restart hostapd

echo
echo "[+] Setup complete."
ip a show "$AP_IF" | sed -n '1,5p'
echo
echo "[+] NAT rules:"
iptables -t nat -L POSTROUTING -v -n | grep MASQUERADE
echo
echo "[i] Connect to SSID '${AP_SSID}' (password: ${AP_PSK})"
echo "    and you should have internet access through ${OUT_IF}."
