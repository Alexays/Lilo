/* @jsxImportSource react */
import { useEffect, useState } from "react";
import type { CSSProperties } from "react";
import {
  AbsoluteFill,
  Composition,
  Easing,
  Img,
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

interface Frame {
  atMs: number;
  file: string;
}

const ease = {
  easing: Easing.bezier(0.22, 1, 0.36, 1),
  extrapolateLeft: "clamp",
  extrapolateRight: "clamp",
} as const;

const background =
  "radial-gradient(ellipse at 30% 20%, #f8f7ff 0%, #eeedfb 46%, #d9d5f5 100%)";

const NativeCrop = ({
  src,
  crop,
  width,
  style,
}: {
  src: string;
  crop: [number, number, number, number];
  width: number;
  style?: CSSProperties;
}) => {
  const [x, y, w, h] = crop;
  const scale = width / w;

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
      <Img
        alt=""
        src={staticFile(src)}
        style={{
          height: 720 * scale,
          left: -x * scale,
          maxWidth: "none",
          position: "absolute",
          top: -y * scale,
          width: 1120 * scale,
        }}
      />
    </div>
  );
};

const Audio = () => (
  <AbsoluteFill style={{ background }}>
    <NativeCrop
      src="audio.png"
      crop={[350, 84, 680, 340]}
      width={1000}
      style={{
        filter: "blur(3px)",
        left: 140,
        opacity: 0.42,
        top: 90,
        transform:
          "perspective(1800px) rotateX(8deg) rotateY(-8deg) rotateZ(-3deg)",
      }}
    />
    <NativeCrop
      src="audio.png"
      crop={[735, 140, 285, 42]}
      width={1090}
      style={{
        borderRadius: 24,
        boxShadow: "0 28px 90px #43367a35, 0 0 0 1px #ffffff",
        left: 95,
        top: 437,
      }}
    />
    <NativeCrop
      src="audio.png"
      crop={[368, 183, 410, 25]}
      width={1000}
      style={{ borderRadius: 12, boxShadow: "none", left: 140, top: 637 }}
    />
  </AbsoluteFill>
);

const SharingScene = ({ timeline }: { timeline: Frame[] }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const seconds = frame / fps;
  let nativeTime = 8000;

  if (seconds < 2.8) {
    nativeTime = 1600;
  } else if (seconds < 4.8) {
    nativeTime = 1600 + (seconds - 2.8) * 1000;
  } else if (seconds < 6.4) {
    nativeTime = 4100;
  } else if (seconds < 8.5) {
    nativeTime = 5000 + (seconds - 6.4) * 1000;
  }

  const source = (
    timeline.findLast((item) => item.atMs <= nativeTime) ?? timeline[0]
  ).file;

  const picker = (
    timeline.findLast((item) => item.atMs <= Math.min(nativeTime, 3500)) ??
    timeline[0]
  ).file;

  const result = (
    timeline.findLast(
      (item) => item.atMs <= (nativeTime < 6506 ? 4100 : 8000)
    ) ?? timeline[0]
  ).file;

  return (
    <AbsoluteFill style={{ background, perspective: 1800 }}>
      {seconds < 5.7 && (
        <NativeCrop
          src={picker}
          crop={[360, 140, 430, 230]}
          width={1080}
          style={{
            left: 100,
            opacity: interpolate(frame, [4.8 * fps, 5.6 * fps], [1, 0], ease),
            top: 112,
            transform: `translateX(${interpolate(frame, [4.8 * fps, 5.7 * fps], [0, -620], ease)}px) translateY(${interpolate(frame, [0, 1.4 * fps], [80, 0], ease)}px) rotateX(${interpolate(frame, [0, 1.4 * fps], [10, 0], ease)}deg) rotateY(${interpolate(frame, [0, 1.4 * fps], [-12, 0], ease)}deg)`,
          }}
        />
      )}
      {seconds >= 4.8 && (
        <>
          <NativeCrop
            src={result}
            crop={[470, 190, 440, 345]}
            width={715}
            style={{
              left: 420,
              opacity: interpolate(
                frame,
                [4.8 * fps, 5.8 * fps],
                [0, 0.72],
                ease
              ),
              top: 335,
              transform: `translateX(${interpolate(frame, [4.8 * fps, 6 * fps], [500, 0], ease)}px) rotateY(-9deg) rotateZ(3deg)`,
            }}
          />
          <NativeCrop
            src={source}
            crop={[10, 589, 248, 67]}
            width={1060}
            style={{
              left: 110,
              opacity: interpolate(frame, [4.8 * fps, 5.5 * fps], [0, 1], ease),
              top: 127,
              transform: `translateX(${interpolate(frame, [4.8 * fps, 5.9 * fps], [620, 0], ease)}px) rotateY(${interpolate(frame, [4.8 * fps, 5.9 * fps], [12, 0], ease)}deg)`,
            }}
          />
        </>
      )}
    </AbsoluteFill>
  );
};

const Sharing = () => {
  const [timeline, setTimeline] = useState<Frame[]>([]);

  const [handle] = useState(() =>
    delayRender("Load verified native frame timing")
  );

  useEffect(() => {
    fetch(staticFile("timeline.json"))
      .then((response) => response.json())
      .then((frames: Frame[]) => {
        setTimeline(frames);

        return continueRender(handle);
      })
      .catch(cancelRender);
  }, [handle]);

  return timeline.length ? <SharingScene timeline={timeline} /> : null;
};

const Root = () => (
  <>
    <Still id="Audio080" component={Audio} width={1280} height={800} />
    <Composition
      id="Sharing080"
      component={Sharing}
      width={1280}
      height={800}
      fps={60}
      durationInFrames={840}
    />
  </>
);

registerRoot(Root);
