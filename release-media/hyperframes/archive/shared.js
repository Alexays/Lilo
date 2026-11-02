window.pressPointer = (timeline, selector, seconds) => {
  timeline
    .fromTo(
      `${selector} svg`,
      { scale: 1 },
      { scale: 0.88, duration: 0.07, ease: "power2.out" },
      seconds,
    )
    .to(`${selector} svg`, { scale: 1, duration: 0.15, ease: "power2.out" }, seconds + 0.07);
};

window.showEnding = (timeline, seconds) => {
  timeline
    .fromTo(
      "#end-wipe",
      { clipPath: "inset(100% 0 0 0)" },
      { clipPath: "inset(0% 0 0 0)", duration: 0.55, ease: "power3.inOut" },
      seconds,
    )
    .fromTo(
      "#end-mark",
      { opacity: 0, y: 150 },
      { opacity: 1, y: 0, duration: 0.7, ease: "expo.out" },
      seconds + 0.1,
    )
    .fromTo(
      "#end-brand",
      { opacity: 0, x: -36 },
      { opacity: 1, x: 0, duration: 0.55, ease: "power4.out" },
      seconds + 0.3,
    )
    .fromTo(
      "#end-version",
      { opacity: 0 },
      { opacity: 1, duration: 0.3, ease: "none" },
      seconds + 0.45,
    )
    .fromTo(
      "#end-caption",
      { opacity: 0 },
      { opacity: 1, duration: 0.35, ease: "none" },
      seconds + 0.65,
    );
};
