import React from "react";
import { AbsoluteFill, CanvasImage, Composition, Still, registerRoot, staticFile } from "remotion";
import icons from "../public/native/0.13.0/capture.json";
import {
  Archive,
  BrowserStill,
  Calls,
  Drop,
  History,
  PinnedTabs,
  SettingsStill,
  SiteColorsStill,
  Spaces,
  TabEdges,
  TabShare,
  UnreadStill,
  UpdateStill,
} from "./Backlog";

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
      durationInFrames={330}
    />
    <Composition
      id="tab-edges"
      component={TabEdges}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={432}
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
      durationInFrames={360}
    />
    <Composition
      id="tab-share"
      component={TabShare}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={396}
    />
    <Composition
      id="history"
      component={History}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={288}
    />
    <Composition
      id="archive"
      component={Archive}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={300}
    />
    <Composition
      id="spaces"
      component={Spaces}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={396}
    />
    <Still id="site-colors" component={SiteColorsStill} width={1920} height={1080} />
    <Still id="seasons" component={HolidayIcons} width={1920} height={1080} />
    <Composition
      id="drop"
      component={Drop}
      width={1920}
      height={1080}
      fps={60}
      durationInFrames={240}
    />
  </>
));
