import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { setTimeout } from "node:timers/promises";
import { fileURLToPath } from "node:url";

import { expect, test } from "@playwright/test";

import { parseReleaseStories } from "../src/lib/release-stories";
import { encodeRecording } from "./recording.ts";
import type { RecordingFrame } from "./recording.ts";
import { captureArchiveState, captureSourceDigest } from "./release-capture.ts";

const root = fileURLToPath(new URL("../../", import.meta.url));
const version = process.env.LILO_CAPTURE_VERSION ?? "";

if (!/^\d+\.\d+\.\d+$/u.test(version)) {
  throw new Error("Use make site-release-capture RELEASE=x.y.z");
}

const story = parseReleaseStories(
  readFileSync(`${root}/CHANGELOG.md`, "utf-8"),
  [
    JSON.parse(
      readFileSync(`${root}/site/src/content/releases/${version}.json`, "utf-8")
    ),
  ]
).get(version);

if (story?.capture.scenario !== "peek") {
  throw new Error(`No Peek capture scenario for release ${version}`);
}

const directory = `${root}/site/src/assets/releases/${version}`;

test("capture Peek without leaving the source tab", async ({ browser }) => {
  const sourceDigest = captureSourceDigest(root);

  const files: { name: string; pixels: Buffer }[] = [];
  const external: string[] = [];

  for (const lang of ["en", "fr"] as const) {
    for (const colorScheme of ["light", "dark"] as const) {
      // oxlint-disable-next-line no-await-in-loop -- Each capture gets a fresh, isolated demo session.
      const context = await browser.newContext({
        colorScheme,
        deviceScaleFactor: 2,
        locale: lang,
        reducedMotion: "no-preference",
        viewport: { height: 720, width: 1120 },
      });

      try {
        // oxlint-disable no-await-in-loop -- Capture the same ordered scenario in each locale and appearance.
        const page = await context.newPage();
        await page.route("**/*", (route) => {
          const url = route.request().url();

          if (new URL(url).origin === "http://127.0.0.1:8791") {
            return route.continue();
          }

          external.push(url);

          return route.abort();
        });
        await page.goto(`/demo/?lang=${lang}`);
        await expect(page.locator("#app")).toHaveAttribute(
          "data-version",
          version
        );
        await expect(page.locator(".repo-top")).toBeVisible();
        await page.locator(".new-tab-row:visible").click();
        const command = page.locator(".command-bar-input");
        await command.fill("https://guide.example.com/links");
        await command.press("Enter");

        const notes = page.locator(
          '.quick-links a[href="https://notes.example.com"]'
        );

        // Astro's development toolbar is not part of the shipped demo.
        await page.evaluate(() =>
          document.querySelector("astro-dev-toolbar")?.remove()
        );
        await page.evaluate(() => document.fonts.ready);
        await notes.hover();
        const frames: RecordingFrame[] = [];

        const frame = async (delay: number) => {
          frames.push({
            delay,
            image: await page.screenshot({ caret: "hide", scale: "css" }),
          });
        };

        const transition = async () => {
          for (let index = 0; index < 8; index += 1) {
            await frame(50);
            await setTimeout(50);
          }
        };

        await frame(800);
        await notes.click({ modifiers: ["Shift"] });
        await transition();
        const peek = page.getByRole("dialog", { exact: true, name: "Peek" });
        await expect(
          peek.getByRole("textbox", {
            exact: true,
            name: lang === "fr" ? "Vos notes" : "Your notes",
          })
        ).toBeVisible();
        await expect(
          page.getByRole("treeitem", { exact: true, name: "guide.example.com" })
        ).toHaveAttribute("aria-selected", "true");
        await frame(1600);
        await peek.getByRole("button").first().click();
        await transition();
        await expect(peek).toHaveCount(0);
        await frame(800);
        await notes.click({ modifiers: ["Shift"] });
        await transition();
        await expect(peek).toBeVisible();
        await frame(1600);
        files.push(
          {
            name: `peek-${lang}-${colorScheme}.png`,
            pixels: await page.screenshot({
              animations: "disabled",
              caret: "hide",
            }),
          },
          {
            name: `peek-${lang}-${colorScheme}.webp`,
            pixels: await encodeRecording(frames),
          }
        );
      } finally {
        await context.close();
        // oxlint-enable no-await-in-loop
      }
    }
  }

  expect(external).toEqual([]);

  if (
    captureArchiveState(directory) !== "missing" &&
    process.env.LILO_CAPTURE_REPLACE !== "1"
  ) {
    throw new Error("Archived captures exist; use RECAPTURE=1 to replace them");
  }

  mkdirSync(directory, { recursive: true });

  for (const file of files) {
    writeFileSync(`${directory}/${file.name}`, file.pixels);
  }

  writeFileSync(
    `${directory}/capture.json`,
    `${JSON.stringify(
      {
        durationMs: 6000,
        files: files.map((file) => file.name),
        height: 720,
        release: version,
        scenario: "peek",
        sourceDigest,
        sourceRevision: execFileSync("git", ["rev-parse", "HEAD"], {
          cwd: root,
          encoding: "utf-8",
        }).trim(),
        width: 1120,
      },
      null,
      2
    )}\n`
  );
});
