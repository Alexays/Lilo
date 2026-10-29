/* @jsxImportSource react */
import { useEffect, useState } from "react";
import type { CSSProperties } from "react";
import {
  AbsoluteFill,
  Composition,
  Easing,
  Freeze,
  Html5Audio,
  Img,
  OffthreadVideo,
  Sequence,
  Still,
  cancelRender,
  continueRender,
  delayRender,
  interpolate,
  registerRoot,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";

import type { NativeCaptureSource } from "./presentation.ts";
import { storyTiming } from "./timing.ts";

const outputScale = 1.25;

const ease = {
  easing: Easing.bezier(0.22, 1, 0.36, 1),
  extrapolateLeft: "clamp",
  extrapolateRight: "clamp",
} as const;

const background =
  "radial-gradient(ellipse at 30% 20%, #f8f7ff 0%, #eeedfb 46%, #d9d5f5 100%)";

const Canvas = ({ children }: { children: React.ReactNode }) => (
  <AbsoluteFill style={{ background }}>
    <div
      style={{
        height: 800,
        position: "absolute",
        transform: `scale(${outputScale})`,
        transformOrigin: "top left",
        width: 1280,
      }}
    >
      {children}
    </div>
  </AbsoluteFill>
);

type NativeMedia =
  | NativeCaptureSource["captures"][number]
  | NativeCaptureSource["footage"];

const NativeCrop = ({
  media,
  crop,
  width,
  style,
  startAt = 0,
}: {
  media: NativeMedia;
  crop: [number, number, number, number];
  width: number;
  style?: CSSProperties;
  startAt?: number;
}) => {
  const [x, y, w, h] = crop;

  const scale = width / w;

  const isVideo = "nativePixelScale" in media;

  const nativePixels = Math.min(
    media.width / media.logicalWidth,
    media.height / media.logicalHeight,
    isVideo ? media.nativePixelScale : Infinity
  );

  if (
    width * outputScale > w * nativePixels ||
    x < 0 ||
    y < 0 ||
    x + w > media.logicalWidth ||
    y + h > media.logicalHeight
  ) {
    throw new Error(
      `Native crop would enlarge or escape its source pixels: ${media.file}`
    );
  }

  const imageStyle: CSSProperties = {
    height: media.logicalHeight * scale,
    left: -x * scale,
    maxWidth: "none",
    position: "absolute",
    top: -y * scale,
    width: media.logicalWidth * scale,
  };

  return (
    <div
      style={{
        background: "white",
        borderRadius: 20,
        boxShadow: "0 22px 64px #43367a25, 0 2px 8px #43367a16",
        height: h * scale,
        overflow: "hidden",
        position: "absolute",
        width,
        ...style,
      }}
    >
      {isVideo ? (
        <OffthreadVideo
          src={staticFile(media.file)}
          trimBefore={startAt}
          muted
          style={imageStyle}
        />
      ) : (
        <Img alt="" src={staticFile(media.file)} style={imageStyle} />
      )}
    </div>
  );
};

const useNativeSource = () => {
  const [source, setSource] = useState<NativeCaptureSource>();

  const [handle] = useState(() =>
    delayRender("Load fresh verified native capture")
  );

  useEffect(() => {
    fetch(staticFile("native-source.json"))
      .then((response) => response.json())
      .then((native: NativeCaptureSource) => {
        setSource(native);

        return continueRender(handle);
      })
      .catch(cancelRender);
  }, [handle]);

  return source;
};

const AudioCard = () => {
  const source = useNativeSource();

  if (!source) {
    return null;
  }

  const audio = source.captures.find(
    (item) => item.checkpoint === "audio-ready"
  );

  if (!audio) {
    throw new Error("Missing native audio controls");
  }

  const tools = audio.regions[".tab-share-tools"];

  const note = audio.regions[".tab-share-note"];

  return (
    <Canvas>
      <NativeCrop
        media={audio}
        crop={audio.regions[".tab-share-panel"]}
        width={1080}
        style={{
          left: 100,
          opacity: 0.6,
          top: 65,
          transform: "perspective(1800px) rotateY(-6deg) rotateZ(-2deg)",
        }}
      />
      <NativeCrop
        media={audio}
        crop={[tools[0] + tools[2] - 292, tools[1] - 8, 300, tools[3] + 16]}
        width={880}
        style={{
          borderRadius: 20,
          boxShadow: "0 28px 90px #43367a35, 0 0 0 1px #ffffff",
          left: 200,
          top: 440,
        }}
      />
      <NativeCrop
        media={audio}
        crop={[note[0] - 4, note[1] - 4, 420, note[3] + 8]}
        width={1000}
        style={{ borderRadius: 8, boxShadow: "none", left: 140, top: 650 }}
      />
    </Canvas>
  );
};

const SharingScene = ({ source }: { source: NativeCaptureSource }) => {
  const frame = useCurrentFrame();

  const { fps } = useVideoConfig();

  const seconds = frame / fps;

  const timing = storyTiming(source);

  const picker = source.captures.find(
    (item) =>
      item.checkpoint === (seconds < 2.5 ? "picker-open" : "search-finds-brief")
  );

  let cardName = "call-card-names-brief";

  if (seconds >= timing.switchedAt) {
    cardName = "share-switched-to-agenda";
  } else if (seconds >= timing.shownAt) {
    cardName = "share-shown-tab-available";
  }

  const card = source.captures.find((item) => item.checkpoint === cardName);

  if (!picker || !card) {
    throw new Error("Missing native story states");
  }

  const panel = picker.regions[".tab-share-panel"];

  const cardCrop = card.regions[".call-card"];

  return (
    <>
      <Html5Audio src={staticFile("soundtrack.wav")} />
      <Canvas>
        {seconds < 5.8 && (
          <NativeCrop
            media={picker}
            crop={[panel[0] + 10, panel[1] + 57, 430, 230]}
            width={1080}
            style={{
              left: 100,
              opacity: interpolate(frame, [4.8 * fps, 5.8 * fps], [1, 0], ease),
              top: 112,
              transform: `translateX(${interpolate(frame, [4.8 * fps, 5.8 * fps], [0, -620], ease)}px) translateY(${interpolate(frame, [0, 1.2 * fps], [65, 0], ease)}px) rotateY(${interpolate(frame, [0, 1.2 * fps], [-8, 0], ease)}deg)`,
            }}
          />
        )}
        <Sequence from={Math.round(5.4 * fps)} layout="none">
          <Freeze
            frame={Math.min(
              Math.max(0, frame - Math.round(5.4 * fps)),
              Math.round(timing.holdAfter * fps)
            )}
          >
            <NativeCrop
              media={source.footage}
              startAt={Math.round((timing.clipStart / 1000) * fps)}
              crop={[
                270,
                70,
                Math.min(850, source.footage.logicalWidth - 270),
                Math.min(650, source.footage.logicalHeight - 70),
              ]}
              width={650}
              style={{
                left: 490,
                opacity: interpolate(
                  frame,
                  [5.4 * fps, 6.2 * fps],
                  [0, 1],
                  ease
                ),
                top: 270,
                transform: `translateX(${interpolate(frame, [5.4 * fps, 6.2 * fps], [360, 0], ease)}px) rotateY(-6deg) rotateZ(2deg)`,
              }}
            />
          </Freeze>
        </Sequence>
        {seconds >= 4.8 && (
          <NativeCrop
            media={card}
            crop={cardCrop}
            width={760}
            style={{
              left: 115,
              opacity: interpolate(frame, [4.8 * fps, 5.6 * fps], [0, 1], ease),
              top: 120,
              transform: `translateX(${interpolate(frame, [4.8 * fps, 5.9 * fps], [620, 0], ease)}px) rotateY(${interpolate(frame, [4.8 * fps, 5.9 * fps], [8, 0], ease)}deg)`,
            }}
          />
        )}
      </Canvas>
    </>
  );
};

const Sharing = () => {
  const source = useNativeSource();

  return source ? <SharingScene source={source} /> : null;
};

const Root = () => (
  <>
    <Still id="Audio080" component={AudioCard} width={1600} height={1000} />
    <Composition
      id="Sharing080"
      component={Sharing}
      width={1600}
      height={1000}
      fps={60}
      durationInFrames={840}
    />
  </>
);

registerRoot(Root);
