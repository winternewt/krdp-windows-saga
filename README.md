# krdp + Windows Remote Desktop on Debian 13 (trixie)

Patches, a build script and fixes for making KDE's RDP server (**krdp 6.3.5**, Plasma 6.3) work well with the built-in Windows Remote Desktop client (**mstsc.exe**) on Debian 13 trixie and derivatives such as MX Linux 25.

Starting state: login rejected, black screen, "protocol error", no keyboard, about a second of lag, grey blacks.
End state: GPU-decoded H.264 on the Windows side, no lag, correct colors, working keyboard.

If you run Plasma **6.7 or newer**, most of this is fixed upstream (see [What's fixed where](#whats-fixed-where)). This repo is for people on Debian stable.

The full story is in [`article/`](article/).

## Find your symptom

Look in `journalctl --user -u app-org.kde.krdpserver.service` (krdp), and in the full user journal for the portal and KWin.

| Symptom | Log signature | Cause | Fix |
|---|---|---|---|
| Login fails at once | `requestPassword: Failed to read password of "<user>" because of error: 1`, then `Could not find user in SAM database` | krdp stores user passwords in KWallet, and they're missing (lost wallet, renamed account, new install) | Remove the user in System Settings → Remote Desktop and add it again with a password |
| Login fails ("authenticity" or credentials error) | `Message Integrity Check (MIC) verification failed!` / `SEC_E_MESSAGE_ALTERED` | Password mismatch: often old credentials saved in Windows | Delete the saved `TERMSRV/<host>` credential on Windows and type the password |
| Black screen; works only while someone clicks something on the server's own screen | `xdp-kde-remotedesktop: MegaAuth: Failed to lookup permissions: "No entry for remote-desktop"` | The portal permission for krdp is missing, so a hidden "Allow?" dialog waits on the physical screen | [Restore the permission](#portal-permission) |
| Black screen with a cursor, then "Because of a protocol error, this session will be disconnected" | `[libx264] MB rate (32400000) > level limit` / `profile Constrained Baseline, level 6.2` | kpipewire labels the stream H.264 level 6.2 and Windows' GPU decoder rejects it | **kpipewire patch** `local_x264-h264-level.patch`. Common workaround: turn off hardware decoding in the Windows client (see below), but that causes lag |
| Mouse works, keyboard doesn't (or types garbage: Backspace prints `5`) | Portal debug shows `NotifyKeyboardKeycode` with `state: 0` only | Debian's FreeRDP 3 port of krdp 6.3.5 treats every key as a release and shifts keycodes by 8 | **krdp patch** `local_keyboard-press-uses-release-flag.patch` (backport of upstream `0fcf4e51`) |
| About 1 s lag on everything | Thousands of `suspend frame ack` | krdp's frame-rate logic collapses to 1–5 fps with Windows clients | **krdp patch** `local_disable-rtt-framerate-heuristic.patch` (upstream removed it in `978f1cb7`) |
| Lag that builds up (0.2–1 s); server socket queue empty | `ss -tni` shows Send-Q 0 and low RTT, krdp CPU is moderate | Windows decodes 4K in software (hardware decoding off) and falls behind | Fix the level (above) and turn Windows' hardware decoding back on |
| Grey blacks, washed-out contrast | Measure a dark pixel: e.g. RGB (35,38,39) shows as (46,48,51) on the client | Limited-range video shown unexpanded by mstsc | **kpipewire patch** `local_x264-color-matrix-range.patch` plus the [full-range drop-in](#color-range) |
| Black screen after restarting krdp or the portal | `kwin_screencast: "<output>" Stream error: no more input formats` | Seen once, after restarting the portal and krdp in quick succession; cause not identified | Restart krdp once more: `systemctl --user restart app-org.kde.krdpserver.service` |
| Quality slider has no effect | `[libx264] -qscale is ignored, -crf is recommended.` | kpipewire passes quality in a form x264 ignores | **kpipewire patch** `upstream_88ad0577_998cfa1e_x264-crf.patch` |

## What's fixed where

**krdp** (`krdp/patches/`), applied on top of Debian's `6.3.5-1`:

| Patch | Upstream | What it does |
|---|---|---|
| `local_keyboard-press-uses-release-flag.patch` | [`0fcf4e51`](https://invent.kde.org/plasma/krdp/-/commit/0fcf4e51) (part) | Key press vs release from `KBD_FLAGS_RELEASE`; no `- 8` keycode offset under FreeRDP 3 |
| `upstream_d736d8a3_backport.patch` | [`d736d8a3`](https://invent.kde.org/plasma/krdp/-/commit/d736d8a3) | Handle mstsc sending its graphics capabilities twice |
| `upstream_433babfe_backport.patch` | [`433babfe`](https://invent.kde.org/plasma/krdp/-/commit/433babfe) | Scroll wheel with high-resolution wheels and touchpads |
| `upstream_cc67efe6_backport.patch` | [`cc67efe6`](https://invent.kde.org/plasma/krdp/-/commit/cc67efe6) | Thread-safety fixes in the video stream |
| `upstream_59763161_backport.patch` | [`59763161`](https://invent.kde.org/plasma/krdp/-/commit/59763161) | Portal session close: crash and leak |
| `upstream_231bec4e_backport.patch` | [`231bec4e`](https://invent.kde.org/plasma/krdp/-/commit/231bec4e) | Possible hang when a connection closes |
| `local_disable-rtt-framerate-heuristic.patch` | equivalent of [`978f1cb7`](https://invent.kde.org/plasma/krdp/-/commit/978f1cb7) | Turns off the RTT × frame-delay frame-rate logic |
| `upstream_d399708d_backport.patch` | [`d399708d`](https://invent.kde.org/plasma/krdp/-/commit/d399708d) | Clear the send queue at each key frame |
| `local_small-encoder-queue.patch` | similar in spirit to [`d3b06515`](https://invent.kde.org/plasma/krdp/-/commit/d3b06515) | Keep kpipewire's pre-encode queue at 3 frames instead of up to a second |

**kpipewire** (`kpipewire/patches/`), applied on top of Debian's `6.3.6-1`. kpipewire is the encoding library; it's also Spectacle's screen-recording backend.

| Patch | Upstream | What it does |
|---|---|---|
| `upstream_859a3ce9_backport.patch` | [`859a3ce9`](https://invent.kde.org/plasma/kpipewire/-/commit/859a3ce9) | Even-size rounding fix |
| `upstream_88ad0577_998cfa1e_x264-crf.patch` | [`88ad0577`](https://invent.kde.org/plasma/kpipewire/-/commit/88ad0577) + [`998cfa1e`](https://invent.kde.org/plasma/kpipewire/-/commit/998cfa1e) | Quality slider works (CRF 17–28 instead of an ignored `global_quality`) |
| `local_x264-h264-level.patch` | not fixed upstream; [KDE bug 526199](https://bugs.kde.org/show_bug.cgi?id=526199) | Real frame rate plus level 5.1, so hardware decoders accept the stream |
| `local_x264-color-matrix-range.patch` | not fixed upstream; [KDE bug 526795](https://bugs.kde.org/show_bug.cgi?id=526795) | Explicit BT.709 matrix and range, tagged in the stream; `KPIPEWIRE_X264_RANGE=full\|limited`, `KPIPEWIRE_X264_MATRIX=bt709\|bt601` |

Upstream's own full-range fix ([`cb00651a`](https://invent.kde.org/plasma/kpipewire/-/commit/cb00651a), for [bug 507015](https://bugs.kde.org/show_bug.cgi?id=507015)) has no effect for the software encoders: they build their filter graph in the constructor, before the range is set (bug 526795, found by reading the code). The local patch here doesn't depend on it.

Plasma 6.7+ also avoids the black screen in a different way: it falls back to the RemoteFX "progressive" codec when H.264 fails ([KDE bug 502333](https://bugs.kde.org/show_bug.cgi?id=502333), [krdp MR 165](https://invent.kde.org/plasma/krdp/-/merge_requests/165)).

## Build and install

```bash
# once: enable deb-src for trixie (Types: deb deb-src in /etc/apt/sources.list.d/debian.sources), then
sudo apt update
sudo apt build-dep krdp

./build.sh krdp
sudo dpkg -i build-krdp/krdp_*+local1_amd64.deb
systemctl --user daemon-reload
systemctl --user restart app-org.kde.krdpserver.service
```

kpipewire works the same way. Install every package it builds in one go, so the shared libraries match:

```bash
sudo apt build-dep kpipewire
./build.sh kpipewire
# install only the packages you already have (check with: dpkg -l | grep -i pipewire | grep kde)
sudo dpkg -i build-kpipewire/{libkpipewire6,libkpipewire-data,libkpipewire-dev,libkpipewiredmabuf6,libkpipewirerecord6,qml6-module-org-kde-pipewire}_*+local1_*.deb
systemctl --user restart app-org.kde.krdpserver.service
```

Back up the stock packages first (`apt download libkpipewire6 libkpipewire-data …`) so you can go back with `dpkg -i`.

Set `DEBFULLNAME` and `DEBEMAIL` if you want your own name in the package changelog.

Packages are versioned `<debian version>+local1`. That sorts **above** Debian stable updates such as `6.3.5-1+deb13u1`, so apt won't replace your build with one, and you won't notice a security update either. Before upgrading, check `apt-cache policy krdp`. If the candidate changes, rebuild with this repo on top of the new version.

To undo: `sudo apt install --reinstall krdp=6.3.5-1`.

## Setup notes

### Portal permission

krdp needs a stored permission so the desktop portal doesn't ask on the physical screen:

```bash
gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
  --object-path /org/freedesktop/impl/portal/PermissionStore \
  --method org.freedesktop.impl.portal.PermissionStore.SetPermission \
  kde-authorized true remote-desktop org.kde.krdpserver "['yes']"
```

(`flatpak permission-set kde-authorized remote-desktop org.kde.krdpserver yes` does the same if flatpak is installed.)

### Color range

mstsc displays limited-range H.264 without expanding it to full range, so black (16) shows as dark grey. With the kpipewire patch, ask for full range **for krdp only**, so screen recordings keep the standard limited range:

```bash
mkdir -p ~/.config/systemd/user/app-org.kde.krdpserver.service.d
cp config/systemd/app-org.kde.krdpserver.service.d/color-range.conf \
   ~/.config/systemd/user/app-org.kde.krdpserver.service.d/
systemctl --user daemon-reload
systemctl --user restart app-org.kde.krdpserver.service
```

Check it with a known dark color: Konsole's Breeze background (35,38,39) should measure the same on the client, not (46,48,51). That's 16 + 35 × 219/255 ≈ 46, the signature of limited range shown as full.

### Clipboard images (optional)

krdp 6.3 doesn't sync the clipboard. If you use [CrossPaste](https://github.com/CrossPaste/crosspaste-desktop) instead, it reads the X11 clipboard through Xwayland, and on Plasma 6.3 Wayland images copied in native apps never reach it ([CrossPaste #5167](https://github.com/CrossPaste/crosspaste-desktop/issues/5167)). `clipboard-bridge/` copies Wayland clipboard images into X11. It needs `wl-clipboard` and `xclip`:

```bash
install -m755 clipboard-bridge/wl-x11-image-bridge ~/.local/bin/
cp clipboard-bridge/wl-x11-image-bridge.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now wl-x11-image-bridge
```

Separately, Spectacle 6.3's auto-copy is flaky on Wayland ([KDE bug 500366](https://bugs.kde.org/show_bug.cgi?id=500366)). If a screenshot won't paste, select it in Klipper's history.

### Windows side

- Use the user name exactly as configured in krdp, without a `DOMAIN\` prefix.
- **Hardware decoding:** the commonly suggested Group Policy "Turn off hardware-accelerated decoding" makes the picture appear with an unpatched kpipewire, at the cost of lag. Windows has **two similarly named Remote Desktop policy folders that both contain client settings**, and the policy is in only one of them; search gpedit for "hardware-accelerated decoding". With the kpipewire level patch, leave the policy **Not configured**.

## License

Scripts and config in this repository: MIT (see `LICENSE`). Patches are derived from krdp and kpipewire and keep the licenses of the files they modify: mainly LGPL-2.1-only OR LGPL-3.0-only OR a later version accepted by KDE e.V. (see each package's `debian/copyright`).
