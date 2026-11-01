import React from "react";
import type { CSSProperties } from "react";
import { Audio } from "@remotion/media";
import {
  AbsoluteFill,
  CanvasImage,
  interpolate,
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
import siteColors from "../public/native/0.12.0/capture.json";
import drop from "../public/native/0.14.0/capture.json";

const sources: Record<string, { assets: { file: string; width: number; height: number }[] }> = {
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
  "0.12.0": siteColors,
  "0.14.0": drop,
};
const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

// Only positions native pixels; every control, label and state comes from the compiled Lilo capture.
const NativePixels = ({
  version,
  file,
  width = 1660,
  maxHeight = 940,
  style = {},
}: {
  version: string;
  file: string;
  width?: number;
  maxHeight?: number;
  style?: CSSProperties;
}) => {
  const asset = sources[version].assets.find((a) => a.file === `${file}.png`);
  if (!asset) throw Error(`Missing native shot ${version}/${file}`);
  const w = Math.min(width, asset.width, (maxHeight * asset.width) / asset.height);
  return (
    <CanvasImage
      src={staticFile(`native/${version}/${asset.file}`)}
      style={{ position: "absolute", width: w, height: (w * asset.height) / asset.width, ...style }}
    />
  );
};
const Stage = ({ children }: { children: React.ReactNode }) => (
  <AbsoluteFill
    style={{
      backgroundColor: "#15151b",
      overflow: "hidden",
      alignItems: "center",
      justifyContent: "center",
    }}
  >
    {children}
  </AbsoluteFill>
);

export const BrowserStill = () => (
  <Stage>
    <NativePixels version="0.1.0" file="browser" />
  </Stage>
);
export const SettingsStill = () => (
  <Stage>
    <NativePixels version="0.3.0" file="settings-window" />
  </Stage>
);
export const UpdateStill = () => (
  <Stage>
    <NativePixels version="0.4.0" file="updates" width={1560} style={{ borderRadius: 36 }} />
  </Stage>
);
export const UnreadStill = () => (
  <Stage>
    <NativePixels version="0.6.0" file="unread" width={1460} style={{ borderRadius: 24 }} />
  </Stage>
);
export const SiteColorsStill = () => (
  <Stage>
    <NativePixels version="0.12.0" file="site-colors" />
  </Stage>
);

export const TabEdges = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  const edge = f < 2 * fps ? "left" : f < 4 * fps ? "right" : f < 6 * fps ? "top" : "bottom";
  return (
    <Stage>
      <NativePixels version="0.2.0" file={edge} width={1680} />
      {[2, 4, 6].map((second) => (
        <Audio key={second} src={staticFile("audio/switch.wav")} from={second * fps} volume={0.4} />
      ))}
    </Stage>
  );
};

export const PinnedTabs = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  const file = f < 2 * fps ? "pinned" : f < 4 * fps ? "renaming" : "renamed";
  return (
    <Stage>
      <NativePixels
        version="0.1.3"
        file={file}
        width={1560}
        style={{
          borderRadius: 24,
          translate: `0 ${interpolate(f, [0, 0.6 * fps], [14, 0], clamp)}px`,
        }}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={2 * fps} volume={0.4} />
      <Audio src={staticFile("audio/switch.wav")} from={4 * fps} volume={0.4} />
    </Stage>
  );
};

export const Calls = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  const close = interpolate(f, [0.8 * fps, 1.4 * fps], [0, 1], clamp);
  const file = f < 3 * fps ? "connected" : f < 5 * fps ? "muted" : "camera-off";
  return (
    <Stage>
      <NativePixels
        version="0.7.0"
        file="browsing"
        width={1680}
        style={{ opacity: 1 - close * 0.8 }}
      />
      <NativePixels
        version="0.7.0"
        file={file}
        width={1540}
        style={{ opacity: close, borderRadius: 32, translate: `0 ${(1 - close) * 24}px` }}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={3 * fps} volume={0.45} />
      <Audio src={staticFile("audio/mouse-click.wav")} from={5 * fps} volume={0.45} />
    </Stage>
  );
};

export const TabShare = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  const file =
    f < fps
      ? "picker"
      : f < 2 * fps
        ? "search-empty"
        : f < 3 * fps
          ? "search"
          : f < 4 * fps
            ? "match"
            : f < 6.5 * fps
              ? "sharing"
              : "switched";
  return (
    <Stage>
      {f >= fps && f < 4 * fps ? (
        <NativePixels version="0.8.0" file="filtered" width={1780} style={{ opacity: 0.15 }} />
      ) : null}
      <NativePixels
        version="0.8.0"
        file={file}
        width={file === "picker" ? 1780 : file === "match" ? 1300 : 1560}
        maxHeight={920}
        style={{ borderRadius: 26 }}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={2 * fps} volume={0.35} />
      <Audio src={staticFile("audio/switch.wav")} from={4 * fps} volume={0.4} />
      <Audio src={staticFile("audio/switch.wav")} from={6.5 * fps} volume={0.45} />
    </Stage>
  );
};

export const History = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  const close = interpolate(f, [fps, 1.5 * fps], [0, 1], clamp);
  return (
    <Stage>
      <NativePixels
        version="0.9.0"
        file={f < 3 * fps ? "history" : "filtered"}
        width={1780}
        style={{ opacity: 1 - close * 0.8 }}
      />
      <NativePixels
        version="0.9.0"
        file={f < 3 * fps ? "search-empty" : "search"}
        width={1480}
        style={{ opacity: close, borderRadius: 32 }}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={3 * fps} volume={0.4} />
    </Stage>
  );
};

export const Archive = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  return (
    <Stage>
      {f < 2 * fps ? (
        <NativePixels version="0.10.0" file="before" width={1470} style={{ borderRadius: 24 }} />
      ) : f < 4.5 * fps ? (
        <NativePixels version="0.10.0" file="archive" width={1630} style={{ borderRadius: 28 }} />
      ) : (
        <NativePixels version="0.10.0" file="restored" width={1470} style={{ borderRadius: 24 }} />
      )}
      <Audio src={staticFile("audio/mouse-click.wav")} from={2 * fps} volume={0.4} />
      <Audio src={staticFile("audio/switch.wav")} from={4.5 * fps} volume={0.4} />
    </Stage>
  );
};

export const Drop = () => {
  const f = useCurrentFrame(),
    { fps } = useVideoConfig();
  const file = f < 2 * fps ? "before" : f < 4 * fps ? "target" : "dropped";
  return (
    <Stage>
      <NativePixels version="0.14.0" file={file} width={1470} style={{ borderRadius: 24 }} />
      <Audio src={staticFile("audio/switch.wav")} from={4 * fps} volume={0.45} />
    </Stage>
  );
};
