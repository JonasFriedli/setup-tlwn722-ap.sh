#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
IFACE="wlan0"
SSID="KaliHotspot"
PSK="verysecretpass"
AP_IP="10.10.0.1"
DHCP_START="10.10.0.10"
DHCP_END="10.10.0.100"
UPLINK_IF="eth0"     # change if your VM uplink isn't eth0
# ----------------------------------------

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo bash $0"
  exit 2
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Updating apt lists..."
apt-get update -y -qq

echo "==> Installing required packages..."
# prefer packaged DKMS if available, but install the rest either way
apt-get install -yq \
  build-essential dkms git bc hostapd dnsmasq iptables iptables-persistent netfilter-persistent \
  linux-headers-$(uname -r) || {
    echo "Warning: some packages failed to install; please check apt output"
}

# 1) blacklist in-tree driver for future boots
echo "blacklist rtl8xxxu" > /etc/modprobe.d/blacklist-rtl8xxxu.conf
update-initramfs -u || true

# 2) ensure 8188eu module is available: prefer distro DKMS package, fallback to source
if dpkg -s realtek-rtl8188eus-dkms >/dev/null 2>&1; then
  echo "realtek-rtl8188eus-dkms already installed"
else
  if apt-cache show realtek-rtl8188eus-dkms >/dev/null 2>&1; then
    echo "Installing realtek-rtl8188eus-dkms from repo..."
    apt-get install -yq realtek-rtl8188eus-dkms || true
  fi
fi

# fallback: try to build from a maintained repo if module not available
if ! modinfo 8188eu >/dev/null 2>&1; then
  echo "8188eu module not found; attempting DKMS/source fallback build..."
  rm -rf /tmp/rtl8188eus /usr/src/8188eu-*
  # try quickreflex (many users maintain forks); if that fails try aircrack-ng
  if git clone --depth 1 https://github.com/quickreflex/rtl8188eus /tmp/rtl8188eus 2>/dev/null; then
    cd /tmp/rtl8188eus
    if [ -f ./dkms-install.sh ]; then
      chmod +x ./dkms-install.sh
      ./dkms-install.sh || true
    elif [ -f dkms.conf ]; then
      PKGVER=$(sed -n 's/.*PACKAGE_VERSION *= *"\(.*\)".*/\1/p' dkms.conf || echo "1.0")
      rsync -a . /usr/src/8188eu-${PKGVER}
      dkms add -m 8188eu -v ${PKGVER} || true
      dkms build -m 8188eu -v ${PKGVER} || true
      dkms install -m 8188eu -v ${PKGVER} || true
    fi
  else
    echo "quickreflex clone failed; trying aircrack-ng repo..."
    git clone --depth 1 https://github.com/aircrack-ng/rtl8188eus /tmp/rtl8188eus || true
    if [ -d /tmp/rtl8188eus ]; then
      cd /tmp/rtl8188eus
      make clean || true
      make || true
      make install || true
    fi
  fi
fi

# 3) ensure kernel loads our module (and not rtl8xxxu)
modprobe -r rtl8xxxu 2>/dev/null || true
if ! modprobe 8188eu 2>/dev/null; then
  echo "Note: modprobe 8188eu returned non-zero (maybe already loaded or build failed)."
fi

sleep 1
echo "Loaded modules (8188eu/rtl8xxxu):"
lsmod | egrep '8188eu|8xxxu' || true

# 4) check interface exists and capabilities
if ! command -v iw >/dev/null 2>&1; then
  apt-get install -yq iw
fi

echo "==> iw list (Supported interface modes):"
iw list | sed -n '/Supported interface modes:/,/Band/p' || true

# 5) hostapd config (nl80211)
cat > /etc/hostapd/hostapd.conf <<EOF
interface=${IFACE}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_passphrase=${PSK}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF
chmod 600 /etc/hostapd/hostapd.conf

# ensure /etc/default/hostapd points to our config
mkdir -p /etc/default
echo "DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"" > /etc/default/hostapd

# 6) bring interface up with static AP IP
ip link set ${IFACE} down 2>/dev/null || true
ip addr flush dev ${IFACE} 2>/dev/null || true
ip addr add ${AP_IP}/24 dev ${IFACE}
ip link set ${IFACE} up

# 7) unmask + enable + start hostapd
echo "==> Unmasking and starting hostapd..."
systemctl unmask hostapd.service || true
systemctl daemon-reload || true
systemctl enable --now hostapd.service || {
  echo "systemctl enable/start hostapd failed; try: 'journalctl -u hostapd -n 200' to inspect errors"
}

# show recent hostapd logs for quick check
sleep 1
journalctl -u hostapd -n 80 --no-pager || true

# 8) dnsmasq DHCP config for wlan0
cat > /etc/dnsmasq.d/kali_ap.conf <<EOF
interface=${IFACE}
dhcp-range=${DHCP_START},${DHCP_END},12h
EOF
systemctl restart dnsmasq || true

# 9) enable IPv4 forwarding and NAT
sysctl -w net.ipv4.ip_forward=1 || true
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
  # remove commented line if present, then append
  sed -i '/^#net.ipv4.ip_forward/d' /etc/sysctl.conf || true
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

iptables -t nat -A POSTROUTING -o ${UPLINK_IF} -j MASQUERADE || true
iptables -A FORWARD -i ${UPLINK_IF} -o ${IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT || true
iptables -A FORWARD -i ${IFACE} -o ${UPLINK_IF} -j ACCEPT || true

# save iptables rules persistently
netfilter-persistent save || true

echo
echo "==> DONE."
echo "AP should be up: SSID='${SSID}', iface=${IFACE}, IP=${AP_IP}"
echo "If clients don't see the SSID, check: 'journalctl -u hostapd -n 200' and 'dmesg | tail -n 80'"
