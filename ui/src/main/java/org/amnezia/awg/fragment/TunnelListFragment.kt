/*
 * Copyright © 2017-2023 WireGuard LLC. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
package org.amnezia.awg.fragment

import android.content.Intent
import android.content.res.Resources
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.view.animation.Animation
import android.view.animation.AnimationUtils
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.activity.addCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.view.ActionMode
import androidx.lifecycle.lifecycleScope
import com.google.android.material.snackbar.Snackbar
import com.google.zxing.qrcode.QRCodeReader
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import org.amnezia.awg.Application
import org.amnezia.awg.R
import org.amnezia.awg.activity.TunnelCreatorActivity
import org.amnezia.awg.databinding.ObservableKeyedRecyclerViewAdapter.RowConfigurationHandler
import org.amnezia.awg.databinding.TunnelListFragmentBinding
import org.amnezia.awg.databinding.TunnelListItemBinding
import androidx.databinding.Observable
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.model.ObservableTunnel
import org.amnezia.awg.util.ErrorMessages
import org.amnezia.awg.util.QrCodeFromFileScanner
import org.amnezia.awg.util.TunnelImporter
import org.amnezia.awg.widget.ConnectButton
import org.amnezia.awg.widget.MultiselectableRelativeLayout
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch

/**
 * Fragment containing a list of known AmneziaWG tunnels. It allows creating and deleting tunnels.
 */
class TunnelListFragment : BaseFragment() {
    private val actionModeListener = ActionModeListener()
    private var actionMode: ActionMode? = null
    private var backPressedCallback: OnBackPressedCallback? = null
    private var binding: TunnelListFragmentBinding? = null
    private var connectButtonCallback: Observable.OnPropertyChangedCallback? = null
    private var connectButtonTunnel: ObservableTunnel? = null
    private var buttonTunnel: ObservableTunnel? = null
    /**
     * Пока идёт наша операция, опрос не имеет права трогать кнопку.
     *
     * Файл состояния обновляется только по завершении up/down, поэтому опрос в
     * середине подъёма видит "выключено" и затирал выставленное нажатием
     * "подключение": на третьей секунде интерфейс уже есть, а кнопка снова
     * показывала Connect, и это выглядело как пропавшее нажатие.
     */
    @Volatile
    private var buttonBusy = false
    private val tunnelFileImportResultLauncher = registerForActivityResult(ActivityResultContracts.GetContent()) { data ->
        if (data == null) return@registerForActivityResult
        val activity = activity ?: return@registerForActivityResult
        val contentResolver = activity.contentResolver ?: return@registerForActivityResult
        activity.lifecycleScope.launch {
            if (QrCodeFromFileScanner.validContentType(contentResolver, data)) {
                try {
                    val qrCodeFromFileScanner = QrCodeFromFileScanner(contentResolver, QRCodeReader())
                    val result = qrCodeFromFileScanner.scan(data)
                    TunnelImporter.importTunnel(parentFragmentManager, result.text) { showSnackbar(it) }
                } catch (e: Exception) {
                    val error = ErrorMessages[e]
                    val message = Application.get().resources.getString(R.string.import_error, error)
                    Log.e(TAG, message, e)
                    showSnackbar(message)
                }
            } else {
                TunnelImporter.importTunnel(contentResolver, data) { showSnackbar(it) }
            }
        }
    }

    private val qrImportResultLauncher = registerForActivityResult(ScanContract()) { result ->
        val qrCode = result.contents
        val activity = activity
        if (qrCode != null && activity != null) {
            activity.lifecycleScope.launch { TunnelImporter.importTunnel(parentFragmentManager, qrCode) { showSnackbar(it) } }
        }
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        if (savedInstanceState != null) {
            val checkedItems = savedInstanceState.getIntegerArrayList(CHECKED_ITEMS)
            if (checkedItems != null) {
                for (i in checkedItems) actionModeListener.setItemChecked(i, true)
            }
        }
    }

