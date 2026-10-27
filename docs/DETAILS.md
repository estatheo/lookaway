# lookaway: the details

The friendly guide is the [README](../README.md); this is everything else.

A macOS menu-bar app that locks the screen when you look away from it.

It watches the built-in camera with Apple's Vision framework, entirely on-device.
When *your* face has not been seen for a configurable grace period (default 5 s), it
does what you picked under *When I'm away*: by default it blocks the keyboard and mouse (see [Block input only](#block-input-only)); it can also lock the screen the same way Ctrl+Cmd+Q does. Running processes (tmux sessions,
agents, builds) keep going; only input is blocked. It never logs out and never
sleeps the system.

Unlocking is Touch ID / password / Apple Watch, as usual. There is also an opt-in,
clearly labelled *less secure* auto-unlock that unlocks when your face comes back; it is
off by default, see [Auto-unlock](#auto-unlock-opt-in-less-secure).

## Install

Needs macOS 14+ and Xcode (the full app, for the SDK and Swift Testing).

```sh
scripts/install      # builds build/lookaway.app, copies it to ~/Applications, launches it
scripts/build        # just build build/lookaway.app
scripts/test         # unit tests (swift test with Xcode's toolchain)
```

First run:

1. Opening lookaway for the first time shows the **Enroll my face** window by itself and
   macOS asks for **Camera** access. Allow it.
2. Follow the prompts for about ten seconds: look at the screen, then slowly turn your
   head a little left, right, up and down. Only you may be in view.
3. Optional: **Settings… → Start at login**.

Until a face is enrolled the app never locks anything. After that it runs in the menu bar
(an eye icon) with no Dock icon, and starts quietly at login.

If you cannot see the icon: on a MacBook with a notch the menu bar can run out of room, and
icons that do not fit are hidden behind the notch. Check System Settings › Menu Bar (allow
lookaway), or quit a few other menu-bar apps. You never depend on the icon to get at the app:
**opening lookaway.app again** (Finder, Spotlight, `open ~/Applications/lookaway.app`) shows
the Settings window, or the Enroll window if you have not enrolled yet. A second launch hands
over to the running copy and then exits.

The app icon (an open eye with a padlock for a pupil) is drawn by
`scripts/make-icon.swift` and committed as `Resources/AppIcon.icns`; run `scripts/make-icon`
to regenerate it.

### Permissions

| Permission | Why | When |
|---|---|---|
| Camera | Seeing whether you are there | Always |
| Accessibility | The Ctrl+Cmd+Q lock fallback; and typing the password for auto-unlock | Lock fallback: only if the private lock call is unavailable on a future macOS. Auto-unlock: always, once you turn it on. |
| Notifications | One alert when the camera becomes unavailable | Optional |
| Accessibility (cover) | Blocking keyboard and mouse under the cover | Only with *Cover the screen* |
| Bluetooth | Hearing your paired phone | Only once you pair a phone |

The camera permission is tied to the app's code signature. `scripts/build` signs ad-hoc
with a fixed designated requirement (`identifier "local.gizmos.lookaway"`), so the
permission survives rebuilds. To sign with a local certificate instead, set
`LOOKAWAY_SIGN_IDENTITY="Your Cert Name"`. If macOS ever re-prompts or shows a stale
entry, remove lookaway from System Settings → Privacy & Security → Camera and re-enroll.

## Using it

Menu: status line (Watching / You're here / Away 3s… / Paused / Screen locked / Camera
unavailable / Off), the on/off toggle, **Pause** (15 min, 1 h, until resumed), **Enroll my
face…**, **Settings…**, **Quit**.

Settings:

- **Lock when**: *I look away from the screen* (attention, default: your face must be
  turned to the screen) or *I leave the camera's view* (presence: your face anywhere in
  frame is enough).
- **Grace period**: seconds without you before locking. Default 5.
- **Face match**: strict ↔ lenient, with a live readout of the latest match distance
  against the limit, for tuning.
- **Start at login**, and **Delete enrolled face**.

Behaviour worth knowing:

- Once you are recognised, lookaway follows your face from frame to frame. Turning to a
  second screen, leaning in or sitting back, where your face no longer matches the
  enrollment, still counts as you being there (in *presence* mode). The track breaks when
  no face continues it for 2 s, so stepping out of view counts as leaving, and a face that
  appears later starts with no track.
