#!/system/bin/sh
#
# Поднимает/опускает ядерный туннель AmneziaWG и публикует его состояние.
#
# Запускается только из init (system_ext/etc/init/amneziawg.rc), потому что
# нужен CAP_NET_ADMIN. Приложение org.amnezia.awg ничего не выполняет само:
# в system/sepolicy две стены закрывают ему этот путь --
#   netd.te:205             neverallow { appdomain -network_stack } netd:binder call
#   app_neverallows.te:135  neverallow all_untrusted_apps *:{ ... netlink_generic_socket ... }
# первая запрещает awg-quick (он ходит в netd), вторая -- даже чтение
# состояния через awg show. Поэтому протокол такой:
#
#   приложение: пишет конфиг в /data/misc/amneziawg/<имя>.conf,
#               setprop sys.amneziawg.iface <имя>, ctl.start amneziawg_{up,down}
#   мы:         делаем работу и отвечаем в sys.amneziawg.result как "<имя>:<код>"
#   состояние:  awg show all dump в /data/misc/amneziawg/status, обновляется
#               сервисом amneziawg_status, пока туннель поднят
#
# Роуминг wifi <-> мобильная сеть. Модуль сам сбрасывает кэш маршрута до пира
# раз в 5 с (socket.c, WG_ENDPOINT_CACHE_TTL), но ЭТОГО НЕ ДОСТАТОЧНО: замер на
# 5000014556 19:44-19:48 показал, что при неизменном listen-port туннель после
# ухода на LTE не ожил за 3.5 минуты (rx стоял, хендшейка нет 298 с), а
# пересоздание сокета подняло связь за 4 с. Поэтому пересоздание остаётся
# основным средством: быстрый путь -- refresh по событию из приложения,
# надёжный -- слежение за исходящим интерфейсом в ветке status.

DIR=/data/misc/amneziawg
STATUS=$DIR/status
TAG=awg-tunnel

# Как часто обновлять файл состояния. Раньше цикл шёл раз в 2 с и запускал
# около десятка процессов за итерацию -- это стоило ~11% одного ядра постоянно
# (замер на 5000014556: 188 CPU-с за 1628 с). Теперь за итерацию три процесса.
STATUS_PERIOD=10
# Сторож на случай, когда интерфейс тот же, а связь встала: сменился адрес,
# оператор пересобрал NAT. При исправной связи хендшейк обновляется раз в ~120 с,
# поэтому 180 с без него -- уже не норма.
HS_STALE=180
REBIND_MIN_GAP=60
# Шаг повторных попыток после смены сети и порог "связь ожила" по приросту rx.
# 12 с. Каждый новый порт -- новая попытка пробиться: замер на 5000014556
# (22:21-22:23) показал, что после ухода на LTE первые два порта молчали по
# 30+ с, а третий дал хендшейк за 8 с. При шаге 30 с восстановление занимало
# ~72 с, поэтому шаг укорочен -- лишние попытки теперь безопасны, потому что
# признак восстановления (новый хендшейк) работает и цикл сам останавливается.
# Раньше короткий шаг был опасен именно из-за сломанного признака.
RETRY_GAP=12
RX_ALIVE=8192

log() { /system/bin/log -t "$TAG" -p i "$*" 2>/dev/null; }
reply() { setprop sys.amneziawg.result "$1:$2"; }

# Файл состояния читает приложение. Ключи в нём не нужны и лишние: второе
# поле строки интерфейса -- приватный ключ, третье поле строки пира -- PSK.
# Оба затираются, число полей сохраняется (приложение считает поля).
# chmod ДО mv: файл создаётся редиректом от root с umask по умолчанию (0600),
# и приложение ловило EACCES в окне между mv и chmod, считало туннель мёртвым
# и пересоздавало его.
write_status() {
    awg show all dump 2>/dev/null | awk -F'\t' '
        BEGIN { OFS = "\t" }
        $1 != prev { prev = $1; $2 = "(hidden)"; print; next }
        { $3 = "(none)"; print }' > "$STATUS".tmp || return 0
    chmod 644 "$STATUS".tmp 2>/dev/null
    mv "$STATUS".tmp "$STATUS"
}

# Время последнего хендшейка пира интерфейса -- из уже записанного файла
# состояния, чтобы не звать awg второй раз. Строка пира: iface, pubkey, psk,
# endpoint, allowed-ips, latest-handshake, rx, tx, keepalive.
hs_ts() { awk -F'\t' -v i="$1" '$1 == i && NF == 9 { print $6; exit }' "$STATUS" 2>/dev/null; }

