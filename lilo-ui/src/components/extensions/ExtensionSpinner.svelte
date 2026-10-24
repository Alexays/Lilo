<!-- Small inline progress affordance shown while an extension action is in flight. -->
<span class="extension-spinner" aria-hidden="true">
  <svg viewBox="0 0 16 16" fill="none">
    <circle cx="8" cy="8" r="6.5" stroke="currentColor" stroke-width="1.6" opacity="0.22" />
    <path
      d="M8 1.5a6.5 6.5 0 0 1 6.5 6.5"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
    />
  </svg>
</span>

<style>
  .extension-spinner {
    display: inline-flex;
    width: 16px;
    height: 16px;
    flex-shrink: 0;
    color: var(--accent);
  }

  .extension-spinner svg {
    width: 100%;
    height: 100%;
    animation: extension-spinner-spin 0.7s linear infinite;
  }

  @keyframes extension-spinner-spin {
    to {
      transform: rotate(360deg);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .extension-spinner svg {
      animation-duration: 1.6s;
    }
  }
</style>