- A coworker's face in front of the camera does not count as you; the screen still locks.
- While the screen is locked the camera is released. After unlocking, the grace timer
  starts fresh.
- If the camera is unavailable (lid closed, device gone, permission revoked, no frames
  for 5 s) the menu says *Camera unavailable*, one notification is posted, and it does
  **not** lock. It retries the camera every 10 s. After sleep/wake it restarts the camera.
- With auto-unlock on, the camera also runs while the screen is locked (see above).
- Settings and the enrolled face live in `~/Library/Application Support/lookaway/`
  (`enrollment.json`, mode 0600) and the app's user defaults.

## Auto-unlock (opt-in, less secure)

Settings → **Auto-unlock when I look back (less secure)**. Off by default.

When it is on and lookaway has locked the screen, your enrolled face returning to the
camera makes lookaway wake the display and type your login password at the login window
for you, so you do not need Touch ID or the password.

Before typing, lookaway reads `lastUserName` from `/Library/Preferences/com.apple.loginwindow`.
If the login window is preselecting another account (or the setting is missing or
unreadable), nothing is typed: the attempt is logged under subsystem `local.gizmos.lookaway`
and the menu shows "Auto-unlock skipped: login window is on <user>". A skipped attempt
counts toward the attempt limit.

### Threat model: read this before turning it on

A Mac webcam is a 2D camera with no depth sensing. **A photo or a video of you can fool
it.** The extra checks below make that harder, not impossible; this trades security for
convenience. Touch ID and Apple Watch unlock remain the secure options and keep working
exactly as before. Anyone who can get a good picture of your face and hold it up to the
camera while the Mac is locked may be able to unlock it, and your login password is held
in your Keychain for this feature. Do not enable it on a Mac where that is not acceptable.

### What it does and does not unlock

- Only a lock **lookaway itself caused**. A manual lock (Ctrl+Cmd+Q, hot corner, Apple
  menu), a lock after sleep or a restart, and a lock after a lid close are never
  auto-unlocked. A lock that was already in force when lookaway launched is not either.
- Only locks younger than **Newest lock to undo** (default 10 minutes, 1 to 120). Older
  lookaway locks need a normal unlock.
- A stricter match than locking uses. The face must be within the enrollment's base
  distance limit (lock mode allows 1.5 times that by default; the unlock limit is never
  looser than the lock limit), be turned to the screen, and match in at least 5
  consecutive frames spanning at least 1 s. Any other frame (a stranger, no face, a
  turned head) restarts the count.
- A basic liveness check on those frames: the head must move (6° of yaw, pitch or roll,
  or a shift of a tenth of the face height) or the eyes must blink. A photo propped
  still fails this. A video of you, or a photo waved about by hand, can pass it.
- **Two failed attempts and it switches itself off** until you next unlock by hand. An
  attempt fails if the password could not be typed (no Accessibility permission, no
  stored password) or the session is still locked 8 s after typing (wrong password, for
  example after you changed it). You get one notification when that happens.

All of these numbers live in one struct, `UnlockTuning` in
`Sources/LookawayCore/AutoUnlock.swift`, and the decision logic (`UnlockMachine`) is unit
tested with fake clocks and fake frames.

### Turning it on and off