    override fun onCreateView(
        inflater: LayoutInflater, container: ViewGroup?,
        savedInstanceState: Bundle?
    ): View? {
        super.onCreateView(inflater, container, savedInstanceState)
        binding = TunnelListFragmentBinding.inflate(inflater, container, false)
        val bottomSheet = AddTunnelsSheet()
        binding?.apply {
            createFab.setOnClickListener {
                if (childFragmentManager.findFragmentByTag("BOTTOM_SHEET") != null)
                    return@setOnClickListener
                childFragmentManager.setFragmentResultListener(AddTunnelsSheet.REQUEST_KEY_NEW_TUNNEL, viewLifecycleOwner) { _, bundle ->
                    when (bundle.getString(AddTunnelsSheet.REQUEST_METHOD)) {
                        AddTunnelsSheet.REQUEST_CREATE -> {
                            startActivity(Intent(requireActivity(), TunnelCreatorActivity::class.java))
                        }

                        AddTunnelsSheet.REQUEST_IMPORT -> {
                            tunnelFileImportResultLauncher.launch("*/*")
                        }

                        AddTunnelsSheet.REQUEST_SCAN -> {
                            qrImportResultLauncher.launch(
                                ScanOptions()
                                    .setOrientationLocked(false)
                                    .setBeepEnabled(false)
                                    .setPrompt(getString(R.string.qr_code_hint))
                            )
                        }
                    }
                }
                bottomSheet.showNow(childFragmentManager, "BOTTOM_SHEET")
            }
            executePendingBindings()
        }
        backPressedCallback = requireActivity().onBackPressedDispatcher.addCallback(this) { actionMode?.finish() }
        backPressedCallback?.isEnabled = false

        return binding?.root
    }


    /**
     * Круглая кнопка, выбор конфигурации и переход к её настройкам.
     *
     * Как в AmneziaVPN: сверху имя текущей конфигурации с возможностью
     * переключиться, в центре кнопка, под ней статистика и ссылка на настройки.
     * Строки списка остаются только когда туннелей больше одного.
     */
    private fun wireConnectButton() {
        val b = binding ?: return
        lifecycleScope.launch {
            val tunnels = Application.getTunnelManager().getTunnels()
            if (tunnels.isEmpty()) return@launch
            bindButtonTo(tunnels.firstOrNull { it.name == buttonTunnel?.name } ?: tunnels[0])

            b.tunnelSelector.setOnClickListener {
                lifecycleScope.launch {
                    val all = Application.getTunnelManager().getTunnels()
                    val names = all.map { it.name }.toTypedArray()
                    if (names.size < 2) {
                        // Переключать не из чего -- сразу открываем настройки.
                        selectedTunnel = buttonTunnel
                        return@launch
                    }
                    com.google.android.material.dialog.MaterialAlertDialogBuilder(requireContext())
                        .setTitle(R.string.connect_button_pick)
                        .setItems(names) { _, which -> bindButtonTo(all[which]) }
                        .show()
                }
            }
            b.configButton.setOnClickListener { selectedTunnel = buttonTunnel }

            // Один цикл на всё: состояние кнопки и строка под ней.
            //
            // Так же поступает штатный AmneziaVPN: Wireguard.launchStatusJob()
            // раз в секунду опрашивает время последнего хендшейка и только по
            // нему переводит состояние в "подключено". Колбэка модели тут мало --
            // после нажатия экран оставался в ложном "Connect" при уже поднятом
            // туннеле (снимок с 5000014556 10:01). Опрос через менеджер заодно
            // держит модель в согласии с бэкендом.
            viewLifecycleOwner.lifecycleScope.launch {
                while (isActive) {
                    val tunnel = buttonTunnel
                    if (tunnel != null && !buttonBusy) {
                        val state = runCatching { Application.getTunnelManager().getTunnelState(tunnel) }
                            .getOrDefault(tunnel.state)
                        val stats = if (state == Tunnel.State.UP)
                            runCatching { tunnel.getStatisticsAsync() }.getOrNull() else null
                        val handshake = stats?.let { st ->
                            st.peers().mapNotNull { st.peer(it)?.latestHandshakeEpochMillis }
                                .filter { it > 0 }.maxOrNull()
                        } ?: 0L

                        binding?.connectButton?.state = when {
                            state == Tunnel.State.UP && handshake > 0L -> ConnectButton.State.CONNECTED
                            // Интерфейс есть, рукопожатия ещё нет -- это и есть
                            // "подключение", а не "подключено".
                            state == Tunnel.State.UP -> ConnectButton.State.CONNECTING
                            state == Tunnel.State.TOGGLE -> ConnectButton.State.CONNECTING
                            else -> ConnectButton.State.DISCONNECTED
                        }
                        binding?.tunnelStats?.text = if (handshake == 0L || stats == null) {
                            getString(R.string.connect_button_stats_idle, tunnel.name)
                        } else {
                            getString(
                                R.string.connect_button_stats,
                                tunnel.name, (System.currentTimeMillis() - handshake) / 1000L,
                                android.text.format.Formatter.formatFileSize(requireContext(), stats.totalRx()),
                                android.text.format.Formatter.formatFileSize(requireContext(), stats.totalTx())
                            )
                        }
                    }
                    delay(2000)
                }
            }
        }
    }

