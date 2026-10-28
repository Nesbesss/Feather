# Tour audio

`tour-background.mp3` is **First Light**, an original synthesized ambient loop
created for Feather's distributable release. It contains no sampled recording
or copied third-party composition. The composition and recording are dedicated
to the public domain under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/).

Source: `Tools/Release/make-tour-audio.py` in the Feather repository. The Python
standard-library generator produces 142.248 seconds of stereo PCM. Recreate it:

```sh
python3 Tools/Release/make-tour-audio.py build/audio/tour-background.wav
ffmpeg -i build/audio/tour-background.wav -ar 44100 -c:a libmp3lame -b:a 128k \
  -map_metadata -1 -metadata title='Feather - First Light' \
  -metadata artist='Feather contributors' build/audio/tour-background.mp3
```

Playback is local, with fade-in, pause/resume, mute and volume controls. It never
changes macOS audio settings. The previous user-supplied recording was preserved
outside the public source in the local release backup and is not distributed.

The short tour tap is original synthesized audio in `WelcomeSound.makeClickWave()`.
Typing recordings and their CC0 provenance are documented in `Typing/LICENSE.txt`.
