[README на русском](https://github.com/ImMALWARE/uz801-openwrt/blob/main/README_ru.md)
# OpenWrt for UZ801 modem
![Image 1](https://raw.githubusercontent.com/ImMALWARE/uz801-openwrt/refs/heads/main/img/1.png)

![Image 2](https://raw.githubusercontent.com/ImMALWARE/uz801-openwrt/refs/heads/main/img/2.png)

![Image 3](https://raw.githubusercontent.com/ImMALWARE/uz801-openwrt/refs/heads/main/img/3.png)

# Changes in fork
I don't know how did ModemManager for the original author, but for me it was crashing the modem. So I had to fork, write my own packages to manage cellular connection and SMS, and LuCI apps for them. Scripts are based on postmarketOS wiki advices.

Citation from postmarketOS wiki:
> On my UZ801 V3.2, the process of getting a fresh pmOS image to connect to LTE was rather painful. The internet lists some misleading instructions (qmi-network script does not work out of the box here), and in other cases suggests setting sysctl keys which do not exist. This device also does not work with ModemManager, nor ofono, straight up crashing the latter. Hence, all of this has been determined through manual trial and error.

`alias q='qmicli -d /dev/wwan0qmi0'`

> Device-specific quirks:
> - Setting the data format through `q --wda-set-data-format=raw-ip` does not seem to work. It falsely returns success, but `--wda-set-data-format` says 802-3 still. Instead, append `--device-open-net='net-raw-ip|net-no-qos-header'` to the `wds-start-network` call
> - `--client-cid=...` is evil and will hang `qmicli`. Of note, it doesn't hang the modem, just causes it to never respond, and `qmicli` is bad at handling timeouts
> - `--wds-go-dormant` / `--wds-go-active` doesn't do anything. Generally my version seems to be quite cut down, even `--wds-get-supported-messages` fails
> - `--client-no-release-cid` fails, use `--wds-follow-network` instead. This will lock up your shell, however. To disconnect, first ^C so `qmicli` sends a disconnection request to the modem, then ^Z, then `killall -9 qmicli` (otherwise it'll hang forever)
> - `qmicli` seems to be randomly unable to receive status back from the modem. This will result in "error: operation failed: Transaction timed out". This Is Fine™

sms-tool, [luci-app-3ginfo-lite](https://github.com/4IceG/luci-app-3ginfo-lite) also crashed the modem.

I removed:
- WireGuard
- ModemManager

Added:
- Russian language
- NFQUEUE
- PBR
- mailsend
- [AmneziaWG](https://docs.amnezia.org/documentation/amnezia-wg/)
- sing-box
- SMB server
- Kernel patch for counting RX/TX packets and bytes

Packages written from scratch:
- zhihe-qmi + luci-proto-zhiheqmi - for connecting to cellular network. Add `modem` interface with `Zhihe/Yiming QMI` protocol.
- modem-at-engine - ubus service to send AT commands to modem the way it doesn't crash :D
- sms-sqlite-sync + luci-app-sms-sqlite - checks for new SMS on SIM card every 3 minutes and moves them to database. Also able to send email about new SMS. LuCI app can show and send SMS.
- luci-app-cellular-info - information about cellular connection, signal strength, and nearby cells.

Unfortunately, I couldn't set up IPv6 on cellular connection :(

# How to install from Linux computer
1. Download all files from latest OpenWrt release ([releases page](https://github.com/ImMALWARE/uz801-openwrt/releases)).
2. Enable ADB on modem by opening http://192.168.100.1/usbdebug.html
3. Install adb and [edl tools](https://github.com/bkerler/edl) on your computer
4. When connected to modem via USB, run `adb reboot edl` to reboot into EDL mode
5. Make a full backup of your modem's firmware:
```
edl rf stock.bin
edl rl stock --genxml
```
6. `cd` to folder with downloaded files from step 1 and run:
```
chmod +x openwrt-msm89xx-msm8916-yiming-uz801v3-flash.sh
./openwrt-msm89xx-msm8916-yiming-uz801v3-flash.sh
```
7. Wait for the script to finish, then wait for modem to initialize. You should see new wired connection, and you can access LuCI at http://192.168.1.1
8. To connect to cellular network, go to Network -> Interfaces -> Add new interface, call it `modem`, set protocol to `Zhihe/Yiming QMI`.

# Set up email forwarding in sms-sqlite-sync
1. Enable email forwarding:
```sh
uci set sms_sync.main.enable_email='1'
```

2. Set SMTP parameters (example for Gmail app password):
```sh
uci set sms_sync.main.smtp_server='smtp.gmail.com'
uci set sms_sync.main.smtp_port='465'
uci set sms_sync.main.smtp_user='your_email@gmail.com'
uci set sms_sync.main.smtp_pass='your_app_password'
uci set sms_sync.main.email_to='destination@example.com'
uci set sms_sync.main.email_from='router@example.com'
```

3. Save config:
```sh
uci commit sms_sync
```

# How to update to a new version
## Method 1: Via sysupgrade (Recommended)
1. Download `openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-sysupgrade.bin` from the new release.
2. In LuCI, go to System -> Backup / Flash Firmware.
3. In the "Flash new firmware image" section, select the downloaded `.bin` file and click Flash image. If needed, enable or disable "Keep settings".
4. Wait for flashing to complete and for the modem to reboot automatically.

Alternative via SSH:
Upload the `.bin` file to `/tmp/` on the modem and run:
```sh
sysupgrade -v /tmp/openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-sysupgrade.bin
```

### Method 2: Via fastboot
1. Connect to the modem over SSH and corrupt the `boot` partition to force the modem into fastboot mode:
	```sh
	dd if=/dev/zero of=/dev/mmcblk0p13 bs=1M count=1
	reboot
	```
	The modem will reboot with a corrupted kernel and automatically enter fastboot mode.

2. Connect the modem to a Linux PC with fastboot installed, then write the new boot and system images:
	```sh
	fastboot flash boot openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-boot.img
	fastboot flash rootfs openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-system.img
	```

3. If you want a full reset and to remove all user data, erase the `rootfs_data` partition. If you want to keep settings and data, skip this step:
	```sh
	fastboot erase rootfs_data
	```

4. Reboot the modem:
	```sh
	fastboot reboot
	```

5. Fix conflicts with installed packages database:
	```sh
	rm -f /overlay/upper/lib/apk/db/installed
	cat /overlay/upper/etc/apk/world 2>/dev/null | grep -vE '^(kernel=|base-files=)' | cat - /rom/etc/apk/world | sort -u > /tmp/world.merged && mv /tmp/world.merged /overlay/upper/etc/apk/world
	```
	**REBOOT AFTER THIS!**
	```sh
	reboot
	```

	```sh
	apk update
	apk fix
	```