    /** Привязывает кнопку и селектор к конкретному туннелю. */
    private fun bindButtonTo(tunnel: ObservableTunnel) {
        val b = binding ?: return
        connectButtonCallback?.let { cb -> connectButtonTunnel?.removeOnPropertyChangedCallback(cb) }
        buttonTunnel = tunnel
        b.tunnelSelector.text = getString(R.string.connect_button_selector, tunnel.name)

        fun refresh() {
            // Пока идёт наша операция, состояние кнопки держит она сама.
            // Колбэк модели прилетает и на смену статистики, а tunnel.state в
            // середине подъёма ещё DOWN, поэтому он затирал "подключение"
            // обратно в "Connect" (снимок 10:13, интерфейс уже поднят).
            if (buttonBusy) return
            b.connectButton.state = when (tunnel.state) {
                Tunnel.State.UP -> ConnectButton.State.CONNECTED
                Tunnel.State.TOGGLE -> ConnectButton.State.CONNECTING
                else -> ConnectButton.State.DISCONNECTED
            }
        }
        refresh()
        // Список туннелей приезжает раньше, чем менеджер выясняет их состояния,
        // поэтому tunnel.state в этот момент ещё DOWN, и кнопка на поднятом
        // туннеле показывала "Connect", а нажатие слало включение вместо
        // выключения. Спрашиваем состояние через менеджер: он опрашивает бэкенд
        // и сам обновляет модель. Трогать onStateChanged напрямую нельзя --
        // модель разъезжается с действительностью, и бэкенд начинает молча
        // отбрасывать команды, считая, что туннель уже в нужном состоянии.
        viewLifecycleOwner.lifecycleScope.launch {
            runCatching { Application.getTunnelManager().getTunnelState(tunnel) }
            refresh()
        }
        val callback = object : Observable.OnPropertyChangedCallback() {
            override fun onPropertyChanged(sender: Observable?, propertyId: Int) = refresh()
        }
        connectButtonCallback = callback
        connectButtonTunnel = tunnel
        tunnel.addOnPropertyChangedCallback(callback)

        b.connectButton.setOnClickListener {
            buttonBusy = true
            activity?.lifecycleScope?.launch {
                // Состояние сверяем перед решением: модель могла не успеть
                // обновиться, а команда "включить уже включённый" молча теряется.
                // Заодно только теперь известно направление, а значит и надпись:
                // при выключении это "Disconnecting", а не "Connecting".
                val current = runCatching { Application.getTunnelManager().getTunnelState(tunnel) }
                    .getOrDefault(tunnel.state)
                val up = current != Tunnel.State.UP
                b.connectButton.state =
                    if (up) ConnectButton.State.CONNECTING else ConnectButton.State.DISCONNECTING
                try {
                    tunnel.setStateAsync(Tunnel.State.of(up))
                } catch (e: Throwable) {
                    val ctx = activity ?: Application.get()
                    val message = ctx.getString(if (up) R.string.error_up else R.string.error_down, ErrorMessages[e])
                    // Пишем и в журнал: на экране сообщение живёт секунды, и
                    // разобрать задним числом, что именно отказало, было нечем.
                    Log.e(TAG, message, e)
                    showSnackbar(message)
                } finally {
                    buttonBusy = false
                }
                refresh()
            }
        }
    }

