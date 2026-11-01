# DynuclearVolume

**Your notifications match the room they're heard in.** Loud bar → the ping
carries. 2 a.m. bedroom → the same ping doesn't detonate.

Install: add `https://nucleartweaks.github.io/` in Sileo/Cydia (rootless, iOS 15+).
Sliders live under **Settings → DynuclearVolume**. Applies live — no respring.

## Why it exists

iOS has one ringer volume for every room you'll ever be in. At 3 a.m. that
volume is a weapon; at a loud coffee shop it's inaudible — so you live at
either "miss my notifications" or "startle myself awake". Apple's "Attention
Awareness" only notices *your face*, not the world. Your phone has a perfect
ear already installed; it just never uses it at the one moment it matters.

## What it does

Right before a notification sound (or a Siri earcon/response) plays, the tweak
listens through the mic for **0.12 seconds**, then slides the system volume to
where the room says it belongs:

| Room          | Volume                       |
|---------------|------------------------------|
| Dead silent   | your **minimum** slider      |
| Normal chatter| in between                   |
| Loud venue    | your **maximum** slider      |

* Separate min/max sliders for **notifications** and for **Siri** (Siri has
  its own volume bucket on iOS — spoken answers scale with the room too).
* The mic is only hot for the sample window itself — never while you otherwise
  use the phone. One sample per burst (300 ms debounce) so a message + preview
  + haptic doesn't triple-sample.
* Keystroke clicks and other ultrasonic system sounds are excluded — no
  per-tap mic work, no battery drip.
* Toggle it off in Settings and everything behaves exactly like stock iOS.

## How it works

1. **The hook moment.** Every notification tone, SMS alert and Siri earcon on
   iOS funnels through the CoreServices C entry points
   `AudioServicesPlaySystemSound[WithCompletion]` and
   `AudioServicesPlayAlertSound[WithCompletion]`. The tweak `MSHookFunction`s
   all four. Crucially, these run *before* audio output starts — the sample
   window lands in the gap between "sound requested" and "sound audible", so
   the retuned volume applies to the very sound that triggered it. Siri
   **spoken responses** play through `AVAudioPlayer` with the audio-session
   mode `SpokenAudio`; `-play` is hooked to catch those too.
2. **The measurement.** An `AVAudioEngine` input tap runs for 120 ms; the RMS
   of the captured buffer is converted to dBFS and mapped onto a 0…1
   "room-loudness" anchor (≈ −60 dBFS = silence floor of a phone mic,
   −12 dBFS = loud venue), lightly smoothed against the previous sample.
3. **The lever.** `min + ambient × (max − min)` gives the target volume. The
   backend is probed at runtime: iOS 27 exposes per-category volume on
   `AVSystemController` (`+sharedAVSystemController` +
   `setVolumeTo:forCategory:` with the `Ringtone`/`Siri` categories), with
   `MRMediaRemoteSetSystemVolume` (MediaRemote) as fallback. Everything is
   resolved dynamically (`-undefined dynamic_lookup`) — no private SDK stubs,
   so an iOS bump renames something at worst the tweak logs a backend as
   unavailable and passes through, never crashes.
4. **Live prefs.** Settings writes go to the tweak's preference domain and
   post a Darwin notification; every injected process reloads within one
   sound's latency.

## Known limitations

* Simulator builds cannot apply volume (Apple stubs MediaRemote/AVSystemController
  there); the hooks, sampler and mapping are fully testable, application is
  device-only and logs which backend answered.
* v1 targets UI processes (`UIApplication` filter). Siri earcons that play from
  headless assistant daemons in exotic setups (CarPlay routing) may pass
  through unmodified.
* If a notification arrives with the mic already occupied (call recording,
  Voice Memos), the last known ambient reading is reused — no glitches, just
  a stale number.

## Testing in the jailbroken iOS 27 simulator

The production filter loads unchanged on the sim. What the sim CANNOT do:
apply volume (MediaRemote/AVSystemController are stubs there — the proof file
logs `NO — pass-through backend`, which is expected) and capture mic audio
(guest SpringBoard has no input node; the sampler early-returns — the same
sampling code unit-tested host-side on the Mac captured 4800 frames @48 kHz in
its 120 ms window and mapped silence → minimum exactly per spec). Proof trail:
`/Users/spencer/dynuclearvolume-proof.txt` (host path, absent on device).
`notifyutil -p` cannot post Darwin notifications into the guest (code 9) —
verify prefs changes by writing the plist + respring; live Darwin reload is a
device behavior driven by the Settings pane in-process.

## Development

Org-standard scaffold — pipeline lives in `NuclearTweaks/.github` (reusable `tweak-ci.yml`).

* Local sim loop: `tools/sim-test.sh DynuclearVolume` from the workspace root (Mac + JB-13mini; CI never builds for sim).
* Release: push to `main` → CI opens a release PR → merge → GitHub Release + APT repo update.
* `Package:` id `com.nucleartweaks.dynuclear-volume` is immutable after the first release. See the org KB (`meta` repo → knowledge/pitfalls.md).