Turning it on shows a confirmation that states the risk and asks for your login
password. The password is checked against your account (OpenDirectory) before anything
is stored; a wrong one stores nothing. It is then saved as a device-only item
(`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, not synchronised) in the login Keychain
under the service `local.gizmos.lookaway.login-password`. macOS then asks for Accessibility
access, which is needed to type.

Turning it off (or **Delete enrolled face**) deletes the Keychain item. Check with:

```sh
security find-generic-password -s local.gizmos.lookaway.login-password   # not found = gone
```

If you change your login password, turn auto-unlock off and on again. The old password
would fail twice and switch the feature off.

### How it unlocks

While the screen is locked by lookaway and auto-unlock is armed, the camera keeps running
(at 10 fps instead of 5) and Vision's landmark detector reads each frame. When the
decision logic says yes, lookaway raises a user-activity assertion to wake the display,
taps Shift so the login window shows its password field, types the stored password with
synthetic key events (`CGEvent`, the technique tools like BLEUnlock use) and presses
Return. Then it waits for the session's `screenIsUnlocked` notification. The password is
read from the Keychain per attempt, held in memory only while typing and zeroed after;
it is never logged, and no frame is ever written to disk.

### Verify it on your Mac first

Two things this depends on cannot be proven by unit tests and differ across macOS
releases: that the camera keeps delivering frames while the screen is locked (and with the
display asleep), and that synthetic key events reach the login window. Check the first
with the probe, which counts frames and **locks your screen** (unlock by hand, then read
the file):

```sh
build/lookaway.app/Contents/MacOS/lookaway --probe-locked-camera --out /tmp/lookaway-probe.txt
# add --sleep-display to also put the display to sleep 6 s after the lock
```

To see why your face is or is not recognised, `--probe-face` prints each frame's match
distance against the lock and strict limits, the head angles, and when the cover (or
auto-unlock) would lift. It never blocks or locks:

```sh
build/lookaway.app/Contents/MacOS/lookaway --probe-face --seconds 15
```

`RESULT frames kept arriving while locked` means the camera side works. `RESULT NO frames`
means auto-unlock cannot work on this Mac and should stay off. The second is covered by
the manual checklist below.

## Cover instead of lock (opt-in)

Settings → **When I'm away** → *Cover the screen and block the keyboard and mouse*. The
default stays *Lock the screen*.

When you have been away for the grace period, lookaway does not lock the session. It puts
an opaque window over every display (above the menu bar and full-screen apps), switches
on kiosk options (no Dock, menu bar, Cmd+Tab, Force Quit or log-out), and swallows every
keyboard and mouse event with an event tap. Everything underneath keeps running and stays
exactly where it was.

It comes down by itself when lookaway sees **you** again, using nearly the same strict test
as auto-unlock: within 1.2 times the enrollment's base match limit (auto-unlock: 1.0, as
it types your password; both never looser than the lock limit), facing the screen, 5 frames over at
least 1 s, and moving or blinking. If a phone is paired (below), the phone must also be
nearby for the whole run.

- **A key press or a click under the cover locks the Mac for real.** A stranger who tries
  the keyboard gets the macOS lock screen; you, if you would rather not wait to be
  recognised (or your phone is flat), get Touch ID or the password. Mouse movement and
  scrolling are swallowed silently, so nudging the mouse as you sit down does not lock.
- After **Lock for real after** (default 30 minutes) the cover turns into a real lock.
- Any real lock (Ctrl+Cmd+Q, a hot corner, the lid, display sleep with a password) takes
  the cover away.
- Blocking input needs **Accessibility** access. Without it lookaway locks instead and
  says so once.

### Block input only

Settings → **When I'm away** → *Block the keyboard and mouse only*. The same as the
cover, except the screen stays visible and the menu bar stays: the lookaway icon turns
into a raised hand while input is blocked. A key press or click is swallowed and does
**not** lock; **Ctrl+Cmd+Q** is the way out to a real lock (in both cover modes). Anyone
walking past can read your screen.

Touching the keyboard or mouse while input is blocked (or under the cover) plays
`~/Library/Application Support/lookaway/blocked.mp4` (or `.mov`, `.m4v`) in the middle of
the main display, with the system volume unmuted and set to 40%. When it ends, or the
cover comes down, the volume and mute go back to what they were. Without that file the
app plays its own `Resources/default-blocked.mp4` (an original HANDS OFF clip).

A fresh install starts in this mode. Settings saved by an older version that never chose
keep locking the screen.

### My phone

Settings → **My phone** → **Pair my phone…** lists nearby named Bluetooth devices; pick
your iPhone. lookaway then reads its signal strength, both from its adverts and by
connecting and reading the signal every 2 s, and smooths it (one strong reading does not
count). The phone is *nearby* when it was heard in the last 10 s and the smoothed signal is
stronger than **Nearby means** (default −70 dBm, about arm's length with the phone in a
pocket). Settings shows the live signal so you can set it.

The phone has to be signed in to the same Apple ID as the Mac: an iPhone changes its
Bluetooth address every few minutes and only a Mac on the same account can follow it. The
first pairing makes macOS ask for **Bluetooth** access.

### Threat model

The cover is weaker than the macOS lock, and is for an office you mostly trust, not for a
Mac that holds things a determined person would work to get.

- **It is an app, not the login window.** If lookaway crashes or is killed, the cover and
  the input block go with it and the session is open. Nothing short of the real lock
  survives that.
- **A photo or video of you plus your phone nearby** lifts it. The phone stops a photo on
  its own; it does not stop someone sitting next to you while you are on a call across the
  room, if your phone is still within the threshold. Bluetooth signal can also be relayed
  by someone with the equipment and intent.
- **What an event tap cannot stop:** the power button, the lid, and keys handled in
  hardware. Hot corners and some trackpad gestures are handled by the Dock and may still
  fire; check yours before relying on it (the manual checklist below).
- The cover hides the screen; it does not blank it for screen recording or screen sharing
  already in progress.

If any of that matters, keep *Lock the screen*.

## How it works

- `LookawayCore` is pure logic: `AwayMachine` takes timestamped events (owner facing /
  turned / absent / camera error, lock state, ticks, pause, config) and returns actions
  (`lockScreen`, `notifyCameraUnavailable`). Unit-tested with fake clocks.
- The app target owns the camera (`AVCaptureSession`, low preset, ~5 fps), Vision
  (`VNDetectFaceRectanglesRequest` for faces plus yaw/pitch, `VNGenerateImageFeaturePrintRequest`
  on a square face crop for recognition), the lock (`SACLockScreenImmediate` from
  `login.framework` via `dlopen`, falling back to posting Ctrl+Cmd+Q), and lock-state
  tracking (`com.apple.screenIsLocked` / `screenIsUnlocked`).
- Enrollment stores 16 feature vectors plus a match threshold calibrated from how much your
  own samples differ from each other. Matching takes the closest enrolled vector.
- `lookaway --check` (run `build/lookaway.app/Contents/MacOS/lookaway --check`) verifies the
  lock symbol resolves, the Vision pipeline runs, and prints camera/enrollment state. It
  never locks.

## Privacy and limitations (honest version)

- Frames are analysed in memory and discarded. Nothing is written to disk, nothing is
  sent anywhere; the app makes no network connections. Only face feature vectors are stored
  (and, if you enable auto-unlock, your login password in the Keychain).
- **This is not strong biometric authentication.** Recognition uses Apple's general image
  feature print on a face crop, not a dedicated face-embedding model. It separates "you"
  from "a different person at a desk" reasonably, but it can mistake look-alikes, and it
  can be fooled by a photo or screen showing your face. That is acceptable for "lock when
  I walk off", and is exactly why auto-unlock is marked less secure and is off by default.
- The failure it is tuned against is *not locking when you are away*. The opposite failure
  (locking while you are there) is more likely in poor light, with a hat or mask, or after
  big appearance changes. Use the **Face match** slider and re-enroll in the lighting you
  usually have.
- "Looking at the screen" is head pose (yaw/pitch within about 30°), not eye gaze. Reading a
  notebook beside the laptop with your head turned will count as looking away in attention
  mode; use presence mode if that bothers you.
- Head roll is not corrected before matching.
- `SACLockScreenImmediate` is a private API. It could change in a future macOS; the
  Ctrl+Cmd+Q fallback (needs Accessibility) is there for that case.
- The camera light turns on whenever it is watching. Pausing, turning it off, or locking
  releases the camera.
- Auto-unlock relies on synthetic keystrokes into the login window. It needs Accessibility
  permission, can break on a future macOS, and types the password blind: if the login window
  is not showing its password field it fails, counts as a failed attempt, and after two
  the feature switches off.
- Tested by unit tests for the logic; the camera and Vision parts have only been exercised
  by the manual checklist below.

## Manual test checklist

Run these with lookaway enrolled and enabled, grace period 5 s, attention mode.

- [ ] Fresh install (delete the enrollment first): launching the app opens the Enroll window
      in front and macOS asks for camera access. With an enrolled face, launching does not
      open a window.
- [ ] With the app running, `open ~/Applications/lookaway.app` brings up Settings in front.
- [ ] Menu shows *You're here* while you look at the screen.
- [ ] Look away (turn your head well to the side) for 5 s → the status counts *Away 1s…*,
      then the screen locks.
- [ ] Unlock, look away again → it locks again after a fresh 5 s, not immediately.
- [ ] Walk away from the Mac → locks after ~5 s.
- [ ] Have a coworker (or someone else) sit in front of the camera while you are away →
      the screen still locks. Also: they sit next to you while you look at the screen → it
      does not lock.
- [ ] Cover the camera with tape or a cover → no lock; the menu says *Camera unavailable*
      and exactly one notification appears; uncover it and the status recovers within ~10 s.
- [ ] Close the lid / unplug an external camera → *Camera unavailable*, no lock loop.
- [ ] Start `tmux`, run `while true; do date >> /tmp/lookaway-tick; sleep 1; done`, lock via
      lookaway, wait 30 s, unlock → `/tmp/lookaway-tick` kept growing while locked.
- [ ] **Pause → For 15 minutes**: looking away does not lock; the camera light goes off;
      the menu shows *Paused until HH:MM*. **Resume** works.
- [ ] Switch to *presence* mode in Settings: turning your head does not lock; leaving does.
- [ ] Toggle the menu switch off: nothing locks, camera light off.
- [ ] Quit and relaunch (and, with *Start at login* on, log out and in): enrollment is
      remembered and the camera permission is not asked again.

### Auto-unlock checklist

Run with auto-unlock turned on in Settings, Accessibility granted, in the lighting you
normally sit in. Keep your Touch ID or password handy for when something does not unlock.

- [ ] `--probe-locked-camera` (above) reports frames arriving while locked.
- [ ] Look away until it locks, then look back at the screen and move a little → the screen
      unlocks by itself within a few seconds.
- [ ] Look away until it locks, hold a **photo of you** (a phone showing one is fine) still
      in front of the camera for 15 s → it stays locked. (Waving it about, or playing a video
      of you, may unlock it; that is the stated limitation.)
- [ ] Lock manually with Ctrl+Cmd+Q, then look at the screen → it stays locked.
- [ ] Let lookaway lock, wait longer than **Newest lock to undo** (set it to 1 min to test),
      then look back → it stays locked.
- [ ] Let lookaway lock, close the lid for 10 s and reopen → it stays locked.
- [ ] Let lookaway lock, then someone else looks at the screen → it stays locked.
- [ ] Change your login password without updating lookaway, let it lock, look back → after
      two failed tries a notification says auto-unlock is off, and the menu shows it paused.
      Unlock by hand → it is armed again.
- [ ] Turn the toggle off → `security find-generic-password -s local.gizmos.lookaway.login-password`
      reports the item could not be found, and looking back no longer unlocks.
- [ ] Turn it on with a wrong password in the dialog → it is refused and nothing is stored.
- [ ] While auto-unlock was working: `/tmp/lookaway-tick` (see above) kept growing across the
      lock and unlock, and the password does not appear in
      `log show --last 10m --predicate 'subsystem == "local.gizmos.lookaway"'`.

### Cover checklist

Run with *Cover the screen* selected, Accessibility granted, and your iPhone paired.

- [ ] Look away for 5 s → every display goes black with *Waiting for you*, the Dock and
      menu bar are gone, the menu-bar icon (if visible) shows the covered state.
- [ ] Look back and move a little, phone in your pocket → the cover lifts within a few
      seconds, and everything underneath is as you left it.
- [ ] Leave the phone in another room, look back → the cover stays up and says it is
      waiting for the phone. Fetch the phone → it lifts.
- [ ] Under the cover, press a key → the cover goes and the macOS lock screen is there.
      Same for a click. Moving the mouse or scrolling does nothing.
- [ ] Under the cover try Cmd+Tab, Cmd+Opt+Esc, Cmd+Space, Ctrl+Up (Mission Control),
      your hot corners and a three-finger swipe → nothing shows what is underneath. Note
      anything that does, and do not rely on the cover until it is fixed.
- [ ] Hold a **photo of you** in front of the camera with the phone nearby → it stays
      covered while the photo is still (the same liveness limits as auto-unlock apply).
- [ ] Set **Lock for real after** to 1 min → after a minute covered, the real lock appears.
- [ ] Revoke Accessibility, look away → it locks instead, with one notification.
- [ ] `/tmp/lookaway-tick` (see above) kept growing while covered.
