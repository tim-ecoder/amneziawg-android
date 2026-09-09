/*
 * Copyright © 2017-2023 WireGuard LLC. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 */

package org.amnezia.awg.backend;

import android.content.Context;
import android.util.Log;
import android.util.Pair;

import org.amnezia.awg.backend.BackendException.Reason;
import org.amnezia.awg.backend.Tunnel.State;
import org.amnezia.awg.util.RootShell;
import org.amnezia.awg.util.ToolsInstaller;
import org.amnezia.awg.config.Config;
import org.amnezia.awg.crypto.Key;
import org.amnezia.awg.util.NonNullForAll;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;

import androidx.annotation.Nullable;

/**
 * Implementation of {@link Backend} that uses the kernel module and {@code awg-quick} to provide
 * AmneziaWG tunnels.
 */

@NonNullForAll
public final class AwgQuickBackend implements Backend {
    private static final String TAG = "AmneziaWG/AwgQuickBackend";
    // athena: вместо RootShell/ToolsInstaller -- делегирование init-сервису,
    // см. ServiceControl. Конфиг пишется сразу в /data/misc/amneziawg,
    // временный каталог в кеше приложения больше не нужен.
    private final ServiceControl service;
    private final Map<Tunnel, Config> runningConfigs = new HashMap<>();
    private boolean multipleTunnels;
    @Nullable private Thread statusThread;
    @Nullable private StatusCallback statusCallback;
    @Nullable private Tunnel currentTunnel;

    public AwgQuickBackend(final Context context, final ServiceControl service) {
        this.service = service;
    }

    public static boolean hasKernelSupport() {
        return new File("/sys/module/amneziawg").exists();
    }

    @Override
    public Set<String> getRunningTunnelNames() {
        // Состояние берём из файла, который поддерживает сервис: приложению
        // запрещён netlink_generic (app_neverallows.te:135), само спросить ядро оно не может.
        try {
            return Set.copyOf(service.runningInterfaces());
        } catch (final Exception e) {
            Log.w(TAG, "Unable to enumerate running tunnels", e);
            return Collections.emptySet();
        }
    }

    @Override
    public State getState(final Tunnel tunnel) {
        return getRunningTunnelNames().contains(tunnel.getName()) ? State.UP : State.DOWN;
    }

    @Override
    public long getLastHandshake(final Tunnel tunnel) {
        if (getState(tunnel) != State.UP) {
            return -3; // Tunnel not active
        }
        // Апстрим разбирал вывод `awg show <iface> latest-handshakes` -- две колонки,
        // ключ и время. Мы отдаём строки `dump`, где второе поле это preshared key,
        // поэтому индекс другой. Строка пира в dump -- ровно 8 полей:
        // pubkey, psk, endpoint, allowed-ips, latest-handshake, rx, tx, keepalive.
        final Collection<String> output = service.dumpFor(tunnel.getName());
        for (final String line : output) {
            final String[] parts = line.split("\\t");
            if (parts.length != 8)
                continue;
            try {
                return Long.parseLong(parts[4]);
            } catch (final NumberFormatException ignored) {
                Log.e(TAG, "Failed to parse handshake time");
                return -2;
            }
        }
        Log.e(TAG, "No handshake time found");
        return -1;
    }

    /**
     * Set a callback to be notified when connection status changes.
     *
     * @param callback The callback to invoke on status change
     */
    public void setStatusCallback(@Nullable final StatusCallback callback) {
        this.statusCallback = callback;
    }

