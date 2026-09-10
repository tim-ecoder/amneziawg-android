/*
 * Copyright © 2017-2023 WireGuard LLC. All Rights Reserved.
 * SPDX-License-Identifier: Apache-2.0
 */
package org.amnezia.awg.fragment

import android.content.Context
import android.util.Log
import android.view.View
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.databinding.DataBindingUtil
import androidx.databinding.ViewDataBinding
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.google.android.material.snackbar.Snackbar
import org.amnezia.awg.Application
import org.amnezia.awg.R
import org.amnezia.awg.activity.BaseActivity
import org.amnezia.awg.activity.BaseActivity.OnSelectedTunnelChangedListener
import org.amnezia.awg.backend.Tunnel
import org.amnezia.awg.databinding.TunnelDetailFragmentBinding
import org.amnezia.awg.databinding.TunnelListItemBinding
import org.amnezia.awg.model.ObservableTunnel
import org.amnezia.awg.util.ErrorMessages
import kotlinx.coroutines.launch

/**
 * Base class for fragments that need to know the currently-selected tunnel. Only does anything when
 * attached to a `BaseActivity`.
 */
abstract class BaseFragment : Fragment(), OnSelectedTunnelChangedListener {
    private var pendingTunnel: ObservableTunnel? = null
    private var pendingTunnelUp: Boolean? = null
    private var pendingAction: (() -> Unit)? = null
    private val permissionActivityResultLauncher = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        val action = pendingAction
        pendingAction = null
        if (action != null) {
            action()
            return@registerForActivityResult
        }
        val tunnel = pendingTunnel
        val checked = pendingTunnelUp
        if (tunnel != null && checked != null)
            setTunnelStateWithPermissionsResult(tunnel, checked)
        pendingTunnel = null
        pendingTunnelUp = null
    }

    /**
     * Просит у системы согласие на VPN, если его ещё нет.
     *
     * Возвращает true, если согласие уже есть и действие можно делать сразу;
     * false -- если показан системный диалог, и действие выполнится само, когда
     * человек ответит.
     *
     * Нужно и в ядерном режиме: датапас у нас в ядре, но поверх него поднимается
     * оболочка VpnService (KernelVpnService), а её без согласия система не
     * запускает -- служба отвечает "VPN service not authorized by user".
     */
    protected fun ensureVpnPermission(action: () -> Unit): Boolean {
        val activity = activity ?: return true
        val intent = try {
            android.net.VpnService.prepare(activity)
        } catch (e: Throwable) {
            Log.e(TAG, activity.getString(R.string.error_prepare, ErrorMessages[e]), e)
            null
        }
        if (intent == null) return true
        pendingAction = action
        permissionActivityResultLauncher.launch(intent)
        return false
    }

    protected var selectedTunnel: ObservableTunnel?
        get() = (activity as? BaseActivity)?.selectedTunnel
        protected set(tunnel) {
            (activity as? BaseActivity)?.selectedTunnel = tunnel
        }

    override fun onAttach(context: Context) {
        super.onAttach(context)
        (activity as? BaseActivity)?.addOnSelectedTunnelChangedListener(this)
    }

    override fun onDetach() {
        (activity as? BaseActivity)?.removeOnSelectedTunnelChangedListener(this)
        super.onDetach()
    }

    // open: список переопределяет его, чтобы кнопка показывала ход операции,
    // начатой переключателем в строке (см. TunnelListFragment).
    open fun setTunnelState(view: View, checked: Boolean) {
        val tunnel = when (val binding = DataBindingUtil.findBinding<ViewDataBinding>(view)) {
            is TunnelDetailFragmentBinding -> binding.tunnel
            is TunnelListItemBinding -> binding.item
            else -> return
        } ?: return
        val activity = activity ?: return
        activity.lifecycleScope.launch {
            // Апстрим спрашивает согласие только у go-бэкенда. Нам оно нужно и в
            // ядерном режиме: туннель ядерный, но VPN-сеть приложениям даёт
            // оболочка VpnService, и без согласия она не поднимается.
            if (checked) {
                try {
                    val intent = android.net.VpnService.prepare(activity)
                    if (intent != null) {
                        pendingTunnel = tunnel
                        pendingTunnelUp = checked
                        permissionActivityResultLauncher.launch(intent)
                        return@launch
                    }
                } catch (e: Throwable) {
                    val message = activity.getString(R.string.error_prepare, ErrorMessages[e])
                    Snackbar.make(view, message, Snackbar.LENGTH_LONG)
                        .setAnchorView(view.findViewById(R.id.create_fab))
                        .show()
                    Log.e(TAG, message, e)
                }
            }
            setTunnelStateWithPermissionsResult(tunnel, checked)
        }
    }

    private fun setTunnelStateWithPermissionsResult(tunnel: ObservableTunnel, checked: Boolean) {
        val activity = activity ?: return
        activity.lifecycleScope.launch {
            try {
                tunnel.setStateAsync(Tunnel.State.of(checked))
            } catch (e: Throwable) {
                val error = ErrorMessages[e]
                val messageResId = if (checked) R.string.error_up else R.string.error_down
                val message = activity.getString(messageResId, error)
                val view = view
                if (view != null)
                    Snackbar.make(view, message, Snackbar.LENGTH_LONG)
                        .setAnchorView(view.findViewById(R.id.create_fab))
                        .show()
                else
                    Toast.makeText(activity, message, Toast.LENGTH_LONG).show()
                Log.e(TAG, message, e)
            }
        }
    }

    companion object {
        private const val TAG = "AmneziaWG/BaseFragment"
    }
}
