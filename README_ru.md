[README in english](https://github.com/ImMALWARE/uz801-openwrt/blob/main/README.md)
# OpenWrt для модема UZ801
![Изображение 1](https://raw.githubusercontent.com/ImMALWARE/uz801-openwrt/refs/heads/main/img/1.png)

![Изображение 2](https://raw.githubusercontent.com/ImMALWARE/uz801-openwrt/refs/heads/main/img/2.png)

![Изображение 3](https://raw.githubusercontent.com/ImMALWARE/uz801-openwrt/refs/heads/main/img/3.png)

# Изменения в форке
Я не знаю, как ModemManager работал у оригинального автора, но у меня он приводил к крашу модема. Поэтому пришлось сделать форк, написать собственные пакеты для управления сотовым подключением и SMS, а также LuCI-приложения для них. Скрипты основаны на рекомендациях из wiki postmarketOS.

Цитата из wiki postmarketOS:
> На моем UZ801 V3.2 процесс настройки свежего образа pmOS для подключения к LTE оказался довольно болезненным. В интернете много вводящих в заблуждение инструкций (например, скрипт qmi-network здесь из коробки не работает), а в других местах советуют выставлять sysctl-ключи, которых просто нет. Это устройство также не работает ни с ModemManager, ни с ofono, причем последнее оно просто крашит. Поэтому все это было выяснено вручную, методом проб и ошибок.

`alias q='qmicli -d /dev/wwan0qmi0'`

> Особенности устройства:
> - Настройка формата данных через `q --wda-set-data-format=raw-ip`, похоже, не работает. Команда возвращает успешный результат, но `--wda-set-data-format` все равно показывает 802-3. Вместо этого добавьте `--device-open-net='net-raw-ip|net-no-qos-header'` к вызову `wds-start-network`
> - `--client-cid=...` опасен и подвешивает `qmicli`. Важно: модем при этом не виснет, просто перестает отвечать, а `qmicli` плохо обрабатывает таймауты
> - `--wds-go-dormant` / `--wds-go-active` ничего не делают. В целом моя версия кажется сильно урезанной, даже `--wds-get-supported-messages` завершается ошибкой
> - `--client-no-release-cid` не работает, используйте `--wds-follow-network`. Но это заблокирует вашу shell-сессию. Чтобы отключиться, сначала нажмите ^C (чтобы `qmicli` отправил модему запрос на отключение), затем ^Z, после чего выполните `killall -9 qmicli` (иначе процесс зависнет навсегда)
> - `qmicli` иногда случайно не может получить статус от модема. В результате появляется "error: operation failed: Transaction timed out". This Is Fine™

sms-tool и [luci-app-3ginfo-lite](https://github.com/4IceG/luci-app-3ginfo-lite) тоже приводили к крашу модема.

Я удалил:
- WireGuard
- ModemManager

Добавил:
- Русский язык
- NFQUEUE
- PBR
- mailsend
- [AmneziaWG](https://docs.amnezia.org/documentation/amnezia-wg/)
- sing-box
- SMB сервер
- Патч ядра для подсчета RX/TX пакетов и байтов

Пакеты, написанные с нуля:
- zhihe-qmi + luci-proto-zhiheqmi - для подключения к сотовой сети. Добавьте интерфейс `modem` с протоколом `Zhihe/Yiming QMI`.
- modem-at-engine - сервис ubus для отправки AT-команд модему способом, при котором он не крашится :D
- sms-sqlite-sync + luci-app-sms-sqlite - каждые 3 минуты проверяет новые SMS на SIM-карте и переносит их в базу данных. Также умеет отправлять email о новых SMS. Приложение LuCI умеет показывать и отправлять SMS.
- luci-app-cellular-info - информация о сотовом подключении, уровне сигнала и ближайших сотах.

К сожалению, мне не удалось настроить IPv6 на сотовом подключении :(

# Как установить с компьютера на Linux 
1. Скачайте все файлы из последнего релиза OpenWrt ([страница релизов](https://github.com/ImMALWARE/uz801-openwrt/releases)).
2. Включите ADB на модеме, открыв http://192.168.100.1/usbdebug.html
3. Установите adb и [инструменты edl](https://github.com/bkerler/edl) на ваш компьютер
4. Подключив модем по USB, выполните `adb reboot edl`, чтобы перезагрузить его в режим EDL
5. Сделайте полную резервную копию прошивки модема:
```
edl rf stock.bin
edl rl stock --genxml
```
6. Перейдите (`cd`) в папку с файлами, скачанными на шаге 1, и выполните:
```
chmod +x openwrt-msm89xx-msm8916-yiming-uz801v3-flash.sh
./openwrt-msm89xx-msm8916-yiming-uz801v3-flash.sh
```
7. Дождитесь завершения скрипта, затем дождитесь инициализации модема. Должно появиться новое проводное подключение, а LuCI будет доступен по адресу http://192.168.1.1
8. Чтобы подключиться к сотовой сети, перейдите в Сеть -> Интерфейсы -> Добавить новый интерфейс, назовите его `modem` и выберите протокол `Zhihe/Yiming QMI`.

# Настройка email-переадресации в sms-sqlite-sync
1. Включите email-переадресацию:
```sh
uci set sms_sync.main.enable_email='1'
```

2. Укажите параметры SMTP (пример для пароля приложения Gmail):
```sh
uci set sms_sync.main.smtp_server='smtp.gmail.com'
uci set sms_sync.main.smtp_port='465'
uci set sms_sync.main.smtp_user='your_email@gmail.com'
uci set sms_sync.main.smtp_pass='your_app_password'
uci set sms_sync.main.email_to='destination@example.com'
uci set sms_sync.main.email_from='router@example.com'
```

3. Сохраните конфигурацию:
```sh
uci commit sms_sync
```

# Как обновить на новую версию
## Способ 1: Через sysupgrade (Рекомендуемый)
1. Скачайте файл `openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-sysupgrade.bin` из релиза новой версии
2. В LuCI перейдите в меню Система -> Восстановление / Обновление.
3. В разделе "Установить новый образ прошивки" выберите скачанный .bin файл и нажмите Обновить прошивку. При необходимости поставьте или снимите галочку «Сохранить настройки».
4. Дождитесь завершения прошивки и автоматической перезагрузки модема.

Альтернатива через SSH:
Загрузите .bin файл на модем в папку /tmp/ и выполните:
```sh
sysupgrade -v /tmp/openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-sysupgrade.bin
```

### Способ 2: Через fastboot 
1. Подключитесь к модему по SSH и повредите раздел загрузчика `boot`, чтобы отправить модем в fastboot:
    ```sh
    dd if=/dev/zero of=/dev/mmcblk0p13 bs=1M count=1
    reboot
    ```
    Модем перезагрузится с поврежденным ядром и автоматически перейдет в режим fastboot.

2. Подключите модем к ПК на Linux с установленным fastboot и запишите новые файлы ядра и системы:
    ```sh
    fastboot flash boot openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-boot.img
    fastboot flash rootfs openwrt-msm89xx-msm8916-yiming-uz801v3-squashfs-system.img
    ```

3. Если вы хотите полностью сбросить настройки и удалить все пользовательские данные, сотрите раздел `rootfs_data`. Если вы хотите сохранить настройки и данные, пропустите этот шаг:
    ```sh
    fastboot erase rootfs_data
    ```

4. Перезагрузите модем:
    ```sh
    fastboot reboot
    ```

5. Исправьте конфликты с базой данных установленных пакетов:
	```sh
	rm -f /overlay/upper/lib/apk/db/installed
	cat /overlay/upper/etc/apk/world 2>/dev/null | grep -vE '^(kernel=|base-files=)' | cat - /rom/etc/apk/world | sort -u > /tmp/world.merged && mv /tmp/world.merged /overlay/upper/etc/apk/world
	```
	**ПЕРЕЗАГРУЗИТЕ МОДЕМ ПОСЛЕ ЭТОГО!**
	```sh
	reboot
	```

	```sh
	apk update
	apk fix
	```
