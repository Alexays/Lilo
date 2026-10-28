import sharp from "sharp";

export interface RecordingFrame {
  delay: number;
  image: Buffer;
}

export const encodeRecording = (frames: RecordingFrame[]) => {
  if (
    frames.length < 2 ||
    frames.length > 64 ||
    frames.some((frame) => !Number.isFinite(frame.delay) || frame.delay <= 0)
  ) {
    throw new Error("A recording needs 2 to 64 frames with positive delays");
  }

  return sharp(
    frames.map((frame) => frame.image),
    { join: { animated: true } }
  )
    .webp({
      delay: frames.map((frame) => frame.delay),
      effort: 3,
      loop: 1,
      quality: 82,
    })
    .toBuffer();
};
