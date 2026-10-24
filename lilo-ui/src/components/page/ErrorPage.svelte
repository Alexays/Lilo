<script lang="ts">
  import { tabActions } from "../../lib/bridge/actions";
  import { postMessage } from "../../lib/bridge";
  import { getActiveTab } from "../../stores/tabs.svelte";
  import { isSidebarVisible } from "../../stores/ui.svelte";
  import { reportInteractiveZone } from "../../lib/actions/interactiveZone";
  import { t } from "../../lib/i18n/state.svelte";
  import UiButton from "../ui/UiButton.svelte";

  interface ErrorInfo {
    code: number;
    domain: string;
    description: string;
    url: string;
  }

  const activeTab = $derived(getActiveTab());
  const canGoBack = $derived(activeTab?.canGoBack ?? false);
  const error = $derived.by<ErrorInfo | null>(() => {
    if (!activeTab?.hasNavigationError) {
      return null;
    }

    return {
      code: activeTab.navigationErrorCode,
      domain: activeTab.navigationErrorDomain,
      description: activeTab.navigationErrorDescription || t("errorPage.genericDescription"),
      url: activeTab.navigationErrorURL || activeTab.url || "",
    };
  });

  // TLS / certificate failures: offer an explicit, deliberate override.
  const CERT_ERROR_CODES = new Set([-1200, -1201, -1202, -1203, -1204]);

  const errorTitle = $derived.by((): string => {
    if (!error) return "";
    const code = error.code;
    // NSURLError codes
    if (code === -1003 || code === -1006) return t("errorPage.serverNotFound");
    if (code === -1001) return t("errorPage.timedOut");
    if (code === -1009) return t("errorPage.noInternet");
    if (CERT_ERROR_CODES.has(code)) return t("errorPage.notSecure");
    if (code === -1004 || code === -1005) return t("errorPage.connectionFailed");
    if (code === -999) return ""; // Cancelled: nothing to show
    return t("errorPage.couldNotLoad");
  });

  // Line icons (24x24, stroked) in the hang card's style.
  const errorIcon = $derived.by((): string => {
    if (!error) return "";
    const code = error.code;
    if (code === -1009) return "M2 8.5a15 15 0 0 1 20 0M5.5 12a10 10 0 0 1 13 0M9 15.5a5 5 0 0 1 6 0M12 19h.01M3 3l18 18";
    if (CERT_ERROR_CODES.has(code)) return "M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3";
    if (code === -1003 || code === -1006) return "M10.5 4a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM15.5 15.5 20 20";
    if (code === -1001) return "M12 7v5l3 2M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z";
    return "M12 9v4M12 17h.01M10.3 3.9 2.4 18a2 2 0 0 0 1.7 3h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z";
  });

  const errorHint = $derived.by((): string => {
    if (!error) return "";
    const code = error.code;
    if (code === -1009) return t("errorPage.hintNoInternet");
    if (CERT_ERROR_CODES.has(code)) return t("errorPage.hintNotSecure");
    if (code === -1003 || code === -1006) return t("errorPage.hintServerNotFound");
    if (code === -1001) return t("errorPage.hintTimedOut");
    return error.description;
  });

  function retry() {
    if (!error?.url) return;
    tabActions.reload();
  }

  // Offline page reloads by itself once the network is back.
  $effect(() => {
    if (error?.code !== -1009) return;
    window.addEventListener("online", retry);
    return () => window.removeEventListener("online", retry);
  });

  const isCertError = $derived(error != null && CERT_ERROR_CODES.has(error.code));
  const errorHost = $derived.by(() => {
    try {
      return error?.url ? new URL(error.url).hostname : "";
    } catch {
      return "";
    }
  });

  function visitAnyway() {
    if (!errorHost) return;
    // Swift adds the per-host trust exception for this session and reloads.
    postMessage("allowCertificateException", { host: errorHost });
  }
</script>

{#if error && errorTitle}
  <div
    class="error-page chrome-content-overlay-root"
    class:sidebar-hidden={!isSidebarVisible()}
    use:reportInteractiveZone={{ id: "error-page" }}
  >
    <div class="error-card">
      <div class="error-icon" aria-hidden="true">
        <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d={errorIcon} /></svg>
      </div>
      <h1 class="error-title">{errorTitle}</h1>
      <p class="error-description">{errorHint}</p>
      {#if error.url}
        <p class="error-url">{error.url}</p>
      {/if}
      <div class="error-actions">
        <UiButton disabled={!canGoBack} onclick={() => tabActions.goBack()}>{t("errorPage.back")}</UiButton>
        <UiButton variant="primary" onclick={retry}>{t("errorPage.tryAgain")}</UiButton>
        {#if isCertError && errorHost}
          <!-- Deliberately understated: proceeding past a cert error is the unsafe choice. -->
          <UiButton variant="ghost" onclick={visitAnyway}>{t("errorPage.visitAnyway")}</UiButton>
        {/if}
      </div>
    </div>
  </div>
{/if}

<style>
  .error-page {
    display: flex;
    align-items: center;
    justify-content: center;
    pointer-events: auto;
    background: color-mix(in srgb, var(--bg-primary) 94%, transparent);
  }

  .error-card {
    text-align: center;
    max-width: 420px;
    padding: 40px 32px;
  }

  .error-icon {
    width: 56px;
    height: 56px;
    margin: 0 auto 16px;
    border-radius: 50%;
    display: grid;
    place-items: center;
    color: var(--text-secondary);
    background: var(--bg-hover);
  }

  .error-title {
    font-size: var(--font-size-2xl);
    font-weight: var(--font-weight-semibold);
    color: var(--text-primary);
    margin: 0 0 8px;
  }

  .error-description {
    font-size: var(--font-size-lg);
    color: var(--text-secondary);
    line-height: 1.5;
    margin: 0 0 12px;
  }

  .error-url {
    font-size: var(--font-size-sm);
    color: var(--text-muted);
    word-break: break-all;
    margin: 0 0 20px;
  }

  .error-title,
  .error-description,
  .error-url {
    -webkit-user-select: text;
    user-select: text;
  }

  .error-actions {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    justify-content: center;
  }
</style>
