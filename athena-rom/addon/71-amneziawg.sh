#!/sbin/sh
# ADDOND_VERSION=3
#
# Переживание OTA для userspace-части ядерного AmneziaWG.
# Модуль amneziawg.ko и sepolicy сюда НЕ входят: первый привязан к ядру
# (vermagic и CRC символов), вторая компилируется в образы. Оба приезжают
# только со сборкой ROM.
. /tmp/backuptool.functions

list_files() {
cat <<LIST
bin/awg
bin/awg-quick
system_ext/bin/awg-tunnel.sh
system_ext/etc/init/amneziawg.rc
system_ext/app/AmneziaWG/AmneziaWG.apk
LIST
}

case "$1" in
  backup)
    list_files | while read FILE DUMMY; do backup_file "$S/$FILE"; done
  ;;
  restore)
    list_files | while read FILE REPLACEMENT; do
      R=""
      [ -n "$REPLACEMENT" ] && R="$S/$REPLACEMENT"
      [ -f "$C/$S/$FILE" ] && restore_file "$S/$FILE" "$R"
    done
  ;;
  pre-backup|post-backup|pre-restore|post-restore) ;;
esac
