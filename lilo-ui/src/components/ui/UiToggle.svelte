<script lang="ts">
  interface Props {
    checked?: boolean;
    disabled?: boolean;
    ariaLabel: string;
    onchange?: (checked: boolean) => void;
  }

  let {
    checked = false,
    disabled = false,
    ariaLabel,
    onchange,
  }: Props = $props();

  function handleChange(event: Event): void {
    checked = event.currentTarget instanceof HTMLInputElement ? event.currentTarget.checked : checked;
    onchange?.(checked);
  }
</script>

<label class="ui-toggle">
  <input
    type="checkbox"
    bind:checked
    {disabled}
    aria-label={ariaLabel}
    onchange={handleChange}
  />
  <span class="ui-toggle-track"></span>
</label>

<style>
  .ui-toggle {
    position: relative;
    display: inline-block;
    flex: none;
    width: 32px;
    height: 19px;
    cursor: pointer;
  }

  .ui-toggle input {
    position: absolute;
    opacity: 0;
    width: 0;
    height: 0;
  }

  .ui-toggle-track {
    position: absolute;
    inset: 0;
    border-radius: var(--radius-chip);
    background: var(--text-primary-tint-12);
    transition: background var(--transition-fast);
  }

  .ui-toggle-track::after {
    content: "";
    position: absolute;
    top: 2px;
    left: 2px;
    width: 15px;
    height: 15px;
    border-radius: var(--radius-chip);
    background: white;
    box-shadow: var(--shadow-control);
    transition: transform 160ms var(--motion-ease-spring);
  }

  .ui-toggle input:checked + .ui-toggle-track {
    background: var(--accent);
  }

  .ui-toggle input:checked + .ui-toggle-track::after {
    transform: translateX(13px);
  }

  .ui-toggle input:focus-visible + .ui-toggle-track {
    outline: var(--focus-outline);
    outline-offset: 1px;
  }

  .ui-toggle input:disabled + .ui-toggle-track {
    opacity: var(--disabled-opacity);
  }
</style>