# Принятые байты пира -- из того же файла состояния.
rx_bytes() { awk -F'\t' -v i="$1" '$1 == i && NF == 9 { print $7+0; exit }' "$STATUS" 2>/dev/null; }

# Через какой интерфейс сейчас уходят наружу пакеты туннеля. Именно это
# меняется при переходе wifi <-> мобильная сеть.
outbound_dev() {
    EP=$(awg show "$1" endpoints 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$EP" ] || return 1
    MK=$(awg show "$1" fwmark 2>/dev/null); [ -n "$MK" ] || MK=0x20000
    ip route get "${EP%:*}" mark "$MK" 2>/dev/null | head -1 | sed -n 's/.* dev \([^ ]*\).*/\1/p'
}

# Пересоздание UDP-сокета сменой listen-port. Не ломает ни маршрутов, ни
# правил netd, ни соединений поверх туннеля -- можно повторять сколько угодно.
rebind() {
    CUR=$(awg show "$1" listen-port 2>/dev/null)
    NEW=$(( 41000 + $(date +%s) % 20000 ))
    [ "$NEW" = "$CUR" ] && NEW=$(( NEW + 1 ))
    awg set "$1" listen-port "$NEW" 2>/dev/null || return 1
    log "$1: сокет пересоздан, порт $CUR -> $NEW"
    provoke "$1"
}

# Заставляем туннель немедленно начать хендшейк, сбрасывая состояние пиров.
#
# Так делает штатный AmneziaVPN, и это измерено: по смене сети он уничтожает
# VPN-интерфейс и создаёт заново (в замере 22:33 интерфейс сменился tun1 -> tun0,
# счётчики обнулились), после чего свежий wireguard-go сразу начинает хендшейк.
# Восстановление -- 10 с. Наш прежний путь, где менялся только UDP-порт, а
# устройство и сессия оставались прежними, давал ~70 с: старый keypair ещё жив,
# отправлять нечего, хендшейк не начинается.
#
# Полное переподнятие через awg-quick нам запрещено собственным опытом: однажды
# down прошёл, up не удался, и аппарат остался без связи (README, часть 10).
# Поэтому берём середину: `awg setconf` заменяет пиров целиком
# (WGDEVICE_F_REPLACE_PEERS), то есть сбрасывает ключи, таймеры и endpoint-кэш --
# ровно как у свежего устройства, -- но интерфейс, маршруты и конфигурация netd
# остаются нетронутыми. Добавление пира с persistent-keepalive попутно вызывает
# немедленную отправку keepalive (netlink.c: send_keepalive при 0 -> ненулевое),
# а тот при отсутствии сессии тянет за собой инициацию хендшейка.
provoke() {
    CONF="$DIR/$1.conf"
    STRIP="$DIR/.$1.strip"
    if [ -f "$CONF" ]; then
        # Свой стрип: `awg-quick strip` в андроидном порту тулзов не реализован.
        # Выкидываем ключи, которые понимает только awg-quick, и ОБЯЗАТЕЛЬНО
        # возвращаем FwMark: без него setconf обнулит метку, и пакеты туннеля
        # начнут маршрутизироваться в него же самого.
        MK=$(awg show "$1" fwmark 2>/dev/null); [ -n "$MK" ] || MK=0x20000
        awk -v mk="$MK" '
            /^[[:space:]]*\[Interface\]/ { print; print "FwMark = " mk; next }
            /^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig|IncludedApplications|ExcludedApplications)[[:space:]]*=/ { next }
            { print }' "$CONF" > "$STRIP" 2>/dev/null
        if [ -s "$STRIP" ] && awg setconf "$1" "$STRIP" 2>/dev/null; then
            log "$1: состояние пиров сброшено (setconf)"
            rm -f "$STRIP"
            return 0
        fi
        rm -f "$STRIP"
    fi
    # Запасной путь: keepalive через ноль даёт немедленный хендшейк, но старую
    # сессию не сбрасывает.
    for P in $(awg show "$1" peers 2>/dev/null); do
        K=$(awg show "$1" persistent-keepalive 2>/dev/null | awk -v p="$P" '$1 == p { print $2 }')
        case "$K" in ''|off|0) K=25 ;; esac
        awg set "$1" peer "$P" persistent-keepalive 0 2>/dev/null
        awg set "$1" peer "$P" persistent-keepalive "$K" 2>/dev/null
    done
}

IFACE="${2:-$(getprop sys.amneziawg.iface)}"
[ -n "$IFACE" ] || IFACE=awg0
# Имя приходит из проперти, которую ставит приложение, и попадает в путь к
# конфигу и в аргументы awg-quick. Ограничиваем тем, что допустимо для имени
# сетевого интерфейса.
case "$IFACE" in
    *[!A-Za-z0-9_.=+-]*|"") log "недопустимое имя интерфейса"; reply "${IFACE:-?}" 4; exit 1 ;;