    override fun onDestroyView() {
        connectButtonCallback?.let { cb -> connectButtonTunnel?.removeOnPropertyChangedCallback(cb) }
        connectButtonCallback = null
        connectButtonTunnel = null
        binding = null
        super.onDestroyView()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putIntegerArrayList(CHECKED_ITEMS, actionModeListener.getCheckedItems())
    }

    override fun onSelectedTunnelChanged(oldTunnel: ObservableTunnel?, newTunnel: ObservableTunnel?) {
        binding ?: return
        lifecycleScope.launch {
            val tunnels = Application.getTunnelManager().getTunnels()
            if (newTunnel != null) viewForTunnel(newTunnel, tunnels)?.setSingleSelected(true)
            if (oldTunnel != null) viewForTunnel(oldTunnel, tunnels)?.setSingleSelected(false)
        }
    }

    private fun onTunnelDeletionFinished(count: Int, throwable: Throwable?) {
        val message: String
        val ctx = activity ?: Application.get()
        if (throwable == null) {
            message = ctx.resources.getQuantityString(R.plurals.delete_success, count, count)
        } else {
            val error = ErrorMessages[throwable]
            message = ctx.resources.getQuantityString(R.plurals.delete_error, count, count, error)
            Log.e(TAG, message, throwable)
        }
        showSnackbar(message)
    }

    override fun onViewStateRestored(savedInstanceState: Bundle?) {
        super.onViewStateRestored(savedInstanceState)
        binding ?: return
        binding!!.fragment = this
        lifecycleScope.launch { binding!!.tunnels = Application.getTunnelManager().getTunnels() }
        wireConnectButton()
        binding!!.rowConfigurationHandler = object : RowConfigurationHandler<TunnelListItemBinding, ObservableTunnel> {
            override fun onConfigureRow(binding: TunnelListItemBinding, item: ObservableTunnel, position: Int) {
                binding.fragment = this@TunnelListFragment
                binding.root.setOnClickListener {
                    if (actionMode == null) {
                        selectedTunnel = item
                    } else {
                        actionModeListener.toggleItemChecked(position)
                    }
                }
                binding.root.setOnLongClickListener {
                    actionModeListener.toggleItemChecked(position)
                    true
                }
                if (actionMode != null)
                    (binding.root as MultiselectableRelativeLayout).setMultiSelected(actionModeListener.checkedItems.contains(position))
                else
                    (binding.root as MultiselectableRelativeLayout).setSingleSelected(selectedTunnel == item)
            }
        }
    }

    private fun showSnackbar(message: CharSequence) {
        val binding = binding
        if (binding != null)
            Snackbar.make(binding.mainContainer, message, Snackbar.LENGTH_LONG)
                .setAnchorView(binding.createFab)
                .show()
        else
            Toast.makeText(activity ?: Application.get(), message, Toast.LENGTH_SHORT).show()
    }

    private fun viewForTunnel(tunnel: ObservableTunnel, tunnels: List<*>): MultiselectableRelativeLayout? {
        return binding?.tunnelList?.findViewHolderForAdapterPosition(tunnels.indexOf(tunnel))?.itemView as? MultiselectableRelativeLayout
    }

