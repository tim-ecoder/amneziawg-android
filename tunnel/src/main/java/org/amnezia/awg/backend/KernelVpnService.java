/*
 * athena/LOS23.2: VpnService-оболочка над ядерным туннелем.
 *
 * Данные через этот сервис НЕ ходят: дескриптор tun держится открытым и никогда
 * не читается. Он нужен, чтобы система завела настоящую VPN-сеть: tunN с
 * адресом туннеля, правила по uid для списка приложений, DNS, unreachable для
 * IPv6, значок и always-on. Без неё приложения, выбирающие сеть явно (WebRTC в
 * звонках Telegram: BindSocketToNetwork), видели одну сотовую, к которой uid
 * под VPN привязаться не может, и звонок не собирал ни одного кандидата.
 * После establish() служба awg-tunnel.sh (ветка attach) переводит маршруты
 * таблицы tunN на awg0, и трафик идёт ядром.
 */
package org.amnezia.awg.backend;

import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import org.amnezia.awg.backend.BackendException.Reason;
import org.amnezia.awg.config.Config;
import org.amnezia.awg.config.InetNetwork;
import org.amnezia.awg.config.Peer;
import org.amnezia.awg.util.NonNullForAll;

import java.io.IOException;
import java.net.InetAddress;
import java.util.concurrent.CompletableFuture;

import androidx.annotation.Nullable;

@NonNullForAll
public final class KernelVpnService extends android.net.VpnService {
    private static final String TAG = "AmneziaWG/KernelVpnService";

    private static CompletableFuture<KernelVpnService> instance = new CompletableFuture<>();
    @Nullable private static Runnable revokeHandler;

    @Nullable private ParcelFileDescriptor tun;
    @Nullable private String session;

    static CompletableFuture<KernelVpnService> instance() {
        return instance;
    }

    /** Кого дёрнуть, если система отобрала VPN (другой VPN-клиент, выключение в настройках). */
    static void setRevokeHandler(@Nullable final Runnable handler) {
        revokeHandler = handler;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance.complete(this);
    }

    @Override
    public int onStartCommand(final Intent intent, final int flags, final int startId) {
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        closeTun();
        instance = new CompletableFuture<>();
        super.onDestroy();
    }

    @Override
    public void onRevoke() {
        Log.w(TAG, "VPN revoked by the system");
        closeTun();
        final Runnable handler = revokeHandler;
        if (handler != null)
            handler.run();
        stopSelf();
    }

    /** Поднимает VPN-сеть по конфигу туннеля. Дескриптор tun остаётся у нас и не читается. */
    synchronized void establish(final String name, final Config config) throws BackendException {
        closeTun();
        final Builder builder = new Builder();
        builder.setSession(name);

        for (final String app : config.getInterface().getExcludedApplications()) {
            try {
                builder.addDisallowedApplication(app);
            } catch (final PackageManager.NameNotFoundException e) {
                Log.w(TAG, "Excluded application not installed: " + app);
            }
        }
        for (final String app : config.getInterface().getIncludedApplications()) {
            try {
                builder.addAllowedApplication(app);
            } catch (final PackageManager.NameNotFoundException e) {
                Log.w(TAG, "Included application not installed: " + app);
            }
        }
        for (final InetNetwork addr : config.getInterface().getAddresses())
            builder.addAddress(addr.getAddress(), addr.getMask());
        for (final InetAddress dns : config.getInterface().getDnsServers())
            builder.addDnsServer(dns.getHostAddress());
        for (final String domain : config.getInterface().getDnsSearchDomains())
            builder.addSearchDomain(domain);
        // Маршруты -- ровно AllowedIPs. Семейство без единого маршрута (у нас IPv6)
        // система закрывает unreachable-маршрутом: allowFamily намеренно не зовём,
        // иначе v6 приложений из списка утекал бы мимо туннеля прямо в LTE.
        for (final Peer peer : config.getPeers())
            for (final InetNetwork route : peer.getAllowedIps())
                builder.addRoute(route.getAddress(), route.getMask());

        builder.setMtu(config.getInterface().getMtu().orElse(1280));
        builder.setMetered(false);
        builder.setBlocking(false);
        setUnderlyingNetworks(null);

        final ParcelFileDescriptor fd = builder.establish();
        if (fd == null)
            throw new BackendException(Reason.TUN_CREATION_ERROR);
        tun = fd;
        session = name;
        Log.i(TAG, "VPN network established for " + name);
    }

    synchronized boolean isEstablished() {
        return tun != null;
    }

    synchronized void closeTun() {
        if (tun != null) {
            try {
                tun.close();
            } catch (final IOException ignored) {
            }
            Log.i(TAG, "VPN network closed for " + session);
            tun = null;
            session = null;
        }
    }
}
