/*
 * Copyright © 2017-2023 WireGuard LLC. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
package org.amnezia.awg

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.StrictMode
import android.os.StrictMode.ThreadPolicy
import android.os.StrictMode.VmPolicy
import android.util.Log
import androidx.appcompat.app.AppCompatDelegate
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStoreFile
import com.google.android.material.color.DynamicColors
import org.amnezia.awg.backend.Backend
import org.amnezia.awg.backend.AwgQuickBackend
import org.amnezia.awg.backend.ServiceControl
import org.amnezia.awg.configStore.FileConfigStore
import org.amnezia.awg.model.TunnelManager
import org.amnezia.awg.util.NetworkState
import org.amnezia.awg.util.NetworkType
import org.amnezia.awg.util.RootShell
import org.amnezia.awg.util.ToolsInstaller
import org.amnezia.awg.util.UserKnobs
import org.amnezia.awg.util.applicationScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.lang.ref.WeakReference
import java.util.Locale

class Application : android.app.Application() {
    private val futureBackend = CompletableDeferred<Backend>()
    private val coroutineScope = CoroutineScope(Job() + Dispatchers.Main.immediate)
    private var backend: Backend? = null
    private lateinit var rootShell: RootShell
    private lateinit var preferencesDataStore: DataStore<Preferences>
    private lateinit var toolsInstaller: ToolsInstaller
    private lateinit var tunnelManager: TunnelManager
    private lateinit var networkState: NetworkState

    override fun attachBaseContext(context: Context) {
        super.attachBaseContext(context)
        if (BuildConfig.MIN_SDK_VERSION > Build.VERSION.SDK_INT) {
            @Suppress("UnsafeImplicitIntentLaunch")
            val intent = Intent(Intent.ACTION_MAIN)
            intent.addCategory(Intent.CATEGORY_HOME)
            intent.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            System.exit(0)
        }
    }

    // athena: работаем только через ядро. Go-бэкенд из сборки выброшен вместе с
    // нативной частью (libwg-go.so в APK нет), поэтому откатываться некуда --
    // и не нужно: модуль amneziawg входит в прошивку и грузится при старте.
    // root не требуется: AwgQuickBackend делегирует всё init-сервису,
    // см. ServiceControl.
    private suspend fun determineBackend(): Backend {
        // Без модуля не падаем: аддон ставится на любую прошивку athena, и на
        // сборке без amneziawg.ko приложение должно открыться и при попытке
        // подключения показать «модуль не загружен», а не умереть на старте.
        // Службу об этом спросит сам бэкенд (код 3 в sys.amneziawg.result).
        if (!AwgQuickBackend.hasKernelSupport())
            Log.w(TAG, "kernel module amneziawg is not loaded; tunnels cannot be brought up on this ROM")
        // Реакция на смену сети -- в onNetworkChange(), через штатный NetworkState.
        val awgQuickBackend = AwgQuickBackend(applicationContext, ServiceControl())
        awgQuickBackend.setMultipleTunnels(UserKnobs.multipleTunnels.first())
        UserKnobs.multipleTunnels.onEach {
            awgQuickBackend.setMultipleTunnels(it)
        }.launchIn(coroutineScope)
        return awgQuickBackend
    }

    override fun onCreate() {
        Log.i(TAG, USER_AGENT)
        super.onCreate()
        DynamicColors.applyToActivitiesIfAvailable(this)
        rootShell = RootShell(applicationContext)
        toolsInstaller = ToolsInstaller(applicationContext, rootShell)
        preferencesDataStore = PreferenceDataStoreFactory.create { applicationContext.preferencesDataStoreFile("settings") }
        // athena: тема всегда тёмная, системную не слушаем.
        //
        // Экран построен по образцу AmneziaVPN (фон #0E0E11, кольцо #FBB26A), а
        // светлой темы у того нет вовсе. На светлой системной теме наш тёмный
        // фон соседствовал со светлой панелью приложения и светлой кнопкой
        // добавления -- видно на снимке с устройства 2026-09-09 08:51.
        // Апстримный переключатель темы (UserKnobs.darkTheme) вместе с
        // MODE_NIGHT_FOLLOW_SYSTEM поэтому убран.
        AppCompatDelegate.setDefaultNightMode(AppCompatDelegate.MODE_NIGHT_YES)
        tunnelManager = TunnelManager(FileConfigStore(applicationContext))
        tunnelManager.onCreate()

        // Initialize network state monitor for auto-reconnection
        networkState = NetworkState(applicationContext) { oldType, newType ->
            Log.i(TAG, "NetworkState callback: Network changed: $oldType -> $newType")
            onNetworkChange(oldType, newType)
        }

        coroutineScope.launch(Dispatchers.IO) {
            try {
                backend = determineBackend()
                futureBackend.complete(backend!!)
                networkState.bindNetworkListener()
            } catch (e: Throwable) {
                Log.e(TAG, Log.getStackTraceString(e))
            }
        }

        if (BuildConfig.DEBUG) {
            StrictMode.setVmPolicy(VmPolicy.Builder().detectAll().penaltyLog().build())
            StrictMode.setThreadPolicy(ThreadPolicy.Builder().detectAll().penaltyLog().build())
        }
    }

    override fun onTerminate() {
        networkState.unbindNetworkListener()
        coroutineScope.cancel()
        super.onTerminate()
    }

    /**
     * Called when network changes (e.g., WiFi to Mobile or vice versa).
     * Reconnects active tunnels to ensure VPN connection works on new network.
     */
    private fun onNetworkChange(oldType: NetworkType, newType: NetworkType) {
        Log.i(TAG, "onNetworkChange called: $oldType -> $newType")
        
        if (newType == NetworkType.NONE) {
            Log.i(TAG, "Network lost, waiting for new connection...")
            return
        }

        coroutineScope.launch {
            try {
                val activeTunnels = tunnelManager.getTunnels().filter { 
                    it.state == org.amnezia.awg.backend.Tunnel.State.UP 
                }

                if (activeTunnels.isEmpty()) {
                    Log.d(TAG, "No active tunnels, skipping reconnection")
                    return@launch
                }

                Log.i(TAG, "Reconnecting ${activeTunnels.size} tunnel(s) after network change: $oldType -> $newType")

                // athena: апстрим здесь гасил туннель и поднимал заново
                // (setStateAsync(DOWN), delay(500), setStateAsync(UP)).
                // Для ядерного туннеля это вредно и ненадёжно: замерено на
                // 5000014556 -- DOWN прошёл, UP до сервиса не дошёл вовсе, и
                // туннеля не было 85 секунд, пока его не подняли руками.
                //
                // Ядру достаточно пересоздать UDP-сокет: он привязан к сети, в
                // которой создан, и только это ему и нужно. Маршруты, правила
                // netd и конфигурация остаются на месте, соединения поверх
                // туннеля не рвутся. Проверено в поле: на переходе
                // wifi -> мобильная сеть 207 мс от пропажи wifi до пересоздания.
                for (tunnel in activeTunnels) {
                    try {
                        // athena: ничего не делаем. Пересоздание сокета и сброс
                        // состояния пиров выполняет служба amneziawg_status: она
                        // следит за интерфейсом, через который реально уходят
                        // пакеты туннеля, и потому ловит переход wifi -> LTE,
                        // который сюда вообще не приходит (NetworkState считает
                        // сеть после потери "начальной" и пропускает вызов).
                        // Дубль же давал два пересоздания подряд на возврате к wifi.
                        Log.i(TAG, "Network changed, tunnel ${tunnel.name} is handled by the service")
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to rebind ${tunnel.name}", e)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error during network change handling", e)
            }
        }
    }

    companion object {
        val USER_AGENT = String.format(Locale.ENGLISH, "AmneziaWG/%s (Android %d; %s; %s; %s %s; %s)", BuildConfig.VERSION_NAME, Build.VERSION.SDK_INT, if (Build.SUPPORTED_ABIS.isNotEmpty()) Build.SUPPORTED_ABIS[0] else "unknown ABI", Build.BOARD, Build.MANUFACTURER, Build.MODEL, Build.FINGERPRINT)
        private const val TAG = "AmneziaWG/Application"
        private lateinit var weakSelf: WeakReference<Application>

        fun get(): Application {
            return weakSelf.get()!!
        }

        suspend fun getBackend() = get().futureBackend.await()

        fun getRootShell() = get().rootShell

        fun getPreferencesDataStore() = get().preferencesDataStore

        fun getToolsInstaller() = get().toolsInstaller

        fun getTunnelManager() = get().tunnelManager

        fun getCoroutineScope() = get().coroutineScope

        fun getNetworkState() = get().networkState
    }

    init {
        weakSelf = WeakReference(this)
    }
}