    /**
     * Launch a background thread to poll handshake status and determine connection state.
     * This is called after tunnel creation to wait for the first successful handshake.
     */
    private void launchStatusJob() {
        stopStatusJob();
        Log.d(TAG, "Launch status job");
        statusThread = new Thread(() -> {
            while (!Thread.currentThread().isInterrupted()) {
                final long lastHandshake = getLastHandshake(currentTunnel);

                // Check if tunnel is no longer active (race condition protection)
                if (lastHandshake == -3L) {
                    Log.d(TAG, "Tunnel is no longer active, stopping status job");
                    break;
                }

                // 0 means no handshake yet, wait and retry
                if (lastHandshake == 0L) {
                    try {
                        Thread.sleep(1000);
                    } catch (final InterruptedException e) {
                        Thread.currentThread().interrupt();
                        break;
                    }
                    continue;
                }

                // Only positive handshake time indicates successful connection
                // -1 may be returned if unable to parse output (doesn't mean no connection)
                // -2 indicates command execution error (also doesn't mean no connection)
                if (lastHandshake > 0L) {
                    if (statusCallback != null) {
                        statusCallback.onStatusChanged(true);
                    }
                    break;
                }

                // For -1 or -2, retry after delay instead of reporting disconnected
                try {
                    Thread.sleep(1000);
                } catch (final InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
            statusThread = null;
        }, "StatusJob");
        statusThread.start();
    }

    /**
     * Stop the status polling thread if running.
     */
    private void stopStatusJob() {
        if (statusThread != null) {
            statusThread.interrupt();
            statusThread = null;
        }
    }

    @Override
    public Statistics getStatistics(final Tunnel tunnel) {
        final Statistics stats = new Statistics();
        final Collection<String> output = service.dumpFor(tunnel.getName());
        for (final String line : output) {
            final String[] parts = line.split("\\t");
            if (parts.length != 8)
                continue;
            try {
                stats.add(Key.fromBase64(parts[0]), Long.parseLong(parts[5]), Long.parseLong(parts[6]), Long.parseLong(parts[4]) * 1000);
            } catch (final Exception ignored) {
            }
        }
        return stats;
    }

    @Override
    public String getVersion() throws Exception {
        final String version = service.moduleVersion();
        if (version.isEmpty())
            throw new BackendException(Reason.UNKNOWN_KERNEL_MODULE_NAME);
        return version;
    }

    public void setMultipleTunnels(final boolean on) {
        multipleTunnels = on;
    }

    @Override
    public State setState(final Tunnel tunnel, State state, @Nullable final Config config) throws Exception {
        final State originalState = getState(tunnel);
        final Config originalConfig = runningConfigs.get(tunnel);
        final Map<Tunnel, Config> runningConfigsSnapshot = new HashMap<>(runningConfigs);

        if (state == State.TOGGLE)
            state = originalState == State.UP ? State.DOWN : State.UP;
        if ((state == State.UP && originalState == State.UP && originalConfig != null && originalConfig == config) ||
                (state == State.DOWN && originalState == State.DOWN))
            return originalState;
        if (state == State.UP) {
            if (!multipleTunnels && originalState == State.DOWN) {
                final List<Pair<Tunnel, Config>> rewind = new LinkedList<>();
                try {
                    for (final Map.Entry<Tunnel, Config> entry : runningConfigsSnapshot.entrySet()) {
                        setStateInternal(entry.getKey(), entry.getValue(), State.DOWN);
                        rewind.add(Pair.create(entry.getKey(), entry.getValue()));
                    }
                } catch (final Exception e) {
                    try {
                        for (final Pair<Tunnel, Config> entry : rewind) {
                            setStateInternal(entry.first, entry.second, State.UP);
                        }
                    } catch (final Exception ignored) {
                    }
                    throw e;
                }
            }
            if (originalState == State.UP)
                setStateInternal(tunnel, originalConfig == null ? config : originalConfig, State.DOWN);
            try {
                setStateInternal(tunnel, config, State.UP);
            } catch (final Exception e) {
                try {
                    if (originalState == State.UP && originalConfig != null) {
                        setStateInternal(tunnel, originalConfig, State.UP);
                    }
                    if (!multipleTunnels && originalState == State.DOWN) {
                        for (final Map.Entry<Tunnel, Config> entry : runningConfigsSnapshot.entrySet()) {
                            setStateInternal(entry.getKey(), entry.getValue(), State.UP);
                        }
                    }
                } catch (final Exception ignored) {
                }
                throw e;
            }
        } else if (state == State.DOWN) {
            setStateInternal(tunnel, originalConfig == null ? config : originalConfig, State.DOWN);
        }
        return state;
    }

    private void setStateInternal(final Tunnel tunnel, @Nullable final Config config, final State state) throws Exception {
        Log.i(TAG, "Bringing tunnel " + tunnel.getName() + ' ' + state);

        Objects.requireNonNull(config, "Trying to set state up with a null config");

        final String name = tunnel.getName();
        try {
            if (state == State.UP)
                service.writeConfig(name, config.toAwgQuickString());
            service.setState(name, state == State.UP);
        } catch (final Exception e) {
            Log.e(TAG, "Service refused to bring tunnel " + name + ' ' + state, e);
            throw new BackendException(Reason.AWG_QUICK_CONFIG_ERROR_CODE, -1);
        } finally {
            if (state == State.DOWN)
                service.deleteConfig(name);
        }

        if (state == State.UP) {
            runningConfigs.put(tunnel, config);
            currentTunnel = tunnel;
            launchStatusJob();
        } else {
            stopStatusJob();
            runningConfigs.remove(tunnel);
            currentTunnel = null;
        }

        tunnel.onStateChange(state);
    }
}
