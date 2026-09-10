#!/system/bin/sh
# Убрать с аппарата всё, что поставил awg-addon.zip: clean-addon.sh [--data]
#
# Запускать НА АППАРАТЕ из adb root. С --data сносит и рабочее состояние:
# конфиги туннелей, данные приложения и флаг фильтрации входящих.
#
# Что НЕ убирается и убрано быть не может: модуль ядра amneziawg.ko и sepolicy.
# Они лежат в образе прошивки, а не в аддоне, и уходят только с другой сборкой.
# Метки в file_contexts там же -- вреда от них нет, файлов для них просто не
# останется.
set -u
DATA=0; [ "${1:-}" = "--data" ] && DATA=1

echo "1. опускаю туннели"
for I in $(awg show interfaces 2>/dev/null); do
    setprop sys.amneziawg.iface "$I"
    start amneziawg_down 2>/dev/null
    sleep 2
done
stop amneziawg_status 2>/dev/null
for I in $(awg show interfaces 2>/dev/null); do ip link del "$I" 2>/dev/null; done
while ip rule del pref 17900 2>/dev/null; do :; done

echo "2. снимаю файлы аддона"
mount -o remount,rw / || { echo "   не удалось перемонтировать / на запись"; exit 1; }
rm -f  /system/bin/awg /system/bin/awg-quick
rm -f  /system/system_ext/bin/awg-tunnel.sh
rm -f  /system/system_ext/etc/init/amneziawg.rc
rm -rf /system/system_ext/app/AmneziaWG
rm -f  /system/addon.d/71-amneziawg.sh
mount -o remount,ro / 2>/dev/null

echo "3. чищу кэш разбора пакетов"
# Без этого система будет помнить приложение, которого уже нет.
rm -rf /data/system/package_cache/*

if [ "$DATA" = 1 ]; then
    echo "4. чищу рабочее состояние"
    rm -rf /data/misc/amneziawg
    pm clear org.amnezia.awg 2>/dev/null
    # Флаг возвращаем в значение по умолчанию: он ослабляет защиту, и без
    # туннеля в нём нет смысла.
    cmd device_config delete tethering ingress_to_vpn_address_filtering
else
    echo "4. рабочее состояние оставлено (запустите с --data, чтобы снести)"
fi

echo "готово. нужна перезагрузка"