    private inner class ActionModeListener : ActionMode.Callback {
        val checkedItems: MutableCollection<Int> = HashSet()
        private var resources: Resources? = null

        fun getCheckedItems(): ArrayList<Int> {
            return ArrayList(checkedItems)
        }

        override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean {
            return when (item.itemId) {
                R.id.menu_action_delete -> {
                    val activity = activity ?: return true
                    val copyCheckedItems = HashSet(checkedItems)
                    binding?.createFab?.apply {
                        visibility = View.VISIBLE
                        scaleX = 1f
                        scaleY = 1f
                    }
                    activity.lifecycleScope.launch {
                        try {
                            val tunnels = Application.getTunnelManager().getTunnels()
                            val tunnelsToDelete = ArrayList<ObservableTunnel>()
                            for (position in copyCheckedItems) tunnelsToDelete.add(tunnels[position])
                            val futures = tunnelsToDelete.map { async(SupervisorJob()) { it.deleteAsync() } }
                            onTunnelDeletionFinished(futures.awaitAll().size, null)
                        } catch (e: Throwable) {
                            onTunnelDeletionFinished(0, e)
                        }
                    }
                    checkedItems.clear()
                    mode.finish()
                    true
                }

                R.id.menu_action_select_all -> {
                    lifecycleScope.launch {
                        val tunnels = Application.getTunnelManager().getTunnels()
                        for (i in 0 until tunnels.size) {
                            setItemChecked(i, true)
                        }
                    }
                    true
                }

                else -> false
            }
        }

        override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
            actionMode = mode
            backPressedCallback?.isEnabled = true
            if (activity != null) {
                resources = activity!!.resources
            }
            animateFab(binding?.createFab, false)
            mode.menuInflater.inflate(R.menu.tunnel_list_action_mode, menu)
            binding?.tunnelList?.adapter?.notifyDataSetChanged()
            return true
        }

        override fun onDestroyActionMode(mode: ActionMode) {
            actionMode = null
            backPressedCallback?.isEnabled = false
            resources = null
            animateFab(binding?.createFab, true)
            checkedItems.clear()
            binding?.tunnelList?.adapter?.notifyDataSetChanged()
        }

        override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
            updateTitle(mode)
            return false
        }

        fun setItemChecked(position: Int, checked: Boolean) {
            if (checked) {
                checkedItems.add(position)
            } else {
                checkedItems.remove(position)
            }
            val adapter = if (binding == null) null else binding!!.tunnelList.adapter
            if (actionMode == null && !checkedItems.isEmpty() && activity != null) {
                (activity as AppCompatActivity).startSupportActionMode(this)
            } else if (actionMode != null && checkedItems.isEmpty()) {
                actionMode!!.finish()
            }
            adapter?.notifyItemChanged(position)
            updateTitle(actionMode)
        }

        fun toggleItemChecked(position: Int) {
            setItemChecked(position, !checkedItems.contains(position))
        }

        private fun updateTitle(mode: ActionMode?) {
            if (mode == null) {
                return
            }
            val count = checkedItems.size
            if (count == 0) {
                mode.title = ""
            } else {
                mode.title = resources!!.getQuantityString(R.plurals.delete_title, count, count)
            }
        }

        private fun animateFab(view: View?, show: Boolean) {
            view ?: return
            val animation = AnimationUtils.loadAnimation(
                context, if (show) R.anim.scale_up else R.anim.scale_down
            )
            animation.setAnimationListener(object : Animation.AnimationListener {
                override fun onAnimationRepeat(animation: Animation?) {
                }

                override fun onAnimationEnd(animation: Animation?) {
                    if (!show) view.visibility = View.GONE
                }

                override fun onAnimationStart(animation: Animation?) {
                    if (show) view.visibility = View.VISIBLE
                }
            })
            view.startAnimation(animation)
        }
    }

    companion object {
        private const val CHECKED_ITEMS = "CHECKED_ITEMS"
        private const val TAG = "AmneziaWG/TunnelListFragment"
    }
}