esac
[ ${#IFACE} -le 15 ] || { log "слишком длинное имя интерфейса"; reply "$IFACE" 4; exit 1; }

case "$1" in
up)
    CONF="$DIR/$IFACE.conf"
    if [ ! -f "$CONF" ]; then
        log "нет конфига $CONF"; reply "$IFACE" 2; exit 0
    fi
    # Модуль грузит init (init.target.rc). Без него awg-quick молча ушёл бы
    # в userspace-go, которого в этой сборке нет вовсе.
    i=0
    while [ ! -d /sys/module/amneziawg ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i+1)); done
    if [ ! -d /sys/module/amneziawg ]; then
        log "модуль amneziawg не загружен"; reply "$IFACE" 3; exit 1
    fi
    if ip link show "$IFACE" >/dev/null 2>&1; then
        log "$IFACE уже поднят"; write_status; reply "$IFACE" 0; exit 0
    fi
    log "поднимаю $IFACE (ядро $(cat /sys/module/amneziawg/version))"
    awg-quick up "$IFACE" 2>&1 | while read -r l; do log "$l"; done
    if ip link show "$IFACE" >/dev/null 2>&1; then
        write_status; start amneziawg_status; reply "$IFACE" 0
    else
        log "не удалось поднять $IFACE"; reply "$IFACE" 1
    fi
    ;;
down)
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        log "$IFACE не поднят"; write_status; reply "$IFACE" 0; exit 0
    fi
    log "опускаю $IFACE"
    # Сначала останавливаем слежение, иначе оно перезапишет файл состояния
    # обратно, пока интерфейс ещё жив, и приложение прочитает именно эту свежую
    # запись (замер 09:51: после честного down статус тут же становился
    # "подключается" и приложение застревало в нём).
    stop amneziawg_status
    # Обнуляем файл состояния ДО awg-quick.
    #
    # awg-quick сам шлёт приложению REFRESH_TUNNEL_STATES в начале работы, и
    # приложение тут же перечитывает этот файл. Пока он содержал прежний дамп,
    # приложение через миллисекунду после честного "отключено" снова считало
    # туннель поднятым и висело так до своего таймаута в 25 с, проглатывая
    # следующее нажатие (замер на 5000014556 09:36:57-09:37:24).
    : > "$STATUS" 2>/dev/null
    chmod 644 "$STATUS" 2>/dev/null
    awg-quick down "$IFACE" 2>&1 | while read -r l; do log "$l"; done
    ip link show "$IFACE" >/dev/null 2>&1 && reply "$IFACE" 1 || reply "$IFACE" 0
    write_status
    # Если остались другие поднятые туннели, слежение возвращаем.
    [ -n "$(awg show interfaces 2>/dev/null)" ] && start amneziawg_status
    ;;
refresh)
    # Быстрый путь: приложение зовёт это по событию смены сети.
    #
    # Пересоздание UDP-сокета сменой listen-port -- единственное, что реально
    # поднимает туннель после переезда. Замер на 5000014556 19:44-19:48: при
    # неизменном порте после ухода на LTE rx стоял 3.5 минуты и хендшейк не
    # проходил, а смена порта дала хендшейк за 4 с. Сброса кэша маршрута в
    # модуле для этого мало.
    #
    # Операция дешёвая и неразрушающая: маршруты, правила netd и соединения
    # поверх туннеля остаются на месте.
    ip link show "$IFACE" >/dev/null 2>&1 || { reply "$IFACE" 0; exit 0; }
    if rebind "$IFACE"; then
        write_status; reply "$IFACE" 0
    else
        log "$IFACE: не удалось сменить порт"; reply "$IFACE" 1
    fi
    ;;
