// Original editorial sound design; these are not sounds emitted by Lilo.
export const soundtrack = (shownAt: number, switchedAt: number) => {
  const rate = 48_000;
  const seconds = 14;
  const samples = rate * seconds;
  const wav = Buffer.alloc(44 + samples * 4);
  wav.write("RIFF");
  wav.writeUInt32LE(wav.length - 8, 4);
  wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16);
  wav.writeUInt16LE(1, 20);
  wav.writeUInt16LE(2, 22);
  wav.writeUInt32LE(rate, 24);
  wav.writeUInt32LE(rate * 4, 28);
  wav.writeUInt16LE(4, 32);
  wav.writeUInt16LE(16, 34);
  wav.write("data", 36);
  wav.writeUInt32LE(samples * 4, 40);

  const cues = [
    [2.5, 880],
    [4.8, 660],
    [shownAt, 880],
    [switchedAt, 1108.73],
  ];

  for (let index = 0; index < samples; index += 1) {
    const time = index / rate;
    const fade = Math.min(1, time / 1.4, (seconds - time) / 1.6);

    for (let channel = 0; channel < 2; channel += 1) {
      let value = 0;

      for (const frequency of [130.81, 196, 261.63, 329.63]) {
        value +=
          Math.sin(2 * Math.PI * (frequency + channel * 0.35) * time) *
          0.025 *
          (0.85 + 0.15 * Math.sin(time * 0.8));
      }

      for (const [at, frequency] of cues) {
        const elapsed = time - at;

        if (elapsed >= 0 && elapsed < 0.55) {
          value +=
            Math.sin(2 * Math.PI * frequency * elapsed) *
            Math.exp(-elapsed * 16) *
            Math.min(1, elapsed / 0.006) *
            0.15;
        }
      }

      wav.writeInt16LE(
        Math.round(Math.max(-1, Math.min(1, value * fade)) * 32_767),
        44 + index * 4 + channel * 2
      );
    }
  }

  return wav;
};
