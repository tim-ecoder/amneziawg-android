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
# Сеть для приложений даёт НЕ мы, а VpnService приложения (см. attach_vpn).
# С этим связана ветка devconfig: систему приходится просить не отбрасывать
# входящие пакеты на адрес VPN, пришедшие не с её собственного tun.
# Раньше awg-quick сам заводил VPN-сеть в netd (network create ... vpn 1) с
# правилами по uid. Такую сеть ConnectivityService не видит, и приложения,
# которые выбирают сеть явно (WebRTC в звонках Telegram: android_network_monitor
# BindSocketToNetwork), оставались с одной сотовой, к которой uid под VPN
# привязаться не может -- звонок не собирал ни одного кандидата. С VpnService
# система создаёт tunN, VPN-сеть, правила по uid, значок и unreachable для IPv6;
# наша часть -- перевести маршруты её таблицы с tunN на awg0, чтобы данные шли
# ядром, а не через дескриптор tun, который приложение никогда не читает.
#
# Роуминг wifi <-> мобильная сеть. Модуль сам сбрасывает кэш маршрута до пира
# раз в 5 с (socket.c, WG_ENDPOINT_CACHE_TTL), но ЭТОГО НЕ ДОСТАТОЧНО: замер на
# 5000014556 19:44-19:48 показал, что при неизменном listen-port туннель после
# ухода на LTE не ожил за 3.5 минуты (rx стоял, хендшейка нет 298 с), а
# пересоздание сокета подняло связь за 4 с. Поэтому пересоздание остаётся
# основным средством, и делает его слежение за исходящим путём в ветке status.
# Ветка refresh по событию из приложения убрана: NetworkState не видел переход
# wifi -> LTE вовсе, а на обратном давал второе пересоздание подряд.

DIR=/data/misc/amneziawg
STATUS=$DIR/status
TAG=awg-tunnel
# Отметка "флаг выставлен, но эта загрузка идёт ещё со старым значением".
NEEDS_REBOOT=$DIR/.ingress-filter-needs-reboot
# Флаг, отключающий фильтрацию входящих на адрес VPN (ветка devconfig).
DC_NS=tethering
DC_KEY=ingress_to_vpn_address_filtering
DC_VAL=-1

# Как часто обновлять файл состояния. Раньше цикл шёл раз в 2 с и запускал
# около десятка процессов за итерацию -- это стоило ~11% одного ядра постоянно
# (замер на 5000014556: 188 CPU-с за 1628 с). Теперь за итерацию три процесса.
STATUS_PERIOD=10
# Сторож на случай, когда интерфейс тот же, а связь встала: сменился адрес,
# оператор пересобрал NAT. При исправной связи хендшейк обновляется раз в ~120 с,
# поэтому 180 с без него -- уже не норма.
HS_STALE=180
REBIND_MIN_GAP=60
# Признак "отправляем, а в ответ тишина": если за окно ушло больше порога, а не
# пришло ни одного байта, туннель мёртв -- гадать не о чем. Два таких окна
# подряд, то есть 20 с, против 180 с у сторожа по возрасту хендшейка.
#
# Порог именно по tx, а не "rx == 0": на простое keepalive уходит в одну
# сторону и ответа не требует, поэтому какой-то tx без rx -- норма, и на нём
# признак обязан молчать.
#
# Величина взята из замера, а не на глаз (5000014556, 08:27-08:33, шаг 15 с):
# на простое keepalive даёт РОВНО 192 байта раз в 25 с, то есть в окно 10 с
# попадает одно значение, изредка два -- максимум 384 байта. Порог 512 выше
# этого потолка и при этом достаточно низкий для интерактивного обмена.
#
# Прежние 4096 были ошибкой и стоили ровно того случая, ради которого всё
# делалось: ввод в tmux по ssh через туннель замирал, а признак молчал.
# Нажатие клавиши -- это десятки байт, дальше TCP повторяет их с растущей
# паузой, и за 10 с набегает несколько сотен байт. До 4 КБ такой обмен не
# доходит никогда, поэтому срабатывал только сторож по хендшейку и пользователь
# ждал три минуты. Настоящий обрыв при этом виден сразу: эха нет вовсе, rx
# стоит ровно.
RX_STALL_TX=512
RX_STALL_STRIKES=2
# Шаг повторных попыток после смены сети и порог "связь ожила" по приросту rx.
# 12 с. Каждый новый порт -- новая попытка пробиться: замер на 5000014556
# (22:21-22:23) показал, что после ухода на LTE первые два порта молчали по
# 30+ с, а третий дал хендшейк за 8 с. При шаге 30 с восстановление занимало
# ~72 с, поэтому шаг укорочен -- лишние попытки теперь безопасны, потому что
# признак восстановления (новый хендшейк) работает и цикл сам останавливается.
# Раньше короткий шаг был опасен именно из-за сломанного признака.
RETRY_GAP=12
RX_ALIVE=8192
# Потолок шага повторных попыток. Шаг удваивается на каждой неудаче: пока сети
# нет по-настоящему (самолётный режим, метро, долгий разговор), дёргать сокет
# раз в 12 с -- это только расход батареи. Потолок 120 с выбран не наугад: без
# новых попыток ядро само переспрашивает хендшейк около 90 с
# (REKEY_ATTEMPT_TIME), и шаг больше этого оставил бы туннель совсем молчащим.
RETRY_MAX=120
# Сколько ждать после неразрушающего толчка, прежде чем ломать сессию.
NUDGE_WAIT=20
# Период опроса, когда пути наружу нет вовсе. Делать в этом состоянии нечего,
# а возврат сети мы всё равно заметим -- он выглядит как смена пути. Шесть
# итераций в минуту превращаются в одну.
IDLE_PERIOD=60

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

