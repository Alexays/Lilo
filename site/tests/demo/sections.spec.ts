import { expect, test } from "@playwright/test";

for (const lang of ["en", "fr"] as const) {
  for (const mode of ["terminal", "mcp"] as const) {
    test(`${mode} toolbar keeps keyboard refresh and fullscreen with the Lilo logo (${lang})`, async ({
      page,
    }) => {
      await page.addInitScript(() => {
        Element.prototype.requestFullscreen = () =>
          Promise.reject(new Error("Fullscreen unavailable"));
      });
      await page.goto(lang === "fr" ? "/fr/" : "/");
      const demo = page.locator(`#${mode}-demo`);
      await demo.scrollIntoViewIfNeeded();
      const frame = page.frameLocator(`#${mode}-demo iframe`);
      await expect(
        frame.locator(
          mode === "terminal" ? ".terminal input" : ".agent-session .run"
        )
      ).toBeVisible();
      await expect(demo.locator(".demo-brand svg use").first()).toBeVisible();
      await expect(
        demo.locator(".mac-menubar, .demo-modes, [data-action=explore]")
      ).toHaveCount(0);
      await expect(demo.locator(".demo-menubar button")).toHaveCount(2);
      const expand = demo.locator("[data-action=fullscreen]");
      await expand.focus();
      await page.keyboard.press("Enter");
      await expect(demo).toHaveAttribute("data-expanded");
      await expect(page.locator(".site-header")).toHaveJSProperty(
        "inert",
        true
      );
      await page.keyboard.press("Escape");
      await expect(demo).not.toHaveAttribute("data-expanded");
      await expect(expand).toBeFocused();
      const reset = demo.locator("[data-action=reset]");
      await reset.focus();

      const reloaded = page.waitForEvent("framenavigated", {
        predicate: (child) => child.url().includes(`mode=${mode}`),
      });

      await page.keyboard.press("Enter");
      await reloaded;
      await expect(
        frame.locator(
          mode === "terminal" ? ".terminal input" : ".agent-session .run"
        )
      ).toBeVisible();
      await expect(page.locator("#browser-demo .demo-modes")).toHaveCount(1);
    });
  }

  test(`homepage sections, text and demos share the reference frame (${lang})`, async ({
    page,
  }) => {
    await page.goto(lang === "fr" ? "/fr/" : "/");

    for (const width of [390, 768, 1280, 1600]) {
      // oxlint-disable-next-line no-await-in-loop -- Check the same page at each responsive gutter.
      await page.setViewportSize({ height: 900, width });

      // oxlint-disable-next-line no-await-in-loop
      const frames = await page
        .locator(".home-page > section > .wrap, .foot-frame")
        .evaluateAll((elements) =>
          elements.map((element) => {
            const rect = element.getBoundingClientRect();

            return [rect.x, rect.width];
          })
        );

      for (const edges of frames) {
        expect(edges).toEqual(frames[0]);
      }

      // oxlint-disable-next-line no-await-in-loop
      const demos = await page.locator(".demo-shell").evaluateAll((elements) =>
        elements.map((element) => {
          const rect = element.getBoundingClientRect();

          return [rect.x, rect.width];
        })
      );

      for (const edges of demos) {
        expect(edges).toEqual(demos[0]);
      }

      // oxlint-disable-next-line no-await-in-loop
      const textEdges = await page
        .locator(
          "#hero .hero-content, .home-page > .band > .wrap > .head, .foot-brand"
        )
        .evaluateAll((elements) =>
          elements.map((element) => element.getBoundingClientRect().x)
        );

      for (const x of textEdges) {
        expect(x).toBe(textEdges[0]);
      }

      expect(
        // oxlint-disable-next-line no-await-in-loop
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth
        )
      ).toBe(true);
    }
  });

  for (const mode of ["terminal", "mcp"] as const) {
    test(`${mode} repeats without reloading and pauses offscreen and for Reduce Motion (${lang})`, async ({
      page,
    }) => {
      await page.emulateMedia({ reducedMotion: "no-preference" });
      await page.goto(lang === "fr" ? "/fr/" : "/");
      const demo = page.locator(`#${mode}-demo`);
      await demo.scrollIntoViewIfNeeded();
      const frame = page.frameLocator(`#${mode}-demo iframe`);
      const root = frame.locator("html");
      await expect(root).toHaveAttribute("data-showcase-cycle", "1");

      await (mode === "terminal"
        ? expect(frame.locator(".terminal input")).not.toHaveValue("")
        : expect(frame.locator(".agent-session")).toHaveAttribute(
            "data-agent-status",
            /running|waiting/u
          ));

      const navigations: string[] = [];
      page.on("framenavigated", (child) => {
        if (child.url().includes(`mode=${mode}`)) {
          navigations.push(child.url());
        }
      });
      await page.locator("#open-source").scrollIntoViewIfNeeded();
      await expect(root).toHaveAttribute("data-showcase", "paused");

      if (mode === "mcp") {
        await expect(frame.locator(".agent-session")).toHaveAttribute(
          "data-agent-status",
          "stopped"
        );
      }

      const content = frame.locator(
        mode === "terminal" ? ".terminal-output .xterm-rows" : ".launch-page"
      );

      const pausedText = await content.textContent();

      const pausedInput =
        mode === "terminal"
          ? await frame.locator(".terminal input").inputValue()
          : "";

      // Observe longer than a typing, command or approval delay to catch background playback.
      await page.waitForTimeout(1800);
      await expect(root).toHaveAttribute("data-showcase-cycle", "1");
      await expect(content).toHaveText(pausedText ?? "");

      if (mode === "terminal") {
        await expect(frame.locator(".terminal input")).toHaveValue(pausedInput);
      }

      await demo.scrollIntoViewIfNeeded();
      await expect(root).toHaveAttribute("data-showcase", "running");
      await expect(root).toHaveAttribute("data-showcase-cycle", "2", {
        timeout: 25_000,
      });

      if (mode === "mcp") {
        await expect(frame.locator(".prompt-actions")).toBeVisible({
          timeout: 15_000,
        });
        await expect(frame.locator(".published")).toBeEmpty();
      }

      expect(navigations).toEqual([]);
      await page.emulateMedia({ reducedMotion: "reduce" });
      await expect(root).toHaveAttribute("data-showcase", "paused");
    });
  }

  test(`section demos load on demand, run commands and request agent approval (${lang})`, async ({
    page,
  }) => {
    await page.goto(lang === "fr" ? "/fr/" : "/");
    const terminal = page.locator("#build .feature-demo iframe");
    const agent = page.locator("#agents .feature-demo iframe");
    await expect(terminal).not.toHaveAttribute("src");
    await expect(agent).not.toHaveAttribute("src");
    await page.locator("#build .feature-demo").scrollIntoViewIfNeeded();
    const terminalFrame = page.frameLocator("#build .feature-demo iframe");
    const input = terminalFrame.locator(".terminal input");
    await expect(input).toBeVisible();
    await expect(terminalFrame.locator("html")).toHaveAttribute(
      "data-showcase",
      "idle"
    );
    await input.fill("printf '# Changed in the section demo\\n' > README.md");
    await input.press("Enter");
    await expect(terminalFrame.locator(".workspace-file")).toContainText(
      "Changed in the section demo"
    );
    await expect(agent).not.toHaveAttribute("src");
    await page.locator("#agents .feature-demo").scrollIntoViewIfNeeded();
    await expect(terminalFrame.locator("html")).toHaveClass(/reduced-power/u);
    const agentFrame = page.frameLocator("#agents .feature-demo iframe");
    await expect(agentFrame.locator(".agent-session .run")).toBeEnabled();
    await agentFrame.locator(".agent-session .run").click();
    await expect(agentFrame.locator(".agent-session")).toHaveAttribute(
      "data-agent-status",
      "waiting",
      { timeout: 15_000 }
    );
    await expect(agentFrame.locator(".prompt-actions")).toBeVisible();
    await page.locator("#open-source").scrollIntoViewIfNeeded();
    await expect(agentFrame.locator(".agent-session")).toHaveAttribute(
      "data-agent-status",
      "stopped"
    );
  });

  test(`both installation panels copy independently (${lang})`, async ({
    page,
  }) => {
    await page.addInitScript(() => {
      Object.defineProperty(navigator, "clipboard", {
        value: { writeText: () => Promise.resolve() },
      });
    });
    await page.goto(lang === "fr" ? "/fr/" : "/");
    const hero = page.locator("#hero .install-panel");
    const end = page.locator("#open-source .install-panel");
    await hero.locator(".copy-command").click();
    await expect(hero.locator(".check-icon")).toBeVisible();
    await expect(end.locator(".copy-status")).toBeEmpty();
    await end.locator(".copy-command").click();
    await expect(end.locator(".check-icon")).toBeVisible();
  });

  test(`terminal walkthrough runs, refreshes and hands over on interaction (${lang})`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(lang === "fr" ? "/fr/" : "/");
    await page.locator("#build .feature-demo").scrollIntoViewIfNeeded();
    const frame = page.frameLocator("#build iframe");
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "running"
    );
    await expect(frame.locator(".terminal-output")).toContainText(
      "BUILT IN LILO",
      {
        timeout: 20_000,
      }
    );
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "done"
    );
    await expect(frame.locator(".workspace-file")).toContainText(
      "Built in Lilo"
    );
    await page.locator("#build .demo-tools [data-action=reset]").click();
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "running"
    );
    const input = frame.locator(".terminal input");
    await input.click();
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "stopped"
    );
    await input.fill("printf '# Your turn\\n' > README.md");
    await input.press("Enter");
    await expect(frame.locator(".workspace-file")).toContainText("Your turn");
  });

  test(`agent walkthrough shows approval and completes automatically (${lang})`, async ({
    page,
  }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(lang === "fr" ? "/fr/" : "/");
    await page.locator("#agents .feature-demo").scrollIntoViewIfNeeded();
    const frame = page.frameLocator("#agents iframe");
    await expect(frame.locator(".prompt-actions")).toBeVisible({
      timeout: 20_000,
    });
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "done",
      {
        timeout: 15_000,
      }
    );
    await expect(frame.locator(".agent-session")).toHaveAttribute(
      "data-agent-status",
      "done"
    );
    await expect(frame.locator(".published")).toBeVisible();
    await page.locator("#agents .demo-tools [data-action=reset]").click();
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "running"
    );
    await page.locator("#open-source").scrollIntoViewIfNeeded();
    await expect(frame.locator("html")).toHaveAttribute(
      "data-showcase",
      "paused"
    );
  });
}

