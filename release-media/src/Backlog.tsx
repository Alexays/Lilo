import React from "react";
import { Audio } from "@remotion/media";
import { staticFile } from "remotion";
import {
  InsertedRow,
  NativePixels,
  Pointer,
  Stage,
  glide,
  nativeAsset,
  phase,
  reveal,
  useSeconds,
} from "./Motion";
import archiveCapture from "../public/native/0.10.0/capture.json";
import dropCapture from "../public/native/0.14.0/capture.json";

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

export const PinnedTabs = () => {
  const t = useSeconds();
  const letter = Math.max(0, Math.min(6, Math.floor((t - 1.3) / 0.16) + 1));
  const file = t < 0.94 ? "pinned" : t < 3 ? `rename-${letter}` : "renamed";
  const width = glide(t, 0.15, 0.7, 1400, 1620) - glide(t, 3.3, 0.7, 0, 160);
  return (
    <Stage motion>
      <NativePixels
        version="0.1.3"
        file={file}
        width={width}
        y={540 + (1 - reveal(t, 0)) * 90}
        style={{ borderRadius: 24 }}
      />
      <Pointer
        time={t}
        x={glide(t, 0.3, 0.5, 1540, 735)}
        y={glide(t, 0.3, 0.5, 800, 540)}
        click={0.9}
        opacity={reveal(t, 0.25, 0.15) * (1 - phase(t, 2.65, 0.2))}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={48} volume={0.3} />
      <Audio src={staticFile("audio/mouse-click.wav")} from={54} volume={0.3} />
      {[0, 1, 2, 3, 4, 5].map((i) => (
        <Audio
          key={i}
          src={staticFile("audio/mouse-click.wav")}
          from={Math.round((1.3 + i * 0.16) * 60)}
          volume={0.065}
        />
      ))}
      <Audio src={staticFile("audio/switch.wav")} from={180} volume={0.28} />
    </Stage>
  );
};

export const Calls = () => {
  const t = useSeconds();
  const close = reveal(t, 0.65);
  const width = 291 + 1219 * close - glide(t, 4.35, 0.7, 0, 40);
  const file = t < 1.96 ? "connected" : t < 3.51 ? "muted" : "camera-off";
  return (
    <Stage motion>
      <NativePixels
        version="0.7.0"
        file="browsing"
        width={1660}
        style={{ opacity: 1 - close * 0.84 }}
      />
      <NativePixels
        version="0.7.0"
        file={file}
        width={width}
        x={365 + 595 * close}
        y={913 - 373 * close}
        style={{ opacity: phase(t, 0.65, 0.06), borderRadius: 28 }}
      />
      <Pointer
        time={t}
        x={glide(t, 1.25, 0.5, 1600, 1161) + glide(t, 2.75, 0.55, 0, 153)}
        y={glide(t, 1.25, 0.5, 820, 540)}
        click={t < 2.7 ? 1.9 : 3.45}
        opacity={reveal(t, 1.2, 0.15) * (1 - phase(t, 3.9, 0.2))}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={114} volume={0.35} />
      <Audio src={staticFile("audio/mouse-click.wav")} from={207} volume={0.35} />
    </Stage>
  );
};

export const TabShare = () => {
  const t = useSeconds();
  const focus = reveal(t, 1.1);
  const choose = reveal(t, 2.7);
  const share = reveal(t, 3.65);
  const letter = Math.max(0, Math.min(5, Math.floor((t - 1.9) / 0.15) + 1));
  return (
    <Stage motion>
      {t < 3.9 ? (
        <NativePixels
          version="0.8.0"
          file={t < 2 ? "picker" : "filtered"}
          width={1740}
          y={540 + (1 - reveal(t, 0)) * 80}
          style={{
            top: 137.5 + (1 - reveal(t, 0)) * 80,
            opacity: (1 - focus * 0.88) * (1 - share),
            borderRadius: 28,
          }}
        />
      ) : null}
      {t >= 1.1 && t < 3.65 ? (
        <NativePixels
          version="0.8.0"
          file={`search-${letter}`}
          width={1643 + 1797 * focus}
          maxHeight={400}
          x={960 + 930 * focus}
          y={338.4 + 46.6 * focus}
          style={{ opacity: (1 - phase(t, 2.8, 0.25)) * phase(t, 1.1, 0.08), borderRadius: 26 }}
        />
      ) : null}
      {t >= 2.7 && t < 4 ? (
        <NativePixels
          version="0.8.0"
          file="match"
          width={397 + 380 * choose}
          maxHeight={700}
          x={333 + 627 * choose}
          y={563 + 7 * choose}
          style={{ opacity: phase(t, 2.7, 0.08) * (1 - phase(t, 3.65, 0.2)), borderRadius: 30 }}
        />
      ) : null}
      {t >= 3.65 ? (
        <NativePixels
          version="0.8.0"
          file={t < 5.08 ? "sharing" : "switched"}
          width={1560}
          y={540 + (1 - share) * 180}
          style={{
            opacity: phase(t, 3.65, 0.08),
            clipPath: `inset(${(1 - share) * 100}% 0 0 0 round 30px)`,
          }}
        />
      ) : null}
      <Pointer
        time={t}
        x={t < 3.6 ? glide(t, 0.45, 0.5, 1490, 580) : glide(t, 4.25, 0.5, 1610, 1266)}
        y={t < 3.6 ? glide(t, 0.45, 0.5, 780, 337) : glide(t, 4.25, 0.5, 890, 637)}
        click={t < 3.6 ? 1 : 5}
        opacity={
          t < 3.6
            ? reveal(t, 0.4, 0.15) * (1 - phase(t, 1.65, 0.2))
            : reveal(t, 4.2, 0.15) * (1 - phase(t, 5.55, 0.2))
        }
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={60} volume={0.3} />
      {[0, 1, 2, 3, 4].map((i) => (
        <Audio
          key={i}
          src={staticFile("audio/mouse-click.wav")}
          from={Math.round((1.9 + i * 0.15) * 60)}
          volume={0.06}
        />
      ))}
      <Audio src={staticFile("audio/switch.wav")} from={219} volume={0.28} />
      <Audio src={staticFile("audio/mouse-click.wav")} from={300} volume={0.35} />
    </Stage>
  );
};

