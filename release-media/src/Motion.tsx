import React from "react";
import type { CSSProperties } from "react";
import {
  AbsoluteFill,
  CanvasImage,
  Easing,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import browser from "../public/native/0.1.0/capture.json";
import pins from "../public/native/0.1.3/capture.json";
import edges from "../public/native/0.2.0/capture.json";
import settings from "../public/native/0.3.0/capture.json";
import updates from "../public/native/0.4.0/capture.json";
import unread from "../public/native/0.6.0/capture.json";
import calls from "../public/native/0.7.0/capture.json";
import share from "../public/native/0.8.0/capture.json";
import history from "../public/native/0.9.0/capture.json";
import archive from "../public/native/0.10.0/capture.json";
import spaces from "../public/native/0.11.0/capture.json";
import siteColors from "../public/native/0.12.0/capture.json";
import drop from "../public/native/0.14.0/capture.json";

const sources: Record<
  string,
  { assets: { file: string; width: number; height: number; rectPoints: number[] }[] }
> = {
  "0.1.0": browser,
  "0.1.3": pins,
  "0.2.0": edges,
  "0.3.0": settings,
  "0.4.0": updates,
  "0.6.0": unread,
  "0.7.0": calls,
  "0.8.0": share,
  "0.9.0": history,
  "0.10.0": archive,
  "0.11.0": spaces,
  "0.12.0": siteColors,
  "0.14.0": drop,
};

export const useSeconds = () => useCurrentFrame() / useVideoConfig().fps;
export const phase = (time: number, start: number, duration: number) =>
  Math.max(0, Math.min(1, (time - start) / duration));
// Motion Prompt #009 · MIT License (c) 2026 Shohei Ohtaki · https://showheyohtaki.github.io/motion-prompt/#009
// Short pointer paths need a modest peak speed; camera moves use the same easing family.
const cameraEase = Easing.bezier(0.65, 0, 0.35, 1);
export const glide = (time: number, start: number, duration: number, from: number, to: number) =>
  from + (to - from) * cameraEase(phase(time, start, duration));
// Motion Prompt #005 · MIT License (c) 2026 Shohei Ohtaki · https://showheyohtaki.github.io/motion-prompt/#005
export const reveal = (time: number, start: number, duration = 0.65) =>
  1 - (1 - phase(time, start, duration)) ** 5;

export const Stage = ({
  children,
  motion = false,
}: {
  children: React.ReactNode;
  motion?: boolean;
}) => (
  <AbsoluteFill
    style={{
      background: motion
        ? "radial-gradient(ellipse at 50% 0%, #282333 0%, #101014 72%)"
        : "#15151b",
      overflow: "hidden",
    }}
  >
    {children}
  </AbsoluteFill>
);

// Compositing positions captured pixels; it never draws or enlarges a product control past its source resolution.
export const nativeAsset = (version: string, file: string) => {
  const asset = sources[version].assets.find((a) => a.file === `${file}.png`);
  if (!asset) throw Error(`Missing native shot ${version}/${file}`);
  return asset;
};

export const NativePixels = ({
  version,
  file,
  width = 1660,
  maxHeight = 940,
  x = 960,
  y = 540,
  style = {},
}: {
  version: string;
  file: string;
  width?: number;
  maxHeight?: number;
  x?: number;
  y?: number;
  style?: CSSProperties;
}) => {
  const asset = nativeAsset(version, file);
  const w = Math.min(width, asset.width, (maxHeight * asset.width) / asset.height);
  const h = (w * asset.height) / asset.width;
  return (
    <CanvasImage
      src={staticFile(`native/${version}/${asset.file}`)}
      style={{
        position: "absolute",
        left: x - w / 2,
        top: y - h / 2,
        width: w,
        height: h,
        ...style,
      }}
    />
  );
};

// Three mattes reveal the captured new row while the captured rows below it move by its exact native height.
export const InsertedRow = ({
  version,
  before,
  after,
  insertionY,
  progress,
  top,
  width = 1440,
}: {
  version: string;
  before: string;
  after: string;
  insertionY: number;
  progress: number;
  top: number;
  width?: number;
}) => {
  const old = nativeAsset(version, before),
    image = nativeAsset(version, after);
  const height = (image.height * width) / image.width;
  const oldHeight = (old.height * width) / old.width;
  const added = height - oldHeight;
  const line = ((insertionY - image.rectPoints[1]) * width) / image.rectPoints[2];
  if (added <= 0 || width > image.width || old.rectPoints[2] !== image.rectPoints[2])
    throw Error("Row insertion requires aligned native sources");
  const common = { version, file: after, width, maxHeight: height, x: width / 2, y: height / 2 };
  if (progress >= 1)
    return (
      <NativePixels
        version={version}
        file={after}
        width={width}
        maxHeight={height}
        style={{ top, borderRadius: 26 }}
      />
    );
  return (
    <div
      style={{
        position: "absolute",
        left: 960 - width / 2,
        top,
        width,
        height: oldHeight + added * progress,
        overflow: "hidden",
        borderRadius: 26,
      }}
    >
      <NativePixels {...common} style={{ clipPath: `inset(0 0 ${height - line}px 0)` }} />
      <NativePixels
        {...common}
        style={{ clipPath: `inset(${line}px 0 ${height - line - added * progress}px 0)` }}
      />
      <NativePixels
        {...common}
        style={{
          clipPath: `inset(${line + added}px 0 0 0)`,
          transform: `translateY(${(progress - 1) * added}px)`,
        }}
      />
    </div>
  );
};

export const Pointer = ({
  x,
  y,
  time,
  click = -10,
  opacity = 1,
}: {
  x: number;
  y: number;
  time: number;
  click?: number;
  opacity?: number;
}) => {
  const press = phase(time, click, 0.24);
  const ring = phase(time, click, 0.34);
  return (
    <div style={{ position: "absolute", left: x, top: y, opacity, pointerEvents: "none" }}>
      {ring > 0 && ring < 1 ? (
        <div
          style={{
            position: "absolute",
            width: 58,
            height: 58,
            left: -29,
            top: -29,
            border: "2px solid rgba(226,217,255,.7)",
            borderRadius: "50%",
            opacity: 1 - ring,
            transform: `scale(${0.25 + ring})`,
          }}
        />
      ) : null}
      <svg
        width="46"
        height="64"
        viewBox="0 0 26 36"
        style={{
          transformOrigin: "0 0",
          transform: `scale(${1 - 0.12 * Math.sin(Math.PI * press)})`,
          filter: "drop-shadow(0 2px 3px rgba(0,0,0,.45))",
        }}
      >
        <path
          d="M2 2v28l7.1-7.1 5.3 11.2 5-2.4-5.4-10.9H24L2 2Z"
          fill="white"
          stroke="#15151b"
          strokeWidth="1.8"
          strokeLinejoin="round"
        />
      </svg>
    </div>
  );
};
