/*
 * athena/LOS23.2: управление ядерным туннелем без root.
 *
 * Апстримный AwgQuickBackend ходит через RootShell, то есть требует su.
 * Нам это недоступно и не нужно: в system/sepolicy две железные стены,
 * которые закрывают путь «приложение само запускает awg/awg-quick»:
 *
 *   netd.te:205            neverallow { appdomain -network_stack } netd:binder call;
 *   app_neverallows.te:135 neverallow all_untrusted_apps *:{ ... netlink_generic_socket ... } *;
 *
 * Первая запрещает awg-quick (он настраивает DNS и маршруты через netd),
 * вторая — даже чтение состояния через `awg show`. Поэтому приложение не
 * выполняет ничего само, а делегирует привилегированному init-сервису:
 *
 *   поднять/опустить  -> setprop sys.amneziawg.iface <имя>; ctl.start amneziawg_{up,down}
 *   состояние         -> чтение /data/misc/amneziawg/status, который пишет сервис
 *   конфиги           -> приложение кладёт их прямо в /data/misc/amneziawg/<имя>.conf
 *                        (каталог с типом amneziawg_data_file, домену приложения
 *                         разрешена запись — это наш собственный тип, ничьих
 *                         neverallow он не задевает)
 */
package org.amnezia.awg.backend;

import android.util.Log;

import org.amnezia.awg.util.NonNullForAll;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

import androidx.annotation.Nullable;

@NonNullForAll
public final class ServiceControl {
    private static final String TAG = "AmneziaWG/ServiceControl";

    public static final File CONF_DIR = new File("/data/misc/amneziawg");
    private static final File STATUS_FILE = new File(CONF_DIR, "status");
    private static final File VERSION_FILE = new File("/sys/module/amneziawg/version");

    private static final String PROP_IFACE = "sys.amneziawg.iface";
    private static final String PROP_RESULT = "sys.amneziawg.result";
    private static final String CTL_START = "ctl.start";

    /** Сколько ждём, пока сервис отработает. awg-quick up с хендшейком укладывается в 10-15 с. */
    private static final long TIMEOUT_MS = 25_000;
    private static final long POLL_MS = 250;
    /** Сколько ждём завершения предыдущего запуска той же службы. */
    private static final long SERVICE_IDLE_WAIT_MS = 20_000;

    private static void setProp(final String key, final String value) throws IOException {
        try {
            final Class<?> sp = Class.forName("android.os.SystemProperties");
            sp.getMethod("set", String.class, String.class).invoke(null, key, value);
        } catch (final Exception e) {
            throw new IOException("SystemProperties.set(" + key + ") failed", e);
        }
    }

    private static String getProp(final String key) {
        try {
            final Class<?> sp = Class.forName("android.os.SystemProperties");
            final Object v = sp.getMethod("get", String.class, String.class).invoke(null, key, "");
            return v == null ? "" : (String) v;
        } catch (final Exception e) {
            return "";
        }
    }

    /** Конфиг туннеля там, где его ждёт awg-quick. */
    public void writeConfig(final String name, final String contents) throws IOException {
        final File conf = new File(CONF_DIR, name + ".conf");
        // Сначала удаляем: конфиг мог быть положен руками от root с режимом 0600,
        // и тогда открыть его на запись мы не сможем, хотя в каталог писать вправе.
        // noinspection ResultOfMethodCallIgnored
        conf.delete();
        try (final FileOutputStream out = new FileOutputStream(conf, false)) {
            out.write(contents.getBytes(StandardCharsets.UTF_8));
        }
    }

    public void deleteConfig(final String name) {
        // noinspection ResultOfMethodCallIgnored
        new File(CONF_DIR, name + ".conf").delete();
    }

    /**
     * Просит сервис поднять или опустить туннель и дожидается результата.
     * Сервис публикует код возврата в sys.amneziawg.result как "<iface>:<rc>".
     */
    public void setState(final String name, final boolean up) throws IOException {
        final String service = up ? "amneziawg_up" : "amneziawg_down";
        // Ждём, пока отработает предыдущий запуск этой же службы.
        //
        // init игнорирует ctl.start для сервиса, который уже выполняется, и
        // тогда ответа в sys.amneziawg.result не будет вовсе -- мы простаивали
        // все 25 секунд до таймаута и показывали ошибку, хотя туннель в этот
        // момент спокойно поднимался. Достаточно дождаться, пока
        // init.svc.<сервис> перестанет быть "running".
        awaitServiceIdle(service);
        setProp(PROP_RESULT, "");
        setProp(PROP_IFACE, name);
        setProp(CTL_START, service);

        final long deadline = System.currentTimeMillis() + TIMEOUT_MS;
        while (System.currentTimeMillis() < deadline) {
            final String r = getProp(PROP_RESULT);
            if (r.startsWith(name + ":")) {
                final String code = r.substring(name.length() + 1);
                if ("0".equals(code)) {
                    Log.i(TAG, "Tunnel " + name + (up ? " up" : " down") + " via service");
                    return;
                }
                throw new IOException("service " + service + " returned " + code);
            }
            try {
                Thread.sleep(POLL_MS);
            } catch (final InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IOException("interrupted while waiting for " + service, e);
            }
        }
        throw new IOException("timeout waiting for " + service);
    }