# Принятые и отправленные байты пира -- из того же файла состояния.
rx_bytes() { awk -F'\t' -v i="$1" '$1 == i && NF == 9 { print $7+0; exit }' "$STATUS" 2>/dev/null; }
tx_bytes() { awk -F'\t' -v i="$1" '$1 == i && NF == 9 { print $8+0; exit }' "$STATUS" 2>/dev/null; }

# Каким путём сейчас уходят наружу пакеты туннеля: интерфейс И адрес источника.
#
# Одного интерфейса мало, и это стоило зависшего туннеля на нестабильном LTE.
# Имя `rmnet_data1` переживает и пересборку PDP-контекста, и переход между
# сотами: интерфейс тот же, а адрес и NAT-трансляция у оператора уже новые.
# Смены сети при этом не видно, поэтому туннель молчал, пока не срабатывал
# сторож по возрасту хендшейка -- а тот ждёт HS_STALE, три минуты. Адрес
# источника меняется в тот же миг, что и путь, и ловится сразу.
outbound_path() {
    EP=$(awg show "$1" endpoints 2>/dev/null | head -1 | awk '{print $2}')
    # IPv4 -- "addr:port", IPv6 -- "[addr]:port". Простое ${EP%:*} для IPv6
    # оставляло "[addr]", ip route get его не понимал, путь наружу считался
    # потерянным навсегда, и ни одного пересоздания сокета не происходило.
    case "$EP" in
        ''|'(none)') return 1 ;;
        \[*\]:*) HOST=${EP#\[}; HOST=${HOST%%\]*} ;;
        *) HOST=${EP%:*} ;;
    esac
    MK=$(awg show "$1" fwmark 2>/dev/null); [ -n "$MK" ] || MK=0x20000
    ip route get "$HOST" mark "$MK" 2>/dev/null | head -1 | awk '{
        for (i = 1; i < NF; i++) {
            if ($i == "dev") dev = $(i + 1)
            if ($i == "src") src = $(i + 1)
        }
        if (dev != "") print dev " " src
    }'
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
# Значение ключа секции [Interface] конфига: conf_get <iface> <Key>.
conf_get() { awk -F'=' -v k="$2" '/^[[:space:]]*\[/ { sec = $0 } sec ~ /Interface/ && $1 ~ "^[[:space:]]*" k "[[:space:]]*$" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$DIR/$1.conf" 2>/dev/null; }

# Стрип конфига для `awg setconf`: strip_conf <iface> <выходной файл>.
# Свой, потому что `awg-quick strip` в андроидном порту тулзов не реализован.
# Выкидываем ключи, которые понимает только awg-quick, и ОБЯЗАТЕЛЬНО возвращаем
# FwMark: без него setconf обнулит метку, и пакеты туннеля начнут
# маршрутизироваться в него же самого. ListenPort выкидываем тоже: provoke
# зовётся сразу после rebind, и setconf с ListenPort из конфига вернул бы старый
# порт, отменив пересоздание сокета.
strip_conf() {
    MK=$(awg show "$1" fwmark 2>/dev/null); case "$MK" in ''|off|0) MK=0x20000 ;; esac
    awk -v mk="$MK" '
        /^[[:space:]]*\[Interface\]/ { print; print "FwMark = " mk; next }
        /^[[:space:]]*(Address|DNS|MTU|Table|ListenPort|PreUp|PostUp|PreDown|PostDown|SaveConfig|IncludedApplications|ExcludedApplications)[[:space:]]*=/ { next }
        { print }' "$DIR/$1.conf" > "$2" 2>/dev/null
    [ -s "$2" ]
}