for (const width of [390, 811, 1280]) {
  test(`pixel breathing pauses offscreen and respects Reduce Motion (${width}px)`, async ({
    page,
  }) => {
    await page.setViewportSize({ height: 900, width });
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto("/");
    const hero = page.locator("#hero .pixel-bloom");
    const end = page.locator("#open-source .pixel-bloom");
    await expect(hero).toHaveAttribute("data-active");
    await expect(hero.locator(".pixel-petal").first()).toHaveCSS(
      "animation-play-state",
      "running"
    );
    await expect(hero.locator(".pixel-petal").first()).toHaveCSS(
      "animation-duration",
      "3.2s"
    );
    await expect(end).not.toHaveAttribute("data-active");
    await page.locator("#open-source").scrollIntoViewIfNeeded();
    await expect(hero).not.toHaveAttribute("data-active");
    await expect(hero.locator(".pixel-petal").first()).toHaveCSS(
      "animation-play-state",
      "paused"
    );
    await expect(end).toHaveAttribute("data-active");
    await expect(end.locator(".pixel-petal").first()).toHaveCSS(
      "animation-play-state",
      "running"
    );
    await page.emulateMedia({ reducedMotion: "reduce" });
    await expect(end).not.toHaveAttribute("data-active");
    await expect(end.locator(".pixel-petal").first()).toHaveCSS(
      "animation-name",
      "none"
    );
  });
}