status)
    # Пишем файл состояния, пока поднят хоть один туннель: приложению неоткуда
    # взять статистику иначе. Заодно это наш слушатель смены сети.
    #
    # Служба намеренно ничего не разрушает: awg-quick down/up только по явной
    # команде приложения. Полное переподнятие как «запасной ярус» однажды сняло
    # интерфейс и не подняло обратно, оставив аппарат без связи.
    #
    # Период 10 с, а не 2 с, как было раньше: тот цикл запускал десяток
    # процессов за итерацию и стоил ~11% одного ядра постоянно (188 CPU-с за
    # 1628 с). Быстрый путь всё равно даёт приложение через refresh, здесь --
    # надёжный: сеть могла смениться, пока приложение заморожено в doze.
    log "слежу за $IFACE, период $STATUS_PERIOD с"
    DEV=$(outbound_dev "$IFACE")
    TRY=0; DEADLINE=0; RX0=0; HS0=; LAST_REBIND=0
    # Отсчёт "хендшейка не было ни разу" ведём от старта слежения.
    NOHS_SINCE=$(date +%s)
    while [ -n "$(awg show interfaces 2>/dev/null)" ]; do
        write_status
        NOW=$(outbound_dev "$IFACE")
        T=$(date +%s)
        # Пока ждём восстановления -- поддерживаем повод для хендшейка.
        [ "$DEADLINE" != 0 ] && provoke "$IFACE"

        if [ -n "$NOW" ] && [ -n "$DEV" ] && [ "$NOW" != "$DEV" ]; then
            log "$IFACE: сеть сменилась, $DEV -> $NOW, пересоздаю сокет"
            RX0=$(rx_bytes "$IFACE"); HS0=$(hs_ts "$IFACE")
            rebind "$IFACE"; LAST_REBIND=$T; TRY=1; DEADLINE=$(( T + RETRY_GAP ))
        elif [ "$DEADLINE" != 0 ] && { [ "$(hs_ts "$IFACE")" != "$HS0" ] \
             || [ $(( $(rx_bytes "$IFACE") - RX0 )) -gt $RX_ALIVE ]; }; then
            # Выздоровление -- ЛИБО новый хендшейк, ЛИБО заметный прирост rx.
            #
            # Одного прироста rx мало, и это стоило целого дня разбора: на
            # простаивающем телефоне за 45 с набегает всего ~6 КБ (хендшейки и
            # keepalive), порог в 8 КБ не берётся, и служба пересоздавала сокет
            # каждые 20 с бесконечно, сама же ломая исправный туннель. Замер на
            # 5000014556 20:30-20:34: три перехода подряд, в каждом хендшейк
            # проходил за ~15 с, входящих пакетов 37-54, и всё равно за 45 с
            # менялось по три порта источника.
            #
            # Новый хендшейк после пересоздания -- прямое доказательство, что
            # сервер узнал новый адрес и ответы доходят. Прирост rx оставлен
            # вторым признаком: он срабатывает раньше, когда трафик уже идёт.
            log "$IFACE: связь восстановлена с $TRY-й попытки"
            TRY=0; DEADLINE=0
        elif [ "$DEADLINE" != 0 ] && [ "$T" -ge "$DEADLINE" ] && [ -n "$NOW" ]; then
            # Повторяем, пока не поможет. Пересоздание сокета не ломает ни
            # маршрутов, ни правил netd, ни соединений поверх туннеля, поэтому
            # повторять его безопасно. Условие -n "$NOW": пока наружу нет
            # маршрута вовсе (самолётный режим), дёргать сокет незачем.
            TRY=$(( TRY + 1 ))
            log "$IFACE: связи нет, пересоздаю сокет ещё раз (попытка $TRY)"
            rebind "$IFACE"; LAST_REBIND=$T; DEADLINE=$(( T + RETRY_GAP ))
        elif [ "$DEADLINE" = 0 ]; then
            # Сторож на случай, когда интерфейс тот же, а связь всё равно встала.
            AGE=$(hs_ts "$IFACE")
            case "$AGE" in
                ''|0)
                    # Хендшейка не было ВОВСЕ -- туннель подняли уже на мёртвом
                    # канале. Раньше эта ветка молчала: сторож требовал
                    # существующего хендшейка и случай "связи не было с самого
                    # начала" не покрывал. Замер на 5000014556 09:13-09:31:
                    # туннель поднялся на LTE, rx остался 0 при tx в мегабайт,
                    # и служба за 18 минут не сделала ни одной попытки.
                    STALE=$(( T - NOHS_SINCE )) ;;
                *)
                    NOHS_SINCE=$T
                    STALE=$(( T - AGE )) ;;
            esac
            if [ "$STALE" -gt $HS_STALE ] && [ $(( T - LAST_REBIND )) -gt $REBIND_MIN_GAP ]; then
                log "$IFACE: хендшейка нет $STALE с, пересоздаю сокет"
                RX0=$(rx_bytes "$IFACE"); HS0=$AGE
                rebind "$IFACE"; LAST_REBIND=$T; TRY=1; DEADLINE=$(( T + RETRY_GAP )); NOHS_SINCE=$T
            fi
        fi

        [ -n "$NOW" ] && DEV="$NOW"
        sleep $STATUS_PERIOD
    done
    write_status
    ;;
*)
    echo "usage: $0 {up|down|refresh|status} [iface]" >&2; exit 2 ;;
esac