# Правила iptables, которые ставил awg-quick: пропуск помеченных 0x20000
# пакетов самого туннеля и входящего UDP на его порт. Снимаются по комментарию.
iptables_add() {
    iptables -I OUTPUT 1 -m mark --mark 0x20000 -j ACCEPT -m comment --comment "amneziawg rule $1" 2>/dev/null
    ip6tables -I OUTPUT 1 -m mark --mark 0x20000 -j ACCEPT -m comment --comment "amneziawg rule $1" 2>/dev/null
    P=$(awg show "$1" listen-port 2>/dev/null)
    [ -n "$P" ] && iptables -I INPUT 1 -p udp --dport "$P" -j ACCEPT -m comment --comment "amneziawg rule $1" 2>/dev/null
}
iptables_cleanup() {
    # Удаляем той же спецификацией, что добавляли: разбирать вывод -S нельзя,
    # кавычки вокруг комментария в нём теряются.
    for T in iptables ip6tables; do
        while $T -D OUTPUT -m mark --mark 0x20000 -j ACCEPT -m comment --comment "amneziawg rule $1" 2>/dev/null; do :; done
        for P in $($T -S INPUT 2>/dev/null | grep -F -- "amneziawg rule $1" | sed -n 's/.*--dport \([0-9]*\).*/\1/p'); do
            while $T -D INPUT -p udp --dport "$P" -j ACCEPT -m comment --comment "amneziawg rule $1" 2>/dev/null; do :; done
        done
    done
}

# Неразрушающий толчок: nudge <iface>.
#
# Переключение persistent-keepalive через ноль заставляет модуль немедленно
# отправить keepalive (netlink.c: send_keepalive при переходе 0 -> ненулевое).
# Если сессия старше REKEY_AFTER_TIME, WireGuard на этом же пакете сам затевает
# новый хендшейк. Сессия при этом ЦЕЛА: ключи, счётчики и соединения поверх
# туннеля не трогаются, в отличие от provoke() с заменой пиров.
nudge() {
    for P in $(awg show "$1" peers 2>/dev/null); do
        K=$(awg show "$1" persistent-keepalive 2>/dev/null | awk -v p="$P" '$1 == p { print $2 }')
        case "$K" in ''|off|0) K=25 ;; esac
        awg set "$1" peer "$P" persistent-keepalive 0 2>/dev/null
        awg set "$1" peer "$P" persistent-keepalive "$K" 2>/dev/null
    done
}

provoke() {
    CONF="$DIR/$1.conf"
    STRIP="$DIR/.$1.strip"
    if [ -f "$CONF" ]; then
        if strip_conf "$1" "$STRIP" && awg setconf "$1" "$STRIP" 2>/dev/null; then
            log "$1: состояние пиров сброшено (setconf)"
            rm -f "$STRIP"
            return 0
        fi
        rm -f "$STRIP"
    fi
    # Запасной путь: тот же толчок, что и nudge -- keepalive через ноль даёт
    # немедленный хендшейк, но старую сессию не сбрасывает. Лучше, чем ничего,
    # когда конфига нет или setconf не прошёл.
    nudge "$1"
}

# --- слежение за одним интерфейсом: состояние между итерациями ---
#
# Переменные одной итерации: DEV, TRY, DEADLINE, RX0, HS0, LAST_REBIND, LOST,
# NOHS_SINCE, PREV_RX, PREV_TX, STALL, GAP. Между итерациями они лежат в
# <имя>_<ключ>, где ключ -- имя интерфейса с заменой всего, кроме букв и цифр,
# на "_".
watch_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

