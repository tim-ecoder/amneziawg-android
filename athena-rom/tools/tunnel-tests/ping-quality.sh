#!/system/bin/sh
# Качество туннеля изнутри: ping-quality.sh [интерфейс] [минут] [цель]
#
# Запускать НА АППАРАТЕ, из adb root. Пишет два файла в /data/local/tmp:
#   pq-ping.log   -- пинги 10 раз в секунду через туннель
#   pq-state.log  -- время последнего хендшейка и счётчики, раз в 2 с
# По завершении создаёт pq.done. Разбор -- ping-quality-report.sh.
#
# Почему именно так. Десять пакетов в секунду дают разрешение 0,1 с: провал
# видно с точностью, недостижимой при обычном ping раз в секунду. Параллельный
# снимок хендшейка нужен, чтобы отличить провал сети от того, что творится с
# самим туннелем: без него провалы и смены ключей не сопоставить.
#
# ВАЖНО: сам замер поддерживает туннель живым. Если провалов не нашлось, это не
# доказывает, что их нет в простое -- проверяйте на нагруженном туннеле.
I=${1:-awg0}
MIN=${2:-10}
DST=${3:-10.20.0.1}
N=$(( MIN * 600 ))
S=$(( MIN * 30 ))
cd /data/local/tmp || exit 1
rm -f pq-ping.log pq-state.log pq.done
date '+start %s %T' > pq-ping.log
echo "iface=$I dst=$DST minutes=$MIN" >> pq-ping.log
( ping -i 0.1 -c "$N" "$DST" >> pq-ping.log 2>&1; echo PING-EXIT >> pq-ping.log ) &
PP=$!
( i=0; while [ $i -lt $S ]; do
    L=$(awg show "$I" dump 2>/dev/null | sed -n 2p)
    echo "$(date +%s) hs=$(echo "$L" | awk '{print $5}') rx=$(echo "$L" | awk '{print $6}') tx=$(echo "$L" | awk '{print $7}')"
    i=$((i+1)); sleep 2
  done ) > pq-state.log 2>&1
wait $PP
echo done > pq.done
