# Seven bugs between Windows Remote Desktop and my KDE desktop

*How I got KDE's RDP server working properly with the Windows client on Debian stable: two patched packages, two upstream bug reports, and one stubborn grey.*

I wanted something simple: sit at a Windows 10 laptop and use my Linux desktop through the Remote Desktop client every Windows machine already has. The desktop runs Debian 13 (MX Linux 25) with Plasma 6.3 on Wayland, and KDE ships an RDP server for exactly this, **krdp**. Turn it on in System Settings, connect, done.

It took a day. Seven separate problems were stacked on top of each other, each hiding the next. Most were already fixed upstream in newer Plasma versions, which Debian stable doesn't have. Two weren't fixed anywhere. This is the story, with the log lines to search for, because nearly every one of these failures shows up as either "black screen" or "something went wrong".

The patches, a build script and a symptom table are at **[repo link]**.

*A note on method: I did this with an AI coding assistant (Claude Code) driving the terminal: reading logs, diffing upstream commits, building packages. I ran the tests and made the calls. It's still very much the Linux tradition of fixing it yourself, except I didn't have to type the patches.*

---

## 1. "An unspecified error": the passwords were gone

The first attempt failed at login with a vague Windows error. krdp's log was clearer:

```
requestPassword: Failed to read password of "<user>" because of error: 1
[NTLM] ntlm_fetch_ntlm_v2_hash: Could not find user in SAM database
```

krdp keeps its user list in its config file but the **passwords in KWallet**. The night before, I had renamed my Linux account and restored my home directory. The config file came back; the wallet entries didn't. krdp loaded a list of users with no passwords, and every login was "user not found".

**Fix:** delete the users in System Settings → Remote Desktop and add them again. For a while I also had `Message Integrity Check (MIC) verification failed` in the log, which in practice means "wrong password". Windows was reusing an old saved credential.

## 2. A black screen that only worked while I was watching

Once logged in, I got a black screen. Sometimes it worked, and it always worked while I was also connected through Sunshine/Moonlight, a game-streaming tool I run on the same machine. That was the clue, but it took a while to see it:

```
xdp-kde-remotedesktop: MegaAuth: Failed to lookup permissions: "No entry for remote-desktop"
```

On Wayland, krdp has to ask the **desktop portal** for permission to capture the screen and inject input. Normally a permanent "yes" is stored, so it never asks. Mine was gone, also lost in the account rename. So every RDP session opened an **"Allow remote control?" dialog on the physical monitor** and waited. When I was connected through Sunshine, I could see the dialog and click it. Without Sunshine, nobody could.

**Fix:** restore the stored permission (`kde-authorized / remote-desktop / org.kde.krdpserver = yes`; the exact command is in the repo). After that the portal answered in 70 ms with no dialog.

Two things were lost in one account rename (the passwords and the portal permission), and neither produced a clear error.

## 3. "Because of a protocol error, this session will be disconnected"

Next: black screen, a mouse cursor, and the Windows client hanging up after half a second with a "protocol error". The server log showed something odd:

```
[libx264] MB rate (32400000) > level limit (16711680)
[libx264] profile Constrained Baseline, level 6.2, 4:2:0, 8-bit
```

H.264 streams carry a **level**, a declaration of how demanding they are to decode. Level 6.2 means "8K at 120 fps class". Hardware decoders don't go that high, so Windows' GPU decoder rejects the stream and the client gives up.

Why 6.2 for a 4K desktop? kpipewire, KDE's screen-encoding library, gives x264 a time base of 1/1000 s and no frame rate, so x264 assumes **1000 frames per second**. 4K is 32,400 macroblocks per frame; × 1000 = the "MB rate 32,400,000" in the log.

The fix forum guides recommend is to turn off hardware decoding in the Windows client through Group Policy. Windows has *two* similarly named Remote Desktop policy folders that both contain client settings, and the setting is in only one of them. With that on, I got a picture. It also turned out to be the cause of problem 6.

## 4. Mouse yes, keyboard no, then the wrong keys

With a picture, the mouse worked but keystrokes did nothing. With the portal's debug logging on, the cause was visible:

```
NotifyKeyboardKeycode … state: 0
NotifyKeyboardKeycode … state: 0
```

64 key events, **all releases, no presses**. A key that's only ever released never types anything.

Debian's krdp 6.3.5 carries an early draft of upstream's port to FreeRDP 3, and that draft missed a change. It decided "pressed" from a flag (`KBD_FLAGS_DOWN`) that the Windows client doesn't set on a fresh key press. Upstream had fixed it in the final port (commit `0fcf4e51`) by checking `KBD_FLAGS_RELEASE` instead. I backported that, and keys arrived, but as garbage: Backspace printed "5". The same port also subtracted 8 from every keycode, an old X11 habit, which FreeRDP 3 no longer needs. Backspace (14) became 6, which is the "5" key. With both changes from the upstream commit, typing worked, in English and Russian.

This one is a plain Debian stable bug: anyone using krdp 6.3.5 from trixie with a Windows client can't type.

## 5. Everything a second late

Now everything worked, about a second late: typing, scrolling, moving the mouse. Two candidates were ruled out first:

- **Not the network.** The RDP socket had nothing queued (Send-Q 0), a 3 ms round trip, and hundreds of megabits per second available.
- **Not the encoder backing up.** kpipewire logs when it drops frames, and it never did.