watch_load() {
    K=$(watch_key "$1")
    eval "DEV=\${DEV_$K:-}; TRY=\${TRY_$K:-0}; DEADLINE=\${DEADLINE_$K:-0}; \
          RX0=\${RX0_$K:-0}; HS0=\${HS0_$K:-}; LAST_REBIND=\${LAST_REBIND_$K:-0}; \
          LOST=\${LOST_$K:-0}; NOHS_SINCE=\${NOHS_SINCE_$K:-$2}; \
          PREV_RX=\${PREV_RX_$K:--1}; PREV_TX=\${PREV_TX_$K:--1}; \
          STALL=\${STALL_$K:-0}; GAP=\${GAP_$K:-$RETRY_GAP}; NUDGED=\${NUDGED_$K:-0}"
}

watch_save() {
    K=$(watch_key "$1")
    eval "DEV_$K=\$DEV; TRY_$K=\$TRY; DEADLINE_$K=\$DEADLINE; RX0_$K=\$RX0; \
          HS0_$K=\$HS0; LAST_REBIND_$K=\$LAST_REBIND; LOST_$K=\$LOST; NOHS_SINCE_$K=\$NOHS_SINCE; \
          PREV_RX_$K=\$PREV_RX; PREV_TX_$K=\$PREV_TX; STALL_$K=\$STALL; GAP_$K=\$GAP; NUDGED_$K=\$NUDGED"
}