export const History = () => {
  const t = useSeconds();
  const letter = Math.max(0, Math.min(6, Math.floor((t - 1.45) / 0.16) + 1));
  const filtered = phase(t, 2.82, 0.18);
  const shrink =
    100 * (1 - nativeAsset("0.9.0", "filtered-rows").height / nativeAsset("0.9.0", "rows").height);
  const top = 465 + (1 - reveal(t, 0.25)) * 130 - glide(t, 2.65, 0.65, 0, 20);
  return (
    <Stage motion>
      <NativePixels
        version="0.9.0"
        file={`search-${letter}`}
        width={1440}
        y={315 + (1 - reveal(t, 0.1)) * 85}
        style={{ borderRadius: 28 }}
      />
      <NativePixels
        version="0.9.0"
        file="rows"
        width={1580}
        maxHeight={900}
        style={{
          top,
          opacity: reveal(t, 0.25, 0.25) * (1 - filtered),
          clipPath: `inset(0 0 ${shrink * reveal(t, 2.6, 0.45)}% 0 round 22px)`,
          borderRadius: 22,
        }}
      />
      {t >= 2.82 ? (
        <NativePixels
          version="0.9.0"
          file="filtered-rows"
          width={1580}
          maxHeight={900}
          style={{ top, opacity: filtered, borderRadius: 22 }}
        />
      ) : null}
      <Pointer
        time={t}
        x={glide(t, 0.5, 0.5, 1530, 720)}
        y={glide(t, 0.5, 0.5, 760, 315)}
        click={1.05}
        opacity={reveal(t, 0.45, 0.15) * (1 - phase(t, 1.4, 0.2))}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={63} volume={0.3} />
      {[0, 1, 2, 3, 4, 5].map((i) => (
        <Audio
          key={i}
          src={staticFile("audio/mouse-click.wav")}
          from={Math.round((1.45 + i * 0.16) * 60)}
          volume={0.065}
        />
      ))}
      <Audio src={staticFile("audio/switch.wav")} from={156} volume={0.22} />
    </Stage>
  );
};

export const Archive = () => {
  const t = useSeconds();
  const open = reveal(t, 1);
  const restored = reveal(t, 3.1, 0.45);
  return (
    <Stage motion>
      {t < 3.1 ? (
        <NativePixels
          version="0.10.0"
          file="before"
          width={1440}
          y={500 - 100 * open}
          style={{ opacity: 1 - open * 0.88, borderRadius: 26 }}
        />
      ) : null}
      {t >= 1 && t < 3.4 ? (
        <NativePixels
          version="0.10.0"
          file="archive"
          width={1440}
          y={540 + (1 - open) * 150}
          style={{
            clipPath: `inset(${(1 - open) * 100}% 0 0 0 round 56px)`,
            opacity: 1 - phase(t, 3.1, 0.2),
          }}
        />
      ) : null}
      {t >= 3.1 ? (
        <InsertedRow
          version="0.10.0"
          before="before"
          after="restored"
          width={1440}
          top={300 - 40 * restored}
          progress={restored}
          insertionY={archiveCapture.checks.insertionY}
        />
      ) : null}
      <Pointer
        time={t}
        x={t < 1.2 ? glide(t, 0.25, 0.6, 1510, 1370) : glide(t, 1.7, 0.6, 1370, 800)}
        y={t < 1.2 ? glide(t, 0.25, 0.6, 800, 581) : glide(t, 1.7, 0.6, 581, 465)}
        click={t < 1.2 ? 0.95 : 3}
        opacity={reveal(t, 0.2, 0.15) * (1 - phase(t, 3.2, 0.2))}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={57} volume={0.3} />
      <Audio src={staticFile("audio/mouse-click.wav")} from={180} volume={0.3} />
      <Audio src={staticFile("audio/switch.wav")} from={186} volume={0.25} />
    </Stage>
  );
};

