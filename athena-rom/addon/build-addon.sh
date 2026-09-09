#!/bin/bash
# Сборка awg-addon.zip -- userspace-части ядерного AmneziaWG для athena.
#
# В zip входят тулзы awg/awg-quick, служба awg-tunnel.sh, amneziawg.rc, APK и
# addon.d-скрипт. Модуль ядра и sepolicy сюда НЕ входят (привязаны к ядру и
# образам), поэтому аддон работает только поверх нашей прошивки.
#
# Использование: ./build-addon.sh [подписанный APK]
#   APK по умолчанию -- ../app-fork/AmneziaWG-athena-platform.apk
#   (подписан платформенным ключом, иначе не будет домена amneziawg_app).
#
# Метаданные (META-INF/com/android/metadata и metadata.pb) генерируются
# make-metadata.py и от версии прошивки НЕ зависят: post-timestamp стоит в
# 2100 году, так что Updater никогда не скажет DOWNGRADE, а recovery для
# BLOCK-пакетов время не проверяет. Из прежнего zip берутся только
# update-binary и тулзы.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEV=/data/LOS232/device/blackberry/sdm660-common
KEYS=/data/@SIGNING-KEYS/signing-keys
HOST=/data/los23out2/host/linux-x86
SIGNAPK="java -Djava.library.path=$HOST/lib64 -jar $HOST/framework/signapk.jar"
APK="${1:-$HERE/../app-fork/AmneziaWG-athena-platform.apk}"
PREV="$HERE/awg-addon.zip"
WORK="$(mktemp -d /tmp/claude-1000/-data-LOS232/addon.XXXXXX 2>/dev/null || mktemp -d)"

[ -f "$APK" ] || { echo "нет APK: $APK" >&2; exit 1; }
[ -f "$PREV" ] || { echo "нет прежнего zip с метаданными и тулзами: $PREV" >&2; exit 1; }

cd "$WORK"
# Каркас из прежнего zip: метаданные, update-binary, updater-script, тулзы.
unzip -q "$PREV" -x 'META-INF/com/android/otacert' 'META-INF/MANIFEST.MF' 'META-INF/CERT.*' 2>/dev/null
# Свежие служба, rc, addon.d и APK.
install -m 0755 "$DEV/system_ext/bin/awg-tunnel.sh"       system/system_ext/bin/awg-tunnel.sh
install -m 0644 "$DEV/system_ext/etc/init/amneziawg.rc"   system/system_ext/etc/init/amneziawg.rc
install -m 0755 "$HERE/71-amneziawg.sh"                    system/addon.d/71-amneziawg.sh
install -m 0644 "$HERE/updater-script"                     META-INF/com/google/android/updater-script
install -m 0644 "$APK"                                     system/system_ext/app/AmneziaWG/AmneziaWG.apk
# Если в prebuilt лежат более свежие тулзы -- берём их.
for t in awg awg-quick; do
    [ -f "$HERE/../prebuilt/$t" ] && install -m 0755 "$HERE/../prebuilt/$t" "system/bin/$t"
done

# Свои метаданные вместо взятых из прежнего zip.
python3 "$HERE/make-metadata.py" "$WORK"

# metadata должен быть ПЕРВЫМ файлом архива.
rm -f unsigned.zip
zip -q -X unsigned.zip META-INF/com/android/metadata META-INF/com/android/metadata.pb
zip -q -X -r unsigned.zip META-INF/com/google system
$SIGNAPK -w "$KEYS/releasekey.x509.pem" "$KEYS/releasekey.pk8" unsigned.zip awg-addon.zip

cp awg-addon.zip "$PREV"
rm -rf "$WORK"
echo "готово: $PREV"
unzip -l "$PREV" | sed -n '4,20p'
md5sum "$PREV"
