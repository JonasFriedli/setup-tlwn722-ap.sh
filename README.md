# 🛰️ TL-WN722N Access Point Setup for Kali Linux

This repository provides a **fully automated setup script** to enable **Access Point (AP) mode** for the **TP-Link TL-WN722N v2/v3** adapter on **Kali Linux**.
It installs and configures all required components — Realtek drivers, `hostapd`, `dnsmasq`, and NAT — to create a functional Wi-Fi hotspot that shares your Kali machine’s internet connection.

---

## ⚙️ Features

✅ Installs required packages (`hostapd`, `dnsmasq`, `dkms`, `iptables-persistent`, etc.)
✅ Ensures a working Realtek `8188eu` driver and blacklists incompatible ones
✅ Configures WPA2 AP via `hostapd`
✅ Sets up DHCP via `dnsmasq`
✅ Enables persistent IP forwarding and NAT for internet sharing
✅ Creates systemd services for automatic startup at boot

---

## 🧩 Configuration

Before running the script, you can edit these variables at the **top** of `setup-tlwn722-ap.sh`:

```bash
OUT_IF="eth0"               # outbound (internet) interface (default)
AP_IF="wlan0"               # Wi-Fi interface for AP
AP_SUBNET="192.168.50.0/24" # subnet for connected clients
AP_GW="192.168.50.1"        # gateway IP
AP_SSID="KaliHotspot"       # SSID name
AP_PSK="verysecretpass"     # WPA2 passphrase
AP_CHANNEL="6"              # Wi-Fi channel
```

> 💡 The default subnet `192.168.50.0/24` avoids conflicts with common LAN networks.

---

## 🚀 Usage

1. **Edit variables** (optional): open `setup-tlwn722-ap.sh` and change the values at the top.
2. **Run the script as root**:

   ```bash
   sudo bash setup-tlwn722-ap.sh
   ```
3. **Replug the adapter or reboot** if requested.
   The script installs systemd services that automatically assign IPs and start the AP.

Once done, connect a device to your new hotspot (`SSID: KaliHotspot`) and enjoy full internet access through Kali.

---

## 🧠 Useful Commands

### 🔍 Check interface & service status

```bash
ip a show wlan0
systemctl status hostapd
journalctl -u hostapd -b -n 200 --no-pager
```

### 📡 Verify DHCP and NAT

```bash
ss -lunp | grep -E ':(53|67)\b'
sysctl net.ipv4.ip_forward
iptables -t nat -L POSTROUTING -v -n
iptables -L FORWARD -v -n
```

### 🧾 Watch DHCP traffic (Ctrl+C to stop)

```bash
sudo tcpdump -ni wlan0 port 67 or port 68
```

### 🧰 Troubleshooting

If clients connect but have **no internet**:

1. Ensure `net.ipv4.ip_forward=1`
2. Verify `iptables` MASQUERADE rule exists for `$OUT_IF`
3. Check internet works on the host itself:

   ```bash
   ping -c3 8.8.8.8
   ```

---

## 🕵️‍♂️ Spoofing IPs (Advanced)

You can assign and route an arbitrary IP (for testing or spoofing) safely using a `/32` address:

```bash
# add the IP as a /32 (safe choice if not part of your LAN)
sudo ip addr add 62.2.252.10/32 dev wlan0

# ensure the kernel sends packets via wlan0 for that IP
sudo ip route add 62.2.252.10/32 dev wlan0

# verify
ip -4 addr show dev wlan0
ip route get 62.2.252.10
```

To remove later:

```bash
sudo ip addr del 62.2.252.10/32 dev wlan0
sudo ip route del 62.2.252.10/32 dev wlan0
```

---

## 🗂️ Files Created

| File                                                  | Purpose                       |
| ----------------------------------------------------- | ----------------------------- |
| `/etc/hostapd/hostapd.conf`                           | Hostapd configuration         |
| `/etc/dnsmasq.d/kaliap.conf`                          | DHCP/DNS settings for AP      |
| `/etc/systemd/system/wlan0-ap-ip.service`             | Assigns static IP to wlan0    |
| `/etc/systemd/system/hostapd.service.d/override.conf` | Simplified hostapd startup    |
| `/etc/sysctl.d/99-kaliap.conf`                        | Enables IP forwarding         |
| `/etc/modprobe.d/blacklist-rtl8xxxu.conf`             | Blacklists bad Realtek driver |

---

## 🧩 Troubleshooting Notes

* **Frequent disconnects / WPA handshake loops**
  → Ensure you’re using the out-of-tree `8188eu` driver (not `rtl8xxxu`).
  → Check via `lsmod | grep 8188eu`.

* **Clients get IP but no internet**
  → Confirm NAT rules and forwarding are active.
  → Make sure `dnsmasq` binds to the AP interface.

* **In VMs (e.g., VMware/VirtualBox)**
  → Some USB passthrough implementations can cause instability.
  If issues persist, test the adapter on bare metal.

---

## 🧾 License

**MIT License** — free to modify and redistribute.

> This project aims to make Realtek TL-WN722N setup painless on Kali Linux.
> Future updates may include capture/monitor helpers, advanced diagnostics, and AP testing utilities.
