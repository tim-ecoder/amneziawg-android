#!/bin/bash
# Запуск замера с ПК: run-from-pc.sh [serial] [интерфейс] [минут]
# Канал к аппарату идёт через сам туннель и рвётся, поэтому замер запускается
# отвязанно (nohup) и результат забирается отдельно.
SER=${1:-10.20.0.3:54321}
I=${2:-awg0}
MIN=${3:-10}
D="adb -s $SER"
HERE="$(cd "$(dirname "$0")" && pwd)"
set -e
for f in ping-quality.sh ping-quality-report.sh; do
    for i in 1 2 3; do
        $D push "$HERE/$f" "/data/local/tmp/$f" >/dev/null 2>&1 && break
        adb connect "$SER" >/dev/null 2>&1; sleep 5
    done
done
$D shell "rm -f /data/local/tmp/pq.done; nohup sh /data/local/tmp/ping-quality.sh $I $MIN >/dev/null 2>&1 </dev/null &"
echo "замер на $MIN мин запущен; результат: $0 --report"
