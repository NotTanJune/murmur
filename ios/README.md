# Murmur keyboard for iPhone

A dictation keyboard. Tap the Murmur key, talk, and tap again to type the text into the current
field, or hold the key for push-to-talk. The keyboard records audio itself, so you never switch
apps. Bark 3.0 Clean and the cleanup rules run on the phone, and no audio or text leaves it.

## Install

There is no App Store or TestFlight build yet. To build it yourself, from the repo root, you
need:

- an iPhone on iOS 26 or later, a Mac with Xcode 26, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- a paid Apple Developer membership. The app and the keyboard share files through an App
  Group, and free personal teams cannot use App Groups.

1. Put your signing team in `ios/Local.xcconfig` (git ignores it):

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```

2. Replace `ai.pivotstudio.murmur` with your own identifier. It belongs to another team, so
   Xcode will not sign it for you:

   ```bash
   sed -i '' 's/ai\.pivotstudio\.murmur/com.yourname.murmur/g' ios/project.yml ios/Shared/PhoneEnvironment.swift
   ```

3. Connect the iPhone, unlock it, turn on Developer Mode (Settings > Privacy & Security), then:

   ```bash
   make ios-install
   ```

   This builds a signed Release and installs it on the first connected iPhone. To use Xcode
   instead, run `make ios-project`, open `ios/Murmur.xcodeproj` and run the `MurmurPhone`
   scheme.

4. Open Murmur on the phone and follow the Setup tab. Allow the microphone and speech
   recognition, and download Bark (450 MB). Then add the keyboard in Settings > General >
   Keyboard > Keyboards > Add New Keyboard > Murmur and turn on **Allow Full Access**. The
   keyboard records through WebKit under the app's microphone permission, and that needs
   Full Access.

5. In any text field, hold the globe key and pick Murmur. Tap the key to start and tap again
   to type, or hold it for push-to-talk. After each install, the first Bark load compiles for
   the Neural Engine and takes about 90 s. Apple's transcriber handles dictation until then.

## With the Mac app

The two apps run independently, and both have Bark 3.0 Clean and the
cleanup rules. To train on phone dictations, correct them in the phone's History tab and
export them from Settings > Training > Export labelled recordings. Send the zip to your Mac,
for example over AirDrop, and open it with Settings > Training > Import from iPhone. The runs
join the Mac's history and its next training export.

## Build commands

```bash
make ios-project   # XcodeGen: ios/Murmur.xcodeproj and the two Info.plists
make ios-build     # unsigned compile of both targets, no device needed
make ios-install   # signed Release, installed on the first connected iPhone
```

Build output goes to `~/Library/Caches/MurmurBuild/ios`. How the keyboard records and the traps
in it are in [AGENTS.md](../AGENTS.md#ios-keyboard).