But krdp was logging `suspend frame ack` thousands of times: **6,746** in one session. The Windows client was telling the server "I'll stop acknowledging frames". krdp 6.3 sets its frame rate from round-trip time × unacknowledged frames, and with acknowledgements suspended that number blows up. The requested frame rate collapses to 1–5 fps, so every screen change waits up to a second.

Upstream had found the same thing and deleted that logic ("collapses the requested rate to 1–5 fps even when there is no real send-side pressure", commit `978f1cb7`). Disabling it, plus two small queue fixes, brought the lag down to a fraction of a second.

## 6. The lag that kept building

The remaining lag grew over time, from 0.2 s up to about a second. With the server's queues provably empty (krdp delivered every frame immediately), the only place left was the client: Windows was decoding 4K H.264 **in software**, because of the workaround from problem 3, and couldn't keep up.

So the real fix was problem 3's root cause. I patched kpipewire to give x264 the real frame rate and cap the level at 5.1, which covers 4K frame sizes. Then I turned Windows' hardware decoding **back on**:

| | Before | After |
|---|---|---|
| H.264 level | 6.2 | 5.1 |
| Windows decoding | software | GPU |
| `suspend frame ack` per session | 6,746 | 5 |
| Lag | 0.2–1 s, growing | none |

The suspended acknowledgements were never really a network signal. The software decoder was saying it couldn't keep up.

The level bug turned out to be known: [KDE bug 526199](https://bugs.kde.org/show_bug.cgi?id=526199), filed two weeks earlier for a different client. Upstream's answer has been a different codec: Plasma 6.7+ falls back to RemoteFX "progressive" when H.264 decoding fails ([bug 502333](https://bugs.kde.org/show_bug.cgi?id=502333)), which avoids the black screen. That's a reasonable fix, but it isn't on Debian stable, and H.264 with GPU decoding uses less bandwidth anyway. I added my confirmation and the two-line patch to the bug.

The same rebuild also fixed the quality slider. kpipewire passed quality to x264 in a field x264 ignores (the log said so the whole time: `-qscale is ignored, -crf is recommended`). Upstream fixed that too (`88ad0577`).

## 7. The grey

Everything worked, but the picture looked faintly grey and washed out, as if HDR were on without proper support. Sunshine on the same machine had true blacks. So I measured. Konsole's background is RGB **(35, 38, 39)**. In a screenshot of the RDP window it was **(46, 48, 51)**.

That isn't random. Video usually uses *limited range*, where black is 16 and white is 235, not 0 and 255. Squeeze 35 into that range and you get 16 + 35 × 219/255 ≈ **46**. So the Windows client was showing limited-range video as if it were full range, without stretching it back out. Every black became charcoal.

KDE had already fixed this exact symptom ([bug 507015](https://bugs.kde.org/show_bug.cgi?id=507015), "KRdp serves a grayish video stream…") by having krdp request full-range encoding. Reading that fix in current kpipewire, it doesn't take effect for the software encoders: x264 and OpenH264 build their color-conversion filter in the **constructor**, and the full-range setting is only passed in *afterwards*. So on any machine without hardware encoding, which includes mine with an NVIDIA card, the stream stays limited. I only verified this by reading the code, not by running master, and I said so when I reported it as [bug 526795](https://bugs.kde.org/show_bug.cgi?id=526795).

My local patch converts with an explicit color formula and range and **labels them in the stream**, so the decoder doesn't have to guess. It's switchable through an environment variable. Full range is enabled for krdp only, with a systemd drop-in. The result: **(35, 37, 40)**, within compression rounding of the real thing.

---

## Bonus: the clipboard

krdp 6.3 doesn't sync the clipboard at all. It opens the channel but never touches the desktop clipboard. I wanted screenshots to move between the two machines, so I installed **CrossPaste**, a LAN clipboard-sync tool. Text worked. Images from Windows arrived. Images *from* Linux never left.

CrossPaste is a Java app, which on Linux means X11 through Xwayland. KWin passed text from the Wayland clipboard to X11 but not `image/png`. A 30-line systemd user service that watches the Wayland clipboard and copies images into X11 fixed it; it's in the repo, and reported upstream as [CrossPaste #5167](https://github.com/CrossPaste/crosspaste-desktop/issues/5167). (Spectacle 6.3's own auto-copy is separately flaky on Wayland: [KDE bug 500366](https://bugs.kde.org/show_bug.cgi?id=500366).)

## What I took away

- **"Black screen" is not a diagnosis.** In this setup it had three different causes: a missing portal permission, a rejected codec level, and a screencast stuck after restarts. The log lines are what tell them apart.
- **Workarounds can hide causes.** Turning off hardware decoding made the picture appear and created the lag. The lag fix that looked right, frame-rate logic, was real but only half of it.
- **Measure.** Send-Q 0 ruled out the network. Zero dropped frames ruled out the encoder. One pixel value, 46 instead of 35, explained the grey exactly.
- **Debian stable lags upstream, and that's fine.** Most of these were already fixed in Plasma 6.7–6.8. Nine krdp patches and four kpipewire patches, mostly upstream backports, were a day's work. Two of the problems weren't fixed anywhere, and those are now reported with patches.

Everything is in the repo: both patch sets (they rebuild cleanly from `apt source`), the build script, the color drop-in, the clipboard bridge, and a symptom → log line → fix table.

**[repo link]**