export const Drop = () => {
  const t = useSeconds();
  const dragging = t >= 0.85 && t < 2.15;
  const inserted = reveal(t, 2.15, 0.45);
  const source = nativeAsset("0.14.0", "before");
  const scale = 1440 / source.rectPoints[2];
  const point = dropCapture.checks.insertionPoint;
  const x = glide(t, 1, 0.85, 1500, 240 + (point.x - source.rectPoints[0]) * scale - 153.5);
  const y = glide(t, 1, 0.85, 290, 280 + (point.y - source.rectPoints[1]) * scale - 23.5);
  return (
    <Stage motion>
      {t < 2.15 ? (
        <NativePixels
          version="0.14.0"
          file={t < 1.7 ? "before" : "target"}
          width={1440}
          style={{ top: 280, borderRadius: 26 }}
        />
      ) : (
        <InsertedRow
          version="0.14.0"
          before="before"
          after="dropped"
          insertionY={dropCapture.checks.insertionY}
          progress={inserted}
          top={280 - 40 * inserted}
        />
      )}
      {t < 2.4 ? (
        <NativePixels
          version="0.14.0"
          file="link"
          width={430}
          x={x}
          y={y}
          style={{
            opacity: 1 - phase(t, 2.15, 0.2),
            borderRadius: 22,
            transform: `rotate(${-3 * (dragging ? Math.sin(Math.PI * phase(t, 1, 0.85)) : 0)}deg)`,
            boxShadow: dragging ? "0 24px 60px #0006" : "none",
          }}
        />
      ) : null}
      <Pointer
        time={t}
        x={x + 150}
        y={y + 20}
        click={t < 1 ? 0.85 : 2.15}
        opacity={reveal(t, 0.2, 0.2) * (1 - phase(t, 2.4, 0.2))}
      />
      <Audio src={staticFile("audio/mouse-click.wav")} from={51} volume={0.3} />
      <Audio src={staticFile("audio/switch.wav")} from={129} volume={0.3} />
    </Stage>
  );
};

export const TabEdges = () => {
  const t = useSeconds();
  const poses = ["left", "right", "top", "bottom"];
  return (
    <Stage motion>
      {poses.map((file, i) => {
        const start = i * 1.75;
        const enter = reveal(t, start);
        const exit = i === poses.length - 1 ? 0 : phase(t, start + 1.75, 0.4);
        if (t < start || exit === 1) return null;
        return (
          <NativePixels
            key={file}
            version="0.2.0"
            file={file}
            width={glide(t, start, 0.75, 1540, 1740)}
            maxHeight={1030}
            x={960 + (1 - enter) * 180 - exit * 80}
            style={{
              opacity: i === 0 ? 1 : phase(t, start, 0.15),
              clipPath: `inset(0 ${(1 - enter) * 100}% 0 0 round 20px)`,
            }}
          />
        );
      })}
      {[1.75, 3.5, 5.25].map((second) => (
        <Audio
          key={second}
          src={staticFile("audio/switch.wav")}
          from={Math.round(second * 60)}
          volume={0.28}
        />
      ))}
    </Stage>
  );
};

export const Spaces = () => {
  const t = useSeconds();
  const glass = phase(t, 1.79, 0.16);
  const grain = phase(t, 3.54, 0.16);
  const out = reveal(t, 4.5);
  const width = 1408 + 242 * out;
  const y = 480 + 60 * out;
  return (
    <Stage motion>
      <div style={{ opacity: 1 - out * 0.6 }}>
        <NativePixels version="0.11.0" file="solid-window" width={width} maxHeight={1040} y={y} />
        <NativePixels
          version="0.11.0"
          file="glass-window"
          width={width}
          maxHeight={1040}
          y={y}
          style={{ opacity: glass }}
        />
        <NativePixels
          version="0.11.0"
          file="grain-window"
          width={width}
          maxHeight={1040}
          y={y}
          style={{ opacity: grain }}
        />
      </div>
      {["solid", "glass", "grain"].map((material, index) => (
        <NativePixels
          key={material}
          version="0.11.0"
          file={`${material}-controls`}
          width={1420 + 90 * out}
          y={875 + (1 - reveal(t, 0.25)) * 120 - out * 335}
          style={{
            clipPath: `inset(${(1 - reveal(t, 0.25)) * 100}% 0 0 0 round 999px)`,
            opacity: phase(t, 0.25, 0.08) * (index === 0 ? 1 : index === 1 ? glass : grain),
          }}
        />
      ))}
      <Pointer
        time={t}
        x={glide(t, 1.05, 0.55, 1670, 960) + glide(t, 2.75, 0.55, 0, 474)}
        y={glide(t, 1.05, 0.55, 1030, 875)}
        click={t < 2.7 ? 1.75 : 3.5}
        opacity={reveal(t, 1, 0.15) * (1 - phase(t, 3.95, 0.2))}
      />
      <Audio src={staticFile("audio/switch.wav")} from={105} volume={0.35} />
      <Audio src={staticFile("audio/switch.wav")} from={210} volume={0.35} />
    </Stage>
  );
};
