#!/usr/bin/env python3
"""Writes pink_noise.wav (mono, 48 kHz, 16-bit, default 60 s) to play through the PA for the room measurement.

    python3 make_pink_noise.py [seconds]

Play it from a laptop, phone or the USB player on a mixer channel, at a moderate level, with the channel's EQ flat and
the main EQ as it normally is. Then measure from where the audience sits: Holly Mixer > Main > EQ > Assist >
Measure the room > Pink noise. Keep the level moderate: it is a steady noise and tiring for everyone in the room.

Pink noise has the same energy in every octave; heard through a flat system and room it reads as a flat line in the
measurement. Python 3.8+, standard library only (the filter is Paul Kellet's economy pink-noise approximation).
"""
import random
import struct
import sys
import wave

SECONDS = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
RATE = 48000
random.seed(1)

b0 = b1 = b2 = b3 = b4 = b5 = b6 = 0.0
samples = []
for _ in range(int(SECONDS * RATE)):
    white = random.uniform(-1, 1)
    b0 = 0.99886 * b0 + white * 0.0555179
    b1 = 0.99332 * b1 + white * 0.0750759
    b2 = 0.96900 * b2 + white * 0.1538520
    b3 = 0.86650 * b3 + white * 0.3104856
    b4 = 0.55000 * b4 + white * 0.5329522
    b5 = -0.7616 * b5 - white * 0.0168980
    pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
    b6 = white * 0.115926
    samples.append(pink * 0.11)

peak = max(abs(s) for s in samples)
scale = 0.5 / peak  # -6 dBFS peak
with wave.open("pink_noise.wav", "wb") as out:
    out.setnchannels(1)
    out.setsampwidth(2)
    out.setframerate(RATE)
    out.writeframes(b"".join(struct.pack("<h", int(max(min(s * scale, 1), -1) * 32767)) for s in samples))
print(f"Wrote pink_noise.wav ({SECONDS:.0f} s)")
