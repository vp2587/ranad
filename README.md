# Ranad — ระนาดเอก

An iOS app for playing the Thai **ranad ek** (ระนาดเอก), the lead xylophone of the piphat ensemble.

![icon](Ranad/Assets.xcassets/AppIcon.appiconset/AppIcon.png)

## Features

- **21 bars** hung on cords over a boat-shaped stand (รางระนาด), laid out like the real instrument: the longest, lowest bar on the left.
- **Multi-touch**: every finger is a mallet. Tap to strike, slide across the bars for a glissando.
- **Kro (กรอ)**: turn it on and hold a bar to roll the rapid tremolo that is typical of ranad playing.
- **Octaves (ตีคู่แปด)**: every strike also plays the bar an octave away, the way ranad players usually play with two mallets.
- **Thai or Western tuning**: Thai tuning splits the octave into seven equal steps. Western tuning uses a major scale, for playing along with other instruments.
- Note labels in Thai (โด เร มี …) or Latin (Do Re Mi …), or none.
- No audio samples: the sound is synthesized live. Each note is a set of decaying, inharmonic partials of a wooden bar plus a short noise burst for the hard mallet.

## Running it

Requires Xcode 16 or later, and iOS 17 or later.

1. Open `Ranad.xcodeproj` in Xcode.
2. Select the **Ranad** target → *Signing & Capabilities*, and choose your team. You may also need to change the bundle identifier from `com.example.ranad`.
3. Pick your iPhone or iPad (or a simulator) and press **Run**.

The app runs in landscape only. Sound plays even when the silent switch is on.

## Code

| File | What it does |
| --- | --- |
| `RanadInstrument.swift` | Tuning, note names, and the bar geometry shared by drawing and touch handling |
| `RanadAudioEngine.swift` | `AVAudioEngine` setup and the real-time bar synthesizer |
| `TouchSurface.swift` | Multi-touch handling (strikes, glissando, kro tremolo) |
| `RanadViewModel.swift` | Settings and state for which bars are lit |
| `ContentView.swift` | The SwiftUI instrument and controls |
