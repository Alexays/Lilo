import sharp from "sharp";
import { createHash } from "node:crypto";
import { rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");

function channelHashes(data) {
  const pixels = data.length / 4;
  const rgb = Buffer.allocUnsafe(pixels * 3);
  const alpha = Buffer.allocUnsafe(pixels);
  for (let pixel = 0; pixel < pixels; pixel++) {
    const offset = pixel * 4;
    rgb[pixel * 3] = data[offset];
    rgb[pixel * 3 + 1] = data[offset + 1];
    rgb[pixel * 3 + 2] = data[offset + 2];
    alpha[pixel] = data[offset + 3];
  }
  return { rgb: sha(rgb), alpha: sha(alpha) };
}

export async function isolateNativePng(file, { rect, radius }) {
  if (
    !Array.isArray(rect) ||
    rect.length !== 4 ||
    !rect.every(Number.isFinite) ||
    rect[2] <= 0 ||
    rect[3] <= 0 ||
    !Number.isFinite(radius) ||
    radius < 0 ||
    radius > Math.min(rect[2], rect[3]) / 2
  )
    throw Error("Expected finite native rectangle bounds and a valid corner radius.");
  const metadata = await sharp(file).metadata();
  if (metadata.format !== "png") throw Error("Native cutouts require a PNG source.");
  const { data, info } = await sharp(file)
    .ensureAlpha()
    .raw({ depth: "uchar" })
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== 4 || data.length !== info.width * info.height * 4)
    throw Error("Expected 8-bit RGBA native pixels.");
  const before = channelHashes(data);
  const [left, top, width, height] = rect;
  const centerX = left + width / 2,
    centerY = top + height / 2;
  const straightX = width / 2 - radius,
    straightY = height / 2 - radius;

  // Native bounds may extend past a crop; no synthetic corner is added at the crop edge.
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const qx = Math.abs(x + 0.5 - centerX) - straightX;
      const qy = Math.abs(y + 0.5 - centerY) - straightY;
      const distance =
        Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - radius;
      const coverage = Math.max(0, Math.min(1, 0.5 - distance));
      const offset = (y * info.width + x) * 4 + 3;
      data[offset] = Math.min(data[offset], Math.round(coverage * 255));
    }
  }

  const encoded = await sharp(data, {
    raw: { width: info.width, height: info.height, channels: 4 },
  })
    .png({ palette: false })
    .toBuffer();
  const decoded = await sharp(encoded)
    .ensureAlpha()
    .raw({ depth: "uchar" })
    .toBuffer({ resolveWithObject: true });
  if (
    decoded.info.width !== info.width ||
    decoded.info.height !== info.height ||
    decoded.info.channels !== 4
  )
    throw Error("PNG encoding changed native capture dimensions.");
  const after = channelHashes(decoded.data);
  if (before.rgb !== after.rgb) throw Error("Alpha isolation changed native RGB pixels.");
  let transparentPixels = 0,
    partialPixels = 0,
    opaquePixels = 0;
  for (let offset = 3; offset < decoded.data.length; offset += 4) {
    const alpha = decoded.data[offset];
    if (alpha === 0) transparentPixels++;
    else if (alpha === 255) opaquePixels++;
    else partialPixels++;
  }
  if (!transparentPixels || !opaquePixels)
    throw Error("Native cutout must retain opaque UI and clear its exterior.");

  const temporary = `${file}.cutout.tmp`;
  try {
    await writeFile(temporary, encoded);
    await rename(temporary, file);
  } finally {
    await rm(temporary, { force: true });
  }
  return {
    file: path.basename(file),
    width: info.width,
    height: info.height,
    shape: { rect: [...rect], radius },
    beforeRgbSha256: before.rgb,
    afterRgbSha256: after.rgb,
    beforeAlphaSha256: before.alpha,
    afterAlphaSha256: after.alpha,
    transparentPixels,
    partialPixels,
    opaquePixels,
  };
}
