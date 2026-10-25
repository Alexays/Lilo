<script lang="ts">
  import TabPositionPicker from "../settings/TabPositionPicker.svelte";
  import { t } from "../../lib/i18n/state.svelte";
  import { goBack, goNext } from "../../stores/onboarding.svelte";
</script>

<!-- Each choice moves the real window behind the card, which recenters on the page. -->
<h3>{t("onboarding.tabs.title")}</h3>
<p class="ob-sub">{t("onboarding.tabs.subtitle")}</p>

<TabPositionPicker compact />

<div class="ob-foot">
  <button class="ob-btn ghost" onclick={goBack}>{t("onboarding.back")}</button>
  <button class="ob-btn primary" onclick={goNext}>{t("onboarding.continue")}</button>
</div>
