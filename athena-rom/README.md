# The ROM side

This app is only half of the thing. It has no VPN backend of its own: the tunnel
is a **kernel netdev** created by the AmneziaWG kernel module, and everything
privileged is done by an init service the app talks to through system
properties. That service, its SELinux domain, the module and the userspace tools
all live in the ROM, and they are collected here so the two halves can be read
together.

Everything below is written against LineageOS 23.2 (Android 16) on the
BlackBerry KEY2 (`athena`, SDM660) with a 4.19 kernel, in
`device/blackberry/sdm660-common`.

## Why the app cannot do this itself

Two `neverallow` rules in `system/sepolicy` shut the door on any app, root or
not:

```
netd.te:205             neverallow { appdomain -network_stack } netd:binder call
app_neverallows.te:135  neverallow all_untrusted_apps *:{ ... netlink_generic_socket ... } *
```

The first rules out `awg-quick`, which configures DNS and routes through netd.
The second rules out even *reading* tunnel state with `awg show`. Upstream steps
around both by running as root through `su`; there is no policy that lets an app
do it without one.

So the app writes a config file and sets a property; a privileged init service
does the work and answers in another property. The full protocol is in
`system_ext/bin/awg-tunnel.sh` and in `ServiceControl.java` on the app side.

## What goes where

| file here | destination in the device tree |
|---|---|
| `system_ext/bin/awg-tunnel.sh` | `system_ext/bin/`, copied by `common.mk` |
| `system_ext/etc/init/amneziawg.rc` | `system_ext/etc/init/` |
| `sepolicy/amneziawg.te`, `amneziawg_app.te`, `property_contexts` | `sepolicy/system_ext/private/` |
| `sepolicy/*.snippet` | merge into the existing `file_contexts` / `seapp_contexts` |
| `device-mk/*.snippet` | merge into `BoardConfigCommon.mk`, `common.mk`, `init/init.target.rc` |
| `device-mk/AmneziaWG-app-Android.bp` | `amneziawg/app/Android.bp`, next to the built APK |
| `kernel-module/*.patch` | applied to a checkout of `amneziawg-linux-kernel-module` under `amneziawg/kmod/` |
| `tools/` | `amneziawg/tools/`, built as two `cc_binary` |
| `addon/` | recipe for a sideload zip carrying only the userspace half |

## The kernel module

Built as an external kernel module against the same `KERNEL_OBJ` as the kernel
(`TARGET_KERNEL_EXT_MODULES`), never separately — otherwise vermagic and symbol
CRCs drift and the module either refuses to load or, worse, loads and breaks
later.

`01-build-on-athena-4.19.patch` makes it build on a 4.19 that already carries
the mainline `lib/crypto` backport: the module's own zinc crypto is dropped for
the kernel's (smaller module, and the ARM64 NEON paths come for free), and four
functions the compat layer backports are already present on a CIP kernel, while
`timer_delete_sync` and `DEV_STATS_INC` are not where it expects them.

`02-endpoint-cache-ttl.patch` drops the cached route to the peer every 5
seconds. Android switches networks with `ip rule`, which never invalidates a
cached dst, so packets keep leaving through the network that just died. **This
alone does not fix roaming** — see below — but without it the tunnel does not
follow the system's routing at all.

## The service, and the roaming logic worth knowing

`awg-tunnel.sh` is `up`, `down`, `refresh` and a `status` watcher. The watcher is
where the subtlety is, and every rule in it was paid for:

* **Recreating the UDP socket is not enough.** A live session has nothing to
  send, so no handshake starts and the tunnel sits mute — about 70 s to recover
  a wifi → LTE switch, often never. The stock AmneziaVPN client takes 10 s, and
  its logs say why: on a network change it tears the whole VPN device down and
  builds a new one (`tun1 → tun0`, counters back to zero), and a fresh
  wireguard-go handshakes immediately. `awg setconf` buys the same thing without
  `awg-quick down/up`, which once left a phone with no connectivity at all:
  replacing the peers drops keys, timers and the endpoint cache exactly like a
  new device, while the interface, the routes and netd's configuration stay
  untouched. Measured after the change: **11 s, first attempt**.
* **Strip the config yourself.** `awg-quick strip` does not exist in the Android
  port of the tools — a first attempt silently did nothing at all — and the
  stripped config **must** carry `FwMark` back, or `setconf` zeroes the mark and
  the tunnel's own packets get routed into the tunnel.
