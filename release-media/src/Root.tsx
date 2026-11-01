import React from "react";
import { Audio } from "@remotion/media";
import {
  AbsoluteFill,
  CanvasImage,
  Composition,
  Still,
  interpolate,
  registerRoot,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import icons from "../public/native/0.13.0/capture.json";
import spaces from "../public/native/0.11.0/capture.json";
import {
  Archive,
  BrowserStill,
  Calls,
  Drop,
  History,
  PinnedTabs,
  SettingsStill,
  SiteColorsStill,
  TabEdges,
  TabShare,
  UnreadStill,
  UpdateStill,
} from "./Backlog";

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" } as const;

const Spaces = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const material = frame < 2.5 * fps ? "solid" : frame < 5 * fps ? "glass" : "grain";
  const window = frame >= 10 * fps ? "glass-space.png" : `${material}-window.png`;
  const controls = spaces.assets.find((a) => a.file === `${material}-controls.png`)!;
  const nativeWindow = spaces.assets.find((a) => a.file === window)!;
  const controlsOpacity = Math.min(
    interpolate(frame, [1.2 * fps, 1.7 * fps], [0, 1], clamp),
    interpolate(frame, [8.3 * fps, 8.9 * fps], [1, 0], clamp),
  );
  return (
    <AbsoluteFill
      style={{
        backgroundColor: "#101014",
        overflow: "hidden",
        justifyContent: "center",
        alignItems: "center",
      }}
    >
      <CanvasImage
        src={staticFile(`native/0.11.0/${window}`)}
        style={{
          position: "absolute",
          width: 1700,
          height: (1700 * nativeWindow.height) / nativeWindow.width,
          opacity: interpolate(frame, [0, 0.3 * fps], [0, 1], clamp) * (1 - controlsOpacity * 0.48),
          translate: `0 ${interpolate(frame, [0, 0.5 * fps], [12, 0], clamp)}px`,
        }}
      />
      <CanvasImage
        src={staticFile(`native/0.11.0/${controls.file}`)}
        style={{
          position: "absolute",
          width: controls.rectPoints[2] * 7.4,
          height: controls.rectPoints[3] * 7.4,
          borderRadius: 999,
          opacity: controlsOpacity,
          translate: `0 ${interpolate(frame, [1.2 * fps, 1.7 * fps], [22, 0], clamp)}px`,
        }}
      />
      <Audio src={staticFile("audio/switch.wav")} from={2.5 * fps} volume={0.55} />
      <Audio src={staticFile("audio/switch.wav")} from={5 * fps} volume={0.55} />
      <Audio src={staticFile("audio/switch.wav")} from={10 * fps} volume={0.4} />
    </AbsoluteFill>
  );
};

const HolidayIcons = () => (
  <AbsoluteFill
    style={{ backgroundColor: "#15151b", justifyContent: "center", alignItems: "center" }}
  >
    <div style={{ display: "flex", gap: 60 }}>
      {["halloween.png", "christmas.png", "easter.png"].map((file) => (
        <CanvasImage
          key={file}
          src={staticFile(`native/0.13.0/${icons.assets.find((a) => a.file === file)!.file}`)}
          style={{ width: 520, height: 520 }}
        />
      ))}
    </div>
  </AbsoluteFill>
);

registerRoot(() => (
  <>
    <Still id="browser" component={BrowserStill} width={1920} height={1080} />
    <Composition
      id="pinned-tabs"
      component={PinnedTabs}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={420}
    />
    <Composition
      id="tab-edges"
      component={TabEdges}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={510}
    />
    <Still id="settings" component={SettingsStill} width={1920} height={1080} />
    <Still id="updates" component={UpdateStill} width={1920} height={1080} />
    <Still id="unread" component={UnreadStill} width={1920} height={1080} />
    <Composition
      id="calls"
      component={Calls}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={480}
    />
    <Composition
      id="tab-share"
      component={TabShare}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={570}
    />
    <Composition
      id="history"
      component={History}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={420}
    />
    <Composition
      id="archive"
      component={Archive}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={420}
    />
    <Composition
      id="spaces"
      component={Spaces}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={720}
    />
    <Still id="site-colors" component={SiteColorsStill} width={1920} height={1080} />
    <Still id="seasons" component={HolidayIcons} width={1920} height={1080} />
    <Composition
      id="drop"
      component={Drop}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={420}
    />
  </>
));
