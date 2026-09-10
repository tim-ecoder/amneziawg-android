#!/system/bin/sh
# Разбор замера: ping-quality-report.sh
# Запускать на аппарате после ping-quality.sh.
P=/data/local/tmp/pq-ping.log
S=/data/local/tmp/pq-state.log
[ -f "$P" ] || { echo "нет $P"; exit 1; }
START=$(head -1 "$P" | awk '{print $2}')
head -2 "$P" | tail -1
echo "== итог:"
awk '/icmp_seq=/{ match($0,/icmp_seq=[0-9]+/); s=substr($0,RSTART+9,RLENGTH-9)+0
  if(f==0){f=s;p=s-1}; if(s>p+1){lost+=s-p-1; ev++}; p=s; got++ }
  END{ if(!got){print "  ответов нет"; exit}
       printf "  отправлено %d, получено %d, потеряно %d (%.2f%%), событий потерь %d\n", p-f+1, got, lost, lost*100.0/(p-f+1), ev }' "$P"
echo "== каждая потеря:"
awk -v st="$START" '/icmp_seq=/{ match($0,/icmp_seq=[0-9]+/); s=substr($0,RSTART+9,RLENGTH-9)+0
  if(f==0){f=s;p=s-1}
  if(s>p+1){ n=s-p-1; b=(p+1)*0.1; printf "  %d шт = %.1f с, на +%.1f с (abs %d)\n", n, n*0.1, b, st+b }
  p=s }' "$P"
echo "== смены ключей (должны быть каждые ~120 с и НЕ совпадать с потерями):"
[ -f "$S" ] && awk -v st="$START" '{ if (prev!="" && $2!=prev) printf "  +%d с (abs %s)\n", $1-st, $1; prev=$2 }' "$S"
echo "== задержки:"
awk '/time=/{ match($0,/time=[0-9.]+/); t=substr($0,RSTART+5,RLENGTH-5)+0
  n++; sum+=t; if(t>mx)mx=t; if(t<100)a++; else if(t<150)b++; else if(t<300)c++; else d++ }
  END{ if(n) printf "  среднее %.0f мс, максимум %.0f мс; <100: %d, 100-150: %d, 150-300: %d, >300: %d\n", sum/n, mx, a,b,c,d }' "$P"