# Одна итерация слежения за интерфейсом $1 в момент $2 (секунды).
watch_iter() {
    IFACE="$1"; T="$2"
    NOW=$(outbound_path "$IFACE")
    RXN=$(rx_bytes "$IFACE"); TXN=$(tx_bytes "$IFACE")
    [ -n "$RXN" ] || RXN=0; [ -n "$TXN" ] || TXN=0
    # Как скоро будить цикл в следующий раз. Пока всё обычно -- как раньше.
    WANT=$STATUS_PERIOD

    if [ -z "$NOW" ]; then
        # Маршрута наружу нет вовсе -- самолётный режим, провал LTE. Дёргать
        # сокет незачем, но возврат связи надо считать сменой сети.
        [ "$LOST" = 0 ] && log "$IFACE: пути наружу нет, жду"
        LOST=1
        STALL=0
        # Опрашиваем реже: пакету всё равно некуда идти, а возврат сети виден
        # как смена пути и заметится не позже чем через IDLE_PERIOD.
        [ "$DEADLINE" = 0 ] && WANT=$IDLE_PERIOD
    fi

    if [ -n "$NOW" ] && { { [ -n "$DEV" ] && [ "$NOW" != "$DEV" ]; } || [ "$LOST" = 1 ]; }; then
        log "$IFACE: сеть сменилась, ${DEV:-нет} -> $NOW, пересоздаю сокет"
        LOST=0
        RX0=$RXN; HS0=$(hs_ts "$IFACE"); STALL=0; GAP=$RETRY_GAP
        rebind "$IFACE"; LAST_REBIND=$T; TRY=1; DEADLINE=$(( T + GAP )); REBOUND=1
    elif [ "$DEADLINE" != 0 ] && { [ "$(hs_ts "$IFACE")" != "$HS0" ] \
         || [ $(( RXN - RX0 )) -gt $RX_ALIVE ]; }; then
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
        TRY=0; DEADLINE=0; GAP=$RETRY_GAP; STALL=0
    elif [ "$DEADLINE" != 0 ] && [ "$T" -ge "$DEADLINE" ] && [ -n "$NOW" ]; then
        # Повторяем, пока не поможет. Пересоздание сокета не ломает ни
        # маршрутов, ни правил netd, ни соединений поверх туннеля, поэтому
        # повторять его безопасно. Условие -n "$NOW": пока наружу нет
        # маршрута вовсе (самолётный режим), дёргать сокет незачем.
        TRY=$(( TRY + 1 ))
        # Шаг удваивается до потолка: первые попытки идут часто, а если сети нет
        # всерьёз -- переходим на редкие, чтобы не разряжать батарею впустую.
        GAP=$(( GAP * 2 )); [ "$GAP" -gt $RETRY_MAX ] && GAP=$RETRY_MAX
        log "$IFACE: связи нет, пересоздаю сокет ещё раз (попытка $TRY, следующая через $GAP с)"
        rebind "$IFACE"; LAST_REBIND=$T; DEADLINE=$(( T + GAP )); REBOUND=1
    elif [ "$DEADLINE" = 0 ] && [ -n "$NOW" ] && [ "$PREV_TX" -ge 0 ] \
         && [ $(( TXN - PREV_TX )) -ge $RX_STALL_TX ] && [ $(( RXN - PREV_RX )) -le 0 ]; then
        # Отправляем, а в ответ ничего. Считаем подряд идущие такие окна: одного
        # мало, ответ мог задержаться; два подряд -- это уже 20 с односторонней
        # связи, и туннель мёртв.
        STALL=$(( STALL + 1 ))
        if [ "$STALL" -ge $RX_STALL_STRIKES ]; then
            log "$IFACE: отправлено $(( TXN - PREV_TX )) Б, принято 0, окон подряд $STALL -- пересоздаю сокет"
            RX0=$RXN; HS0=$(hs_ts "$IFACE"); STALL=0; GAP=$RETRY_GAP
            rebind "$IFACE"; LAST_REBIND=$T; TRY=1; DEADLINE=$(( T + GAP )); REBOUND=1
        fi
    elif [ "$DEADLINE" = 0 ]; then
        STALL=0
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
        # Возраст хендшейка сам по себе НЕ повод ломать туннель.
        #
        # Замер (5000014556, 08:27-08:33) показал, что у здорового туннеля
        # хендшейк обновляется каждые 125 с и до порога не дотягивает. Но во сне
        # аппарата keepalive не уходит, обновлять хендшейк нечем, и на
        # пробуждении возраст всегда просрочен -- при полностью живой сессии.
        # Прежний сторож в этот момент сносил её через `setconf` с заменой
        # пиров: всё, что было в полёте, вставало до нового хендшейка, и
        # пользователь видел периодические замирания секунд на двадцать. Разбор
        # журнала за час: семь пересозданий, почти все по этой причине.
        #
        # WireGuard лечится сам -- на первом же отправленном пакете по сессии
        # старше 120 с он затевает новый хендшейк. Вмешиваться нужно, только
        # если его собственные попытки не проходят, а это видно по приёму: он
        # стоит ровно. Поэтому требуем ещё и отсутствия приёма.
        # Отличить живую сессию от мёртвой по счётчикам нельзя: сервер
        # keepalive не шлёт, приём стоит в обоих случаях (замер 08:27-08:33 --
        # rx двигался только в момент хендшейка). Поэтому сначала осторожный
        # толчок, и только если он не помог -- разрушающее пересоздание.
        if [ "$STALE" -le $HS_STALE ]; then
            NUDGED=0
        elif [ "$NUDGED" = 0 ]; then
            log "$IFACE: хендшейк стар ($STALE с), толкаю keepalive, сессию не трогаю"
            nudge "$IFACE"; NUDGED=$T
        elif [ $(( T - NUDGED )) -ge $NUDGE_WAIT ] && [ $(( T - LAST_REBIND )) -gt $REBIND_MIN_GAP ]; then
            log "$IFACE: толчок не помог за $(( T - NUDGED )) с (rx +$(( RXN - PREV_RX ))), пересоздаю сокет"
            RX0=$RXN; HS0=$AGE; GAP=$RETRY_GAP; NUDGED=0
            rebind "$IFACE"; LAST_REBIND=$T; TRY=1; DEADLINE=$(( T + GAP )); NOHS_SINCE=$T; REBOUND=1
        fi
    fi

    # Пока ждём восстановления -- поддерживаем повод для хендшейка. Именно
    # здесь, а не в начале итерации: там этот сброс успевал сработать за
    # мгновение до того, как проверка увидит уже вернувшуюся связь, и на
    # каждое переключение приходился лишний setconf. `rebind` зовёт
    # `provoke` сам, поэтому после него второй раз не нужно.
    # Пока ждём восстановления с большим шагом, будить цикл каждые 10 с незачем:
    # всё, что мы сделаем, -- сравним время. Просыпаемся вдвое чаще шага, чтобы
    # не проспать ни возврат сети, ни срок следующей попытки.
    if [ "$DEADLINE" != 0 ] && [ "$GAP" -gt $(( STATUS_PERIOD * 2 )) ]; then
        WANT=$(( GAP / 2 ))
        [ "$WANT" -gt $IDLE_PERIOD ] && WANT=$IDLE_PERIOD
    fi

    PREV_RX=$RXN; PREV_TX=$TXN
    [ -n "$NOW" ] && DEV="$NOW"
    return 0
}

# Приоритет нашего правила маршрутизации для подсети туннеля. Ниже правил netd
# для uid приложений (13000-17000), чтобы им ничего не менять, и выше общего
# правила «всё остальное в сеть по умолчанию».
OWN_RULE_PREF=17900

