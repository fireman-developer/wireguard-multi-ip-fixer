# WireGuard & UDP Tunnel Symmetric Routing Fixer (`wg-sym-fixer`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20(Debian%2FUbuntu%2FRHEL%2FArch)-green.svg)]()
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)]()

[🇬🇧 English](#english-documentation) | [🇮🇷 توضیحات فارسی](#توضیحات-فارسی)

---

<a name="english-documentation"></a>
## 🇬🇧 English Documentation

## Installation
----

curl -fsSL https://raw.githubusercontent.com/fireman-developer/wireguard-multi-ip-fixer/main/wgmipfixer.sh -o wgmipfixer.sh && sudo bash wgmipfixer.sh

----
### Overview
When running **WireGuard** or low-level UDP tunnel forwarders (such as **Backpack**, **PasarGuard nodes**, **Sing-box**, or raw-socket relays) on a Linux server with multiple public IPv4 addresses, the tunnel process typically binds to wildcard `*:51820` (`0.0.0.0:51820`).

When a client sends a WireGuard Handshake Initiation packet to a **Secondary Public IP** (e.g., `IP_2:51820`), the Linux kernel routes the outgoing Handshake Response using the server's **Primary Default IP** (`IP_1:51820`). Because the source IP of the response does not match the destination IP the client contacted, the client drops the packet immediately, resulting in:
```text
io: read/write on closed pipe
```
Furthermore, many modern tunnel binaries use raw/low-level sockets that bypass standard `iptables` `conntrack`/`POSTROUTING` chains for locally generated UDP responses.

**`wg-sym-fixer`** solves this problem permanently and automatically with zero disruption to your existing firewall rules.

### Key Features
- **Full Hardware & Network Auto-Detection:** Automatically identifies the primary network interface, default gateway, preferred source IP, and all public IPv4 addresses attached to the server.
- **Non-Destructive & Isolated Firewall Rules:** Uses dedicated custom NAT chains (`WG_SYM_PRE` and `WG_SYM_POST`). It **never** flushes `PREROUTING` or `POSTROUTING`, keeping Docker, UFW, Xray, and other tunnel rules 100% intact.
- **Dual Operating Modes:**
  - **Option 1 (Single-IP Mode):** Locks the kernel default route `src` and applies isolated `SNAT` rules to guarantee symmetric outbound packets on a single target public IP.
  - **Option 2 (Multi-IP Active-Active Mode):** Handles the primary IP natively in the kernel and automatically spawns lightweight, timeout-managed (`-T 180`) `socat` UDP relays bound to each secondary IP so clients can connect to **all public IPs simultaneously**.
- **Safe Rollback (Option 3):** Backs up your original kernel routing and `sysctl` settings before making changes, allowing a 1-click clean restore that removes **only** the rules and services created by this script.
- **Reboot Persistence:** Automatically generates and enables a `systemd` service (`wg-sym-fixer.service`) so settings survive server reboots.

### Quick Start

Run directly or clone the repository:

```bash
git clone [https://github.com/YOUR_USERNAME/wg-sym-fixer.git](https://github.com/YOUR_USERNAME/wg-sym-fixer.git)
cd wg-sym-fixer
chmod +x wg-sym-fixer.sh
sudo ./wg-sym-fixer.sh
```

### Interactive Menu Options

```text
======================================================================
       WireGuard & UDP Tunnel Symmetric Routing Fixer (v1.0)          
======================================================================
  1) Server with 1 IP      (Optimize & Lock Outbound Source IP)
  2) Server with Multi-IP  (Active-Active Symmetric Routing for All IPs)
  3) Rollback & Restore    (Revert to previous state & remove ONLY script rules)
  0) Exit
======================================================================
```

### Verification
After applying Option `1` or `2`, verify symmetric packet flow in real time using `tcpdump`:

```bash
sudo tcpdump -ni eth0 udp port 51820
```
Both incoming (148 bytes) and outgoing (92 bytes) handshake packets will now carry the exact same server IP address.

---

<a name="توضیحات-فارسی"></a>
## 🇮🇷 توضیحات فارسی

## نصب 

----

curl -fsSL https://raw.githubusercontent.com/fireman-developer/wireguard-multi-ip-fixer/main/wgmipfixer.sh -o wgmipfixer.sh && sudo bash wgmipfixer.sh

----


### معرفی و بیان مشکل
هنگام راه‌اندازی **وایرگارد (WireGuard)** یا ابزارهای تانلینگ مبتنی بر UDP (مانند **Backpack**، نودهای **پاسارگارد**، **Sing-box** و غیره) روی سرورهای لینوکسی که بیش از یک آی‌پی پابلیک دارند (یا آی‌پی‌های آن‌ها جابه‌جا شده است)، برنامه تانل معمولاً روی `*:51820` (`0.0.0.0:51820`) گوش می‌دهد.

وقتی کاربر به **آی‌پی دوم (فرعی)** سرور وصل می‌شود، هسته لینوکس بستهٔ پاسخ (Handshake Response) را با **آی‌پی اول (اصلی)** سرور به سمت کاربر برمی‌گرداند. به دلیل عدم تطابق آی‌پی رفت و برگشت، کلاینت‌های وایرگارد (مانند v2rayN و v2rayNG) بستهٔ برگشتی را دراپ کرده و خطای زیر را نمایش می‌دهند:
```text
io: read/write on closed pipe
```
از طرفی، به دلیل ساختار سوکت در ابزارهایی مثل `backpack`، رول‌های معمولی `iptables SNAT` به تنهایی دور زده می‌شوند. اسکریپت **`wg-sym-fixer`** این مشکل را به صورت کاملاً خودکار، اصولی و دائمی برطرف می‌کند.

### ویژگی‌های کلیدی اسکریپت
- **شناسایی خودکار مشخصات شبکه:** تشخیص اتوماتیک نام کارت شبکه (`eth0`, `ens3` و...)، آدرس Gateway، لیست تمام آی‌پی‌های پابلیک IPv4 و پورت وایرگارد.
- **ایزوله‌سازی کامل فایروال (بدون حذف سایر رول‌های سرور):** این اسکریپت به هیچ عنوان زنجیره‌های `PREROUTING` یا `POSTROUTING` سرور شما را Flush نمی‌کند؛ بلکه دو زنجیره اختصاصی به نام‌های `WG_SYM_PRE` و `WG_SYM_POST` می‌سازد تا هیچ تداخلی با داکر یا سایر اسکریپت‌های تانل ایجاد نشود.
- **پشتیبانی از دو حالت تک‌آی‌پی و چندآی‌پی (Multi-IP):**
  - **گزینه ۱ (سرور دارای ۱ آی‌پی):** قفل کردن سورس روتینگ کرنل و زنجیره اختصاصی `SNAT` روی آی‌پی مدنظر بدون سربار اضافی.
  - **گزینه ۲ (سرور دارای چند آی‌پی - فعال‌سازی همزمان همه آی‌پی‌ها):** مسیردهی آی‌پی اول از طریق کرنل و راه‌اندازی خودکار رله‌های مقید (`socat` با تایم‌اوت هوشمند `-T 180` برای جلوگیری از مصرف رم) روی تمام آی‌پی‌های فرعی تا همهٔ آی‌پی‌ها به طور همزمان کار کنند.
- **بازگردانی ایمن به حالت قبل (گزینه ۳ - Rollback):** ذخیره خودکار وضعیت اولیه روتینگ و `rp_filter` قبل از اعمال تغییرات. با زدن گزینه ۳، **فقط و فقط** رول‌ها و سرویس ساخته شده توسط همین اسکریپت پاک شده و تنظیمات کرنل به حالت اولیه برمی‌گردد.
- **پایداری در ری‌استارت (Systemd Service):** ساخت خودکار سرویس `wg-sym-fixer.service` برای اعمال مجدد تنظیمات پس از هر بار ریبوت شدن سرور.

### نحوه نصب و اجرا

دستورات زیر را در ترمینال سرور اجرا کنید:

```bash
git clone [https://github.com/YOUR_USERNAME/wg-sym-fixer.git](https://github.com/YOUR_USERNAME/wg-sym-fixer.git)
cd wg-sym-fixer
chmod +x wg-sym-fixer.sh
sudo ./wg-sym-fixer.sh
```
*(اسکریپت به طور خودکار دسترسی `sudo` را بررسی کرده و پیش‌نیازهایی مثل `socat` و `conntrack` را نصب می‌کند).*

### راهنمای گزینه‌های منو
* **گزینه `1` (سرور دارای ۱ آی‌پی):** مناسب زمانی که می‌خواهید تانل وایرگارد فقط روی یک آی‌پی مشخص پاسخ دهد.
* **گزینه `2` (سرور دارای چند آی‌پی):** مناسب زمانی که ۲ یا چند آی‌پی پابلیک روی سرور دارید و می‌خواهید کانفیگ‌ها روی **تمامی آی‌پی‌ها به صورت همزمان** بدون خطای `closed pipe` متصل شوند.
* **گزینه `3` (بازگرداندن تنظیمات به حالت قبل):** حذف کامل زنجیره‌های فایروال اسکریپت، توقف سرویس استارت‌آپ و بازگردانی روتینگ سرور به وضعیت اولیه.
* **گزینه `0` (خروج):** خروج از محیط اسکریپت.

### تست و بررسی نهایی
پس از اجرای گزینه `1` یا `2`، اسکریپت یک **گزارش کامل (Diagnostic Report)** به شما نمایش می‌دهد. همچنین می‌توانید با دستور زیر تبادل متقارن بسته‌ها را زنده مشاهده کنید:

```bash
sudo tcpdump -ni eth0 udp port 51820
```

---

## License
Released under the [MIT License](LICENSE).
