#!/usr/bin/env python3
"""Original Feather ambient loop. No samples or third-party composition.

The composition and generated audio are dedicated to the public domain under
CC0-1.0. Generate PCM with this script, then encode with ffmpeg as documented
in Feather/Resources/Audio/README.md. Python standard library only.
"""
import argparse
import array
import math
from pathlib import Path
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    rate, duration = 22050, 142.248
    frames = round(rate * duration)
    bar = duration / 8
    # Widely spaced, slowly changing original voicings. No percussion.
    chords = [(48, 55, 64, 71), (45, 52, 60, 67), (41, 48, 57, 64),
              (43, 50, 59, 67), (48, 55, 62, 69), (45, 52, 60, 64),
              (41, 48, 55, 64), (43, 50, 55, 62)]
    samples = array.array("h")
    for i in range(frames):
        t = i / rate
        left = right = 0.0
        for b, chord in enumerate(chords):
            local = t - b * bar
            # Neighbouring chords overlap; wrap so the loop has no abrupt edge.
            if local < 0:
                local += duration
            if local >= bar + 5:
                continue
            attack = min(1.0, local / 4)
            release = min(1.0, (bar + 5 - local) / 6)
            env = math.sin(attack * math.pi / 2) ** 2 * max(0, release) ** 2
            for n, midi in enumerate(chord):
                hz = 440 * 2 ** ((midi - 69) / 12)
                phase = 2 * math.pi * hz * local
                tone = (math.sin(phase) + 0.14 * math.sin(phase * 2)) * env * 0.034
                pan = (n - 1.5) * 0.12
                left += tone * (0.7 - pan)
                right += tone * (0.7 + pan)
        edge = min(1.0, t / 2, (duration - t) / 3)
        samples.extend((round(left * edge * 32767), round(right * edge * 32767)))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(samples.tobytes())
    print(f"Created {args.output}: {duration}s, stereo, {rate}Hz, original CC0 audio")


if __name__ == "__main__":
    main()