# Собственный адресный блок туннеля из AllowedIPs: own_subnet <iface>.
#
# Берём ровно тот префикс, внутрь которого попадает наш собственный адрес, и
# только если он не шире /16: широкие куски вроде 192.168.0.0/16 трогать нельзя,
# они увели бы в туннель локальную сеть.
own_subnet() {
    ADDR=$(conf_get "$1" Address | tr ',' ' ' | awk '{print $1}'); ADDR=${ADDR%/*}
    case "$ADDR" in ''|*:*) return 1 ;; esac
    # `awg show allowed-ips` печатает "<ключ>\t<префикс> <префикс> ...":
    # ключ отделён табуляцией, а сами префиксы -- пробелами.
    awg show "$1" allowed-ips 2>/dev/null | tr '\t, ' '\n\n\n' | awk -v a="$ADDR" '
        function ip2n(s,   p) { split(s, p, "."); return ((p[1]*256+p[2])*256+p[3])*256+p[4] }
        BEGIN { an = ip2n(a); best = 0 }
        /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {
            n = split($0, q, "/"); if (n != 2) next
            len = q[2] + 0
            if (len < 16 || len > 32) next
            blk = 2 ^ (32 - len)
            if (int(an / blk) == int(ip2n(q[1]) / blk) && len > best) { best = len; sel = $0 }
        }
        END { if (best) print sel }'
}

# Правило: подсеть туннеля доступна ВСЕМ uid, а не только приложениям из списка.
#
# Всё остальное живёт в таблице VPN-сети и достаётся по правилам netd для uid
# приложений. Для самого туннеля этого мало: adbd после `adb root` работает от
# uid 0, в список приложений root не входит и войти не может (у него нет
# пакета). Ответные пакеты уходили в обычную сеть с адресом 10.20.0.3 и
# терялись: на аппарате копились SYN_RECV, а SYN-ACK уходил в wlan0. Управление
# аппаратом по туннелю от root -- основной способ отладки, ломать его нельзя.
#
# Таблицу main для этого использовать бесполезно: на Android обычный трафик
# ходит по правилам netd, и в их списке main не встречается вовсе -- проверено,
# маршрут туда добавлялся, а `ip route get` от root всё равно выбирал wifi.
own_subnet_rule() {
    PFX=$(own_subnet "$1")
    while ip rule del pref $OWN_RULE_PREF 2>/dev/null; do :; done
    [ -n "$PFX" ] || { log "$1: своей подсети в allowed-ips нет, правило не добавлено"; return 0; }
    if ip rule add to "$PFX" lookup "$2" pref $OWN_RULE_PREF 2>/dev/null; then
        log "$1: $PFX через таблицу $2 для всех uid, включая root"
    else
        log "$1: не удалось добавить правило для $PFX"
    fi
}

# Привязка VPN-сети приложения к ядерному интерфейсу: attach_vpn <iface>.
#
# Приложение ПЕРЕД ctl.start amneziawg_up поднимает VpnService: система создаёт
# tunN с адресом туннеля, VPN-сеть, правила по uid, DNS и unreachable для IPv6,
# а маршруты таблицы tunN ведут в tunN. Переводим их на awg0 -- данные пойдут
# ядром, tunN остаётся пустой оболочкой: значок, список приложений, DNS,
# блокировка IPv6 и явный выбор сети приложениями (WebRTC в Telegram).
# tun ищем по адресу: у него тот же адрес, что и у нашего интерфейса.
attach_vpn() {
    ADDR=$(conf_get "$1" Address | tr ',' ' ' | awk '{print $1}'); ADDR=${ADDR%/*}
    [ -n "$ADDR" ] || { log "$1: нет Address в конфиге"; return 1; }
    TUN=$(ip -o -4 addr show to "$ADDR/32" 2>/dev/null | awk -v me="$1" '$2 != me { print $2; exit }')
    [ -n "$TUN" ] || { log "$1: VPN-сети с адресом $ADDR нет, приложениям туннель не виден"; return 1; }
    TABLE=$(awk -v t="$TUN" '$2 == t { print $1; exit }' /data/misc/net/rt_tables 2>/dev/null)
    [ -n "$TABLE" ] || { log "$1: у $TUN нет таблицы в rt_tables"; return 1; }
    N=0; FAIL=0
    for PFX in $(ip -4 route show table "$TABLE" 2>/dev/null | awk -v t="$TUN" '$2 == "dev" && $3 == t { print $1 }'); do
        [ "$PFX" = "$ADDR" ] && continue
        if ip route replace "$PFX" dev "$1" src "$ADDR" table "$TABLE" 2>/dev/null; then N=$((N+1)); else FAIL=$((FAIL+1)); fi
    done
    log "$1: маршруты $TUN (таблица $TABLE) переведены на $1: $N, ошибок $FAIL"
    own_subnet_rule "$1" "$TABLE"
    [ "$N" -gt 0 ] && [ "$FAIL" = 0 ]
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
    # Без awg-quick: он заводил в netd собственную VPN-сеть (network create,
    # users add, DNS через binder), а теперь сеть приложениям даёт VpnService
    # (см. attach). Нам остаётся сам интерфейс: создать, настроить, поднять.
    STRIP="$DIR/.$IFACE.strip"
    ip link add "$IFACE" type amneziawg 2>&1 | while read -r l; do log "$l"; done
    # Проверяем через ip, не через /sys/class/net: sysfs_net домену запрещён
    # (avc: denied { search } name="net" tcontext=sysfs_net).
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        log "не удалось создать $IFACE"; reply "$IFACE" 1; exit 1
    fi
    strip_conf "$IFACE" "$STRIP" && awg setconf "$IFACE" "$STRIP" 2>&1 | while read -r l; do log "$l"; done
    rm -f "$STRIP"
    case "$(awg show "$IFACE" public-key 2>/dev/null)" in
        ''|'(none)') log "awg setconf $IFACE не прошёл"; ip link del "$IFACE" 2>/dev/null; reply "$IFACE" 1; exit 1 ;;
    esac
    awg set "$IFACE" fwmark 0x20000 2>/dev/null
    # Адрес на awg0 НЕ ставим, он есть на tun у VpnService, и этого достаточно.
    #
    # Источник исходящим задают сами маршруты (`src` в attach_vpn), а входящие
    # доставляются потому, что Linux по умолчанию считает адрес локальным для
    # всей машины, а не для интерфейса, на который пакет пришёл. Порядок это
    # позволяет: приложение поднимает VpnService до того, как мы создаём awg0.
    #
    # Зачем убрано: два интерфейса с одним адресом -- аномалия, которой в
    # обычной системе не бывает, и её видит любое приложение через
    # NetworkInterface.getNetworkInterfaces() без единого разрешения. Именно на
    # ней банковские приложения ловили туннель, тогда как штатный AmneziaVPN,
    # у которого наружу торчит только tun0, они пропускали.
    MTU=$(conf_get "$IFACE" MTU); [ -n "$MTU" ] || MTU=1280
    ip link set dev "$IFACE" mtu "$MTU" up 2>&1 | while read -r l; do log "$l"; done
    iptables_add "$IFACE"
    if [ -f "$NEEDS_REBOOT" ]; then
        log "$IFACE: ВНИМАНИЕ -- фильтрация входящих на адрес VPN ещё включена,"
        log "$IFACE: приложениям трафик не пойдёт до перезагрузки (см. ветку devconfig)"
    fi
    if ip link show "$IFACE" 2>/dev/null | grep -q ',UP'; then
        # Оболочка VpnService к этому моменту уже поднята приложением; без неё
        # интерфейс жив, но приложениям не виден -- это ошибка, а не успех.
        if attach_vpn "$IFACE"; then
            write_status; start amneziawg_status; reply "$IFACE" 0
        else
            iptables_cleanup "$IFACE"; ip link del "$IFACE" 2>/dev/null; reply "$IFACE" 5
        fi
    else
        log "не удалось поднять $IFACE"; iptables_cleanup "$IFACE"; ip link del "$IFACE" 2>/dev/null; reply "$IFACE" 1
    fi
    ;;
devconfig)
    # Отключаем фильтрацию входящих пакетов на адрес VPN.
    #
    # Зачем. Android держит BPF-карту "адрес VPN -> разрешённый интерфейс"
    # (ingress_discard_map, netd.c) и отбрасывает пакеты на этот адрес, пришедшие
    # с другого интерфейса. Система записывает туда наш адрес и tunN, созданный
    # VpnService, а расшифрованные пакеты приходят с awg0 -- и все ответы
    # приложениям молча пропадают. Заметить трудно: от проверки освобождены
    # системные uid (netd.c: is_system_uid -> PASS), поэтому adb, ping и curl от
    # root работают, а Firefox и звонки Telegram висят.
    #
    # Штатный выключатель предусмотрен самим AOSP: ConnectivityService читает
    # флаг isFeatureNotChickenedOut(INGRESS_TO_VPN_ADDRESS_FILTERING), а рядом
    # в generateIngressDiscardRules стоит комментарий ровно про наш случай --
    # бывают VPN, которым нужно принимать пакеты на свой адрес с не-VPN
    # интерфейса. Значение -1 -- это FORCE_DISABLE_FEATURE_FLAG_VALUE
    # (DeviceConfigUtils.java).
    #
    # Цена: защита снимается для всех VPN на аппарате. Она мешает постороннему в
    # общей сети слать пакеты на ваш VPN-адрес. Обойтись без неё нельзя: типы
    # VPN, освобождённые от фильтрации (LEGACY, OEM), приложению не назначить, а
    # править frameworks/base мы себе запретили.
    #
    # Флаг читается ОДИН РАЗ при создании ConnectivityService, то есть действует
    # со следующей загрузки. Поэтому отмечаем файлом, что этой загрузке он ещё
    # не применён, -- ветка up об этом предупредит вместо молчаливого зависания.
    CUR=$(timeout 30 cmd device_config get "$DC_NS" "$DC_KEY" 2>/dev/null)
    if [ "$CUR" = "$DC_VAL" ]; then
        rm -f "$NEEDS_REBOOT"
        log "фильтрация входящих на адрес VPN отключена, флаг уже стоял"
        exit 0
    fi
    if timeout 30 cmd device_config put "$DC_NS" "$DC_KEY" "$DC_VAL" default 2>&1 | while read -r l; do log "$l"; done; [ "$(timeout 30 cmd device_config get "$DC_NS" "$DC_KEY" 2>/dev/null)" = "$DC_VAL" ]; then
        : > "$NEEDS_REBOOT"
        chmod 644 "$NEEDS_REBOOT" 2>/dev/null
        log "флаг $DC_NS/$DC_KEY выставлен в $DC_VAL; вступит в силу после перезагрузки"
    else
        log "не удалось выставить $DC_NS/$DC_KEY"
        exit 1
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
    # VpnService приложение уже остановило (tun и его таблица ушли вместе с ним);
    # нам остаются правила iptables и сам интерфейс.
    iptables_cleanup "$IFACE"
    while ip rule del pref $OWN_RULE_PREF 2>/dev/null; do :; done
    ip link del "$IFACE" 2>&1 | while read -r l; do log "$l"; done
    ip link show "$IFACE" >/dev/null 2>&1 && reply "$IFACE" 1 || reply "$IFACE" 0
    write_status
    # Если остались другие поднятые туннели, слежение возвращаем. Служба
    # сама перебирает все интерфейсы, имя из проперти ей не нужно.
    [ -n "$(awg show interfaces 2>/dev/null)" ] && start amneziawg_status
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
    # 1628 с). Здесь -- надёжный путь: сеть могла смениться, пока приложение
    # заморожено в doze.
    #
    # Следим за ВСЕМИ поднятыми интерфейсами, а не за одним из проперти.
    # sys.amneziawg.iface одна на всех, и при нескольких туннелях служба
    # после down получала имя только что снятого интерфейса: ждала маршрут для
    # несуществующего awg0, а живой awg1 оставался без присмотра. Состояние
    # каждого интерфейса хранится в переменных с суффиксом (см. watch_load /
    # watch_save), сам цикл один процесс.
    log "слежу за туннелями, период $STATUS_PERIOD с"
    while :; do
        write_status
        ALL=$(awg show interfaces 2>/dev/null)
        [ -n "$ALL" ] || break
        T=$(date +%s)
        # Спим столько, сколько просит самый нетерпеливый из интерфейсов.
        NEXT=$IDLE_PERIOD
        for IFACE in $ALL; do
            watch_load "$IFACE" "$T"
            watch_iter "$IFACE" "$T"
            watch_save "$IFACE"
            [ "$WANT" -lt "$NEXT" ] && NEXT=$WANT
        done
        sleep $NEXT
    done
    write_status
    ;;
*)
    echo "usage: $0 {up|down|status|devconfig} [iface]" >&2; exit 2 ;;
esac
