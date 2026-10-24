<style>
  .tab-loader {
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 2px;
    width: 16px;
    height: 16px;
    contain: strict;
  }

  .tab-loader span {
    width: 3px;
    height: 3px;
    border-radius: 50%;
    /* Pull heavily toward text-primary so contrast is always guaranteed.
       With glow: branded tint. Without glow: near full text-primary. */
    background: color-mix(
      in srgb,
      var(--tab-glow, var(--text-primary)) 45%,
      var(--text-primary)
    );
    /* About 30 s of waves, then hold the resting frame: a load that never finishes must not
       keep WebKit's display link running forever. */
    animation: tab-loader-wave 1.1s ease-in-out 27 forwards;
    flex-shrink: 0;
  }

  .tab-loader span:nth-child(2) {
    animation-delay: 0.18s;
  }

  .tab-loader span:nth-child(3) {
    animation-delay: 0.36s;
  }

  @keyframes tab-loader-wave {
    0%, 80%, 100% {
      transform: scaleY(0.6);
      opacity: 0.55;
    }
    40% {
      transform: scaleY(1.5);
      opacity: 1;
    }
  }
</style>

<div class="tab-loader" aria-hidden="true">
  <span></span>
  <span></span>
  <span></span>
</div>
