#!/usr/bin/env bash
set -euo pipefail

# == CONFIG ==
IFACE="wlan0"
SSID="KaliHotspot"
PSK="verysecretpass"
SUBNET="10.10.0.0/24"
AP_IP="10.10.0.1"
DHCP_START="10.10.0.10"
DHCP_END="10.10.0.100"
UPLINK_IF="eth0"           # change if your VM uplink isn't eth0
# ==========

echo "==> Installing packages (may ask for apt) ..."
apt update
# try to install the Kali DKMS package if available; if not, install build stack
if apt-cache show realtek-rtl8188eus-dkms >/dev/null 2>&1; then
  apt install -y realtek-rtl8188eus-dkms hostapd dnsmasq iptables iptables-persistent \
                 build-essential dkms git bc linux-headers-$(uname -r)
else
  apt install -y build-essential dkms git bc hostapd dnsmasq iptables iptables-persistent \
                 linux-headers-$(uname -r)
fi

# 1) blacklist in-tree driver so the vendor driver can be used later
echo "blacklist rtl8xxxu" > /etc/modprobe.d/blacklist-rtl8xxxu.conf
update-initramfs -u || true

# 2) try to ensure 8188eu module is installed/available. Prefer distro package, fallback to repo.
echo "==> Installing/ensuring 8188eu driver via DKMS (package preferred)..."
if dpkg -l | grep -q realtek-rtl8188eus-dkms; then
  echo "realtek-rtl8188eus-dkms already installed via apt."
else
  if apt-cache show realtek-rtl8188eus-dkms >/dev/null 2>&1; then
    apt install -y realtek-rtl8188eus-dkms || true
  fi

  # if module still missing, try a maintained DKMS repo
  if ! modinfo 8188eu >/dev/null 2>&1; then
    echo "Falling back to quickreflex/rtl8188eus DKMS (or aircrack-ng) build..."
    rm -rf /tmp/rtl8188eus /usr/src/8188eu-*
    # try quickreflex first; fallback to aircrack-ng
    if git clone https://github.com/quickreflex/rtl8188eus /tmp/rtl8188eus 2>/dev/null; then
      cd /tmp/rtl8188eus
      if [ -f ./dkms-install.sh ]; then
        chmod +x ./dkms-install.sh
        ./dkms-install.sh
      else
        echo "No dkms-install.sh in quickreflex tree; attempting manual dkms install..."
        # try to use provided dkms files if they exist
        if [ -f dkms.conf ]; then
          PKGVER=$(sed -n 's/.*PACKAGE_VERSION *= *"\(.*\)".*/\1/p' dkms.conf || echo "1.0")
          rsync -a . /usr/src/8188eu-${PKGVER}
          dkms add -m 8188eu -v ${PKGVER} || true
          dkms build -m 8188eu -v ${PKGVER}
          dkms install -m 8188eu -v ${PKGVER}
        fi
      fi
    else
      # fallback to aircrack-ng repo (non-DKMS)
      git clone https://github.com/aircrack-ng/rtl8188eus /tmp/rtl8188eus || true
      if [ -d /tmp/rtl8188eus ]; then
        cd /tmp/rtl8188eus
        make clean || true
        make || true
        make install || true
      fi
    fi
  fi
fi

# 3) ensure the in-tree driver is not loaded now, try to load 8188eu
echo "==> Unloading in-tree rtl8xxxu (if present) and loading 8188eu..."
modprobe -r rtl8xxxu 2>/dev/null || true
# try to load 8188eu (may succeed if DKMS installed)
if ! modprobe 8188eu 2>/dev/null; then
  echo "modprobe 8188eu failed — continuing anyway (maybe already loaded or build failed)."
fi

sleep 1
echo "Loaded modules (filtering 8188eu/8xxxu):"
lsmod | egrep '8188eu|8xxxu' || true

# 4) verify AP capability
echo "==> Checking iface & capabilities..."
ip link || true
if ! command -v iw >/dev/null 2>&1; then
  apt install -y iw
fi
if iw list | grep -q "Supported interface modes:"; then
  iw list | sed -n '/Supported interface modes:/,/Band/p'
else
  echo "WARNING: 'iw list' didn't print supported modes. You may not have AP support."
fi

# 5) Create hostapd config (nl80211)
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

# 6) Bring interface up with static AP IP
echo "==> Configuring interface ${IFACE}..."
ip link set ${IFACE} down 2>/dev/null || true
ip addr flush dev ${IFACE} 2>/dev/null || true
ip addr add ${AP_IP}/24 dev ${IFACE}
ip link set ${IFACE} up

# 7) Start hostapd (enable & start via systemd)
echo "==> Enabling and starting hostapd..."
systemctl disable --now hostapd.service 2>/dev/null || true
# ensure hostapd binary exists (install from apt earlier)
if ! command -v hostapd >/dev/null 2>&1; then
  echo "hostapd not found; aborting."
  exit 1
fi
# create a simple systemd unit drop-in to point hostapd to our conf
mkdir -p /etc/default
echo "DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"" > /etc/default/hostapd
systemctl enable --now hostapd

# wait briefly and show hostapd status
sleep 1
systemctl status hostapd --no-pager -l || true

# 8) dnsmasq config for DHCP on AP
echo "==> Configuring dnsmasq for DHCP on ${IFACE}..."
cat > /etc/dnsmasq.d/kali_ap.conf <<EOF
interface=${IFACE}
dhcp-range=${DHCP_START},${DHCP_END},12h
EOF
systemctl restart dnsmasq

# 9) Enable IPv4 forwarding and setup NAT
echo "==> Enabling IP forwarding and NAT (via ${UPLINK_IF})..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null; then
  sed -i '/^#net.ipv4.ip_forward/d' /etc/sysctl.conf || true
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi

iptables -t nat -A POSTROUTING -o ${UPLINK_IF} -j MASQUERADE || true
iptables -A FORWARD -i ${UPLINK_IF} -o ${IFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT || true
iptables -A FORWARD -i ${IFACE} -o ${UPLINK_IF} -j ACCEPT || true

# Save iptables to be persistent
netfilter-persistent save || true

echo "==> DONE. AP should be up as '${SSID}' on ${IFACE} with IP ${AP_IP}."
echo "Use: 'ip addr show ${IFACE}', 'sudo hostapd -dd /etc/hostapd/hostapd.conf' to debug."
