#!/bin/bash
# Сборка awg-kernel-addon-cleaner.zip -- пакета, который снимает с аппарата всё,
# что поставил awg-kernel-addon.zip.
#
# Ставится тем же путём: Updater как локальное обновление, либо sideload.
# Внутри только updater-script и метаданные, полезной нагрузки нет.
#
# Что снимает: шесть файлов из /system, кэш разбора пакетов и конфиги туннелей
# в /data/misc/amneziawg.
# Шаги с /data -- по возможности: раздел зашифрован пофайлово (ro.crypto.type=file),
# и recovery может не увидеть там имён. Полагаться на них нельзя, но и вреда нет:
# менеджер пакетов и сам заметит, что APK из /system исчез. Для гарантированной
# уборки состояния есть clean-addon.sh, он работает из adb на живой системе.
#
# Что НЕ снимает: модуль ядра и sepolicy -- они в образе прошивки, не в аддоне.
# И флаг ingress_to_vpn_address_filtering: в recovery фреймворка нет, снять его
# оттуда нечем; команда для этого печатается на экране.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
KEYS=/data/@SIGNING-KEYS/signing-keys
HOST=/data/los23out2/host/linux-x86
SIGNAPK="java -Djava.library.path=$HOST/lib64 -jar $HOST/framework/signapk.jar"
PREV="$HERE/awg-kernel-addon.zip"
OUT="$HERE/awg-kernel-addon-cleaner.zip"
WORK="$(mktemp -d /tmp/claude-1000/-data-LOS232/cleaner.XXXXXX 2>/dev/null || mktemp -d)"

[ -f "$PREV" ] || { echo "нет $PREV -- update-binary берётся оттуда" >&2; exit 1; }
cd "$WORK"
# update-binary из основного пакета: он один и тот же, штатный из прошивки.
mkdir -p META-INF/com/google/android META-INF/com/android
unzip -q -j "$PREV" META-INF/com/google/android/update-binary -d META-INF/com/google/android
install -m 0644 "$HERE/cleaner-updater-script" META-INF/com/google/android/updater-script
# Метаданные с датой 2100 года, чтобы Updater не счёл пакет откатом.
python3 "$HERE/make-metadata.py" "$WORK"

rm -f unsigned.zip
zip -q -X unsigned.zip META-INF/com/android/metadata META-INF/com/android/metadata.pb
zip -q -X -r unsigned.zip META-INF/com/google
$SIGNAPK -w "$KEYS/releasekey.x509.pem" "$KEYS/releasekey.pk8" unsigned.zip cleaner.zip
cp cleaner.zip "$OUT"
rm -rf "$WORK"
echo "готово: $OUT"
unzip -l "$OUT" | sed -n '4,12p'
md5sum "$OUT"
