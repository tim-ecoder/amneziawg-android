# AmneziaWG in the kernel, on a BlackBerry KEY2

A fork of [amneziawg-android](https://github.com/amnezia-vpn/amneziawg-android)
whose tunnel is not a userspace process. The crypto runs in the **AmneziaWG
kernel module**, the interface is an ordinary netdev, and this app is the front
end for it. No root, no Magisk, SELinux enforcing.

Built for LineageOS 23.2 (Android 16) on the BlackBerry KEY2 (`athena`, SDM660,
4.19 kernel). Nothing here is device-specific in principle, but every measurement
below was taken on that phone.

## Why bother

The stock client carries the whole protocol in Go. Measured on the same phone,
the same config, the same server, downloading 20 MiB per run and counting busy
ticks in `/proc/stat`:

| | CPU-seconds per run | cost of the tunnel alone |
|---|---|---|
| kernel module | 3.74 | 0.117 CPU-s/MB |
| amneziawg-go | 4.85 | 0.171 CPU-s/MB |

**Go costs 45 % more** for the same bytes. Throughput is the same within noise
(7.4 vs 7.7 MB/s) -- eight cores mean neither implementation is the bottleneck.
Roaming is where the difference shows in practice: the kernel tunnel keeps
handshaking while the phone is in doze, because it does not depend on a process
Android is free to freeze.

## How the halves fit

```
app (this repo)                 privileged init service        kernel
  writes /data/misc/amneziawg/<iface>.conf
  setprop ctl.start amneziawg_up  ──▶  awg-tunnel.sh
                                        ip link add ... type amneziawg  ──▶  amneziawg.ko
                                        awg setconf, routes, netd
  reads sys.amneziawg.result  ◀──       setprop sys.amneziawg.result
  raises a VpnService shell so apps get a VPN network with a NetworkAgent
```

An app cannot do the privileged part itself, and not for want of trying: two
`neverallow` rules in `system/sepolicy` forbid an app domain from calling netd
over binder and from opening a generic netlink socket at all -- the second one
rules out even *reading* tunnel state. Upstream steps around them with `su`. We
delegate to an init service with `CAP_NET_ADMIN` and a domain of its own
instead, which is why this works on a locked-down build with no root.

The `VpnService` shell carries no data -- its descriptor is opened and never
read. It exists because WebRTC (Telegram calls, for one) enumerates networks
through `ConnectivityManager` and binds sockets to them explicitly; a netd-level
VPN network has no `NetworkAgent` and is invisible there. The service then moves
the routes of the system's `tunN` onto the kernel interface, so the datapath
stays in the kernel.

## What is in here

| path | what |
|---|---|
| `ui/`, `tunnel/` | the app. The Go backend and the native build are gone; `AwgQuickBackend` talks to the service through `ServiceControl` |
| `athena-rom/` | everything the ROM side needs: the service, its init.rc, the SELinux policy, the kernel-module patches, the tools build, and the addon recipe. Read its README first if you are porting this |
| `athena-rom/addon/` | scripts that build the sideload zip and its uninstaller |
| `athena-rom/tools/` | measurement scripts: tunnel quality, roaming, ping distribution |

The kernel module and the SELinux policy **cannot** ship in the addon: the
module is tied to its kernel by vermagic and symbol CRCs, and policy is compiled
into the images. Both come from the ROM build. The addon carries the userspace
half only, and refuses to be useful without a matching ROM.

## Building the app

```
$ ./gradlew :ui:assembleRelease
```

Java 21 and SDK 36; Gradle arrives with the wrapper. NDK and Go are not needed.
The APK **must** be signed with the platform key of the ROM it will run on --
without `seinfo=platform` the app does not get its SELinux domain and every
privileged call fails. `athena-rom/addon/build-addon.sh` then packs it into the
zip.

## Things that cost us a day each

* **Roaming is fixed by resetting the peers, not the socket.** Changing
  `listen-port` leaves the session alive, so nothing is sent and no handshake
  starts. `awg setconf` with `WGDEVICE_F_REPLACE_PEERS` behaves like a fresh
  device: 11 seconds to recover, against 10 for the stock client and 70 for the
  naive approach. Put `FwMark` back into the stripped config, or the tunnel's own
  packets route into the tunnel.
* **A watchdog must never destroy the tunnel it watches.** One `awg-quick down`
  that failed to come back up left the phone with no connectivity at all. The
  service only ever re-creates the socket; up and down come from the app.
* **Two tunnels sharing one peer key fight over the session.** The server keys
  its session by peer public key, so an idle second interface steals it every
  120 s and the working one goes deaf for 7-15 s at a time. 7.3 % packet loss
  became 0.1 % when the twin was removed.
* **You cannot measure a tunnel over an adb that runs through it.** The
  instrument becomes part of the system. Drive the phone from another one over
  USB.
* **A replaced system APK is not re-read.** The parser cache is keyed by the app
  directory's mtime, and recovery has no clock, so an install can never look
  newer. The addon stamps the directory with a date in 2100.

## Credit

Upstream app: [amnezia-vpn/amneziawg-android](https://github.com/amnezia-vpn/amneziawg-android),
GPL-2.0. Kernel module:
[amneziawg-linux-kernel-module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module).
Both are the work of the Amnezia project; this fork only moves the datapath into
the kernel and adds the ROM plumbing that makes it possible without root.