* **A network change is a change of address, not of interface name.** On
  unstable LTE `rmnet_data1` survives a PDP context rebuild and a cell handover:
  the name stays while the source address and the operator's NAT mapping are
  new, the session on the far side is dead, and a name-only check sees nothing.
  The tunnel then waited for the staleness watchdog — 180 s without a handshake
  — and looked hung for minutes. The watcher tracks the interface together with
  the source address `ip route get` reports, and treats a route that disappears
  and returns as a change even at the same address.
* **Recovery means a fresh handshake or real received bytes, not bytes alone.**
  An idle phone moves about 6 KB in 45 s, so a bytes-only threshold is never
  met: the watcher recreated the socket every 20 s forever, tearing down a
  tunnel that was working.
* **Watch a tunnel that never handshook.** `awg show` prints 0 for a peer that
  never had one, which a naive staleness check skips as "no data" — a tunnel
  brought up over a dead link then has nothing watching it. Seen running 18
  minutes with rx=0 against 1 MB sent and not one recovery attempt.
* **Stop the watcher before `awg-quick down`, not after.** awg-quick broadcasts a
  state refresh as it starts, the app re-reads the status file, and the watcher
  was busy writing the still-up interface back into it — so a moment after a
  clean disconnect the app believed the tunnel was up again.
* **10 s between status writes, not 2.** The old cadence spawned about ten
  processes per iteration and cost roughly 11% of one core for as long as the
  tunnel was up.

The status file is the app's only window into the tunnel, so the service strips
the private key and the preshared key out of it, and `post-fs-data` deletes it at
boot — otherwise the app believes a tunnel is up after a reboot and `restoreState`
does nothing.

## sepolicy

`system_ext`, not `vendor`: `awg-quick` configures DNS through a binder call to
netd and manages the network with `ndc`, and vendor domains are barred from netd
by neverallow. The policy builds with neverallows **enabled** — no
`SELINUX_IGNORE_NEVERALLOWS` — and the device runs with zero AVC denials.

Four things that cost a boot each:

1. `capabilities NET_ADMIN NET_RAW` in an init service **takes away every other
   capability**, including `DAC_OVERRIDE`. The config is written by the app, mode
   0600, so root could not read it and `awg-quick` reported "Unable to find
   configuration file" for a file that was plainly there.
2. `levelFrom=none` in `seapp_contexts`. With MLS categories the app writes as
   `s0:c…` into a directory at `s0`, and the service cannot read back what the
   app wrote.
3. `typeattribute amneziawg bpfdomain` — iptables reloads the chain together
   with netd's xt_bpf programs, and `allow ... bpfloader:bpf prog_run` alone is
   refused by `neverallow { domain -bpfdomain } *:bpf *`.
4. `init.svc.amneziawg_` needs its own label, or the app gets
   "Access denied finding property" and cannot tell whether the previous
   `ctl.start` has finished.

Also: `create_netlink_socket_perms` does not exist (use
`self:netlink_route_socket ~ioctl`, as `netutils_wrapper.te` does), there is no
`netd_socket` type at all (`ndc` speaks binder), and capabilities go through
`self:global_capability_class_set`.

## The addon zip

`addon/` is the recipe for a small sideload package carrying only the userspace
half — the tools, the service script, the init rc, the APK, and an `addon.d`
script so it survives an OTA. Useful because the phones here get about 1.4 MB/s
over wifi: three megabytes take seconds, a 1.4 GB ROM takes twenty-five minutes.

**The kernel module and the sepolicy cannot go in it.** The module is tied to the
kernel through vermagic and symbol CRCs; the policy is compiled into the images.
Both only ever arrive with a ROM build, so the addon is only meaningful on top of
a ROM built from this tree.

The ROM's `common.mk` therefore carries none of it: `device-mk/common.mk.snippet`
is a comment saying where the userspace half went and which two lines bring it
back into the image.

Three things the zip needs beyond its payload. `META-INF/com/android/metadata.pb`,
without which the LineageOS Updater's importer throws before installing
anything. A `post-timestamp` no older than the installed ROM's `ro.build.date.utc`
in both `metadata` and `metadata.pb` — `InstallUtils.getBlockedReason` calls
anything older a DOWNGRADE and refuses it, so the metadata is copied out of the
ROM the phone is running (minus its `ota-property-files` line, whose offsets
belong to that zip) rather than kept from an older build. And current mtimes on
the files — recovery restores the timestamps
from the zip (2008), and PackageManager then decides the APK is not newer and
never re-scans it. And if the app was ever installed with `adb install`, that
copy shadows the system one: `pm uninstall -k <pkg>` for **all** users, not just
`--user 0`, is what hands control back to the ROM's copy.