    /** Ждёт, пока init-сервис не окажется в состоянии, отличном от "running". */
    private static void awaitServiceIdle(final String service) {
        final long deadline = System.currentTimeMillis() + SERVICE_IDLE_WAIT_MS;
        while (System.currentTimeMillis() < deadline) {
            if (!"running".equals(getProp("init.svc." + service)))
                return;
            try {
                Thread.sleep(POLL_MS);
            } catch (final InterruptedException e) {
                Thread.currentThread().interrupt();
                return;
            }
        }
        Log.w(TAG, service + " is still running; starting it anyway");
    }

    /**
     * Пересоздать UDP-сокет туннеля -- лекарство от смены транспорта.
     *
     * Ядерный сокет привязан к сетевому контексту, в котором создан, и при
     * переходе wifi <-> мобильная сеть остаётся привязан к умершему. Измерено:
     * 120 с молчания, сброс эндпоинта не помогает, явная привязка к новой сети
     * меткой тоже. Помогает только пересоздание сокета -- туннель оживает за
     * секунду. Userspace-реализация делает ровно это сама в BindUpdate().
     *
     * Дешёвая операция: соединения поверх туннеля не рвутся, маршруты и
     * конфигурация netd не трогаются.
     */
    public void refresh(final String name) {
        try {
            setProp(PROP_RESULT, "");
            setProp(PROP_IFACE, name);
            setProp(CTL_START, "amneziawg_refresh");
            final long deadline = System.currentTimeMillis() + 10_000;
            while (System.currentTimeMillis() < deadline) {
                if (getProp(PROP_RESULT).startsWith(name + ":")) {
                    Log.i(TAG, "Socket rebound for " + name + " after network change");
                    return;
                }
                Thread.sleep(POLL_MS);
            }
            Log.w(TAG, "refresh timed out for " + name);
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (final Exception e) {
            Log.w(TAG, "refresh failed: " + e.getMessage());
        }
    }

    /** Содержимое `awg show all dump`, которое сервис обновляет, пока туннель поднят. */
    public List<String> status() {
        try {
            if (!STATUS_FILE.exists())
                return Collections.emptyList();
            return Files.readAllLines(STATUS_FILE.toPath(), StandardCharsets.UTF_8);
        } catch (final IOException e) {
            Log.w(TAG, "Unable to read status: " + e.getMessage());
            return Collections.emptyList();
        }
    }

    /** Имена поднятых интерфейсов -- первый столбец строк со сводкой по интерфейсу. */
    public List<String> runningInterfaces() {
        final List<String> names = new ArrayList<>();
        String current = null;
        for (final String line : status()) {
            final String[] parts = line.split("\\t");
            // `awg show all dump`: первая строка каждого интерфейса -- 5 полей,
            // строки пиров -- 9. Имя интерфейса идёт первым полем в обеих.
            if (parts.length >= 1 && !parts[0].isEmpty() && !parts[0].equals(current)) {
                current = parts[0];
                names.add(current);
            }
        }
        return names;
    }

    /** Строки `awg show all dump`, относящиеся к одному интерфейсу, без имени в начале. */
    public List<String> dumpFor(final String name) {
        final List<String> out = new ArrayList<>();
        for (final String line : status()) {
            final int tab = line.indexOf('\t');
            if (tab > 0 && line.substring(0, tab).equals(name))
                out.add(line.substring(tab + 1));
        }
        return out;
    }

    /** Версия модуля. /sys/module/amneziawg/version читается всеми, делегировать не нужно. */
    public String moduleVersion() {
        try {
            return Files.readAllLines(VERSION_FILE.toPath(), StandardCharsets.UTF_8)
                    .get(0).trim().toLowerCase(Locale.ENGLISH);
        } catch (final Exception e) {
            return "";
        }
    }
}
