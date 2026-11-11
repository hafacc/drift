<script lang="ts">
  import { appName, appStoreUrl, playStoreUrl } from "#lib/app.ts";

  // the dial walks through the apps' modes, each in its own color
  const modes = [
    { label: "COOLING TO", color: "#0a7aff", temp: 24 },
    { label: "TARGET", color: "#5e5ce6", temp: 22 },
    { label: "TARGET", color: "#0e8a9e", temp: 25 },
  ];
  const low = 16;
  const high = 30;

  let index = $state(0);
  const mode = $derived(modes[index]);
  const fraction = $derived((mode.temp - low) / (high - low));

  $effect(() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const timer = setInterval(() => {
      index = (index + 1) % modes.length;
    }, 3200);
    return () => clearInterval(timer);
  });
</script>

<svelte:head>
  <title>{appName}</title>
  <meta
    name="description"
    content="Control your Midea air conditioner on Android, iPhone and Mac."
  >
</svelte:head>

<div class="page" style:--accent={mode.color}>
  <main>
    <div class="dial" aria-hidden="true">
      <svg viewBox="0 0 300 300" aria-hidden="true">
        <path
          d="M 65.1 234.9 A 120 120 0 1 1 234.9 234.9"
          fill="none"
          stroke="var(--track)"
          stroke-width="18"
          stroke-linecap="round"
        />
        <path
          class="arc"
          d="M 65.1 234.9 A 120 120 0 1 1 234.9 234.9"
          fill="none"
          stroke="var(--accent)"
          stroke-width="18"
          stroke-linecap="round"
          pathLength="100"
          stroke-dasharray="100"
          stroke-dashoffset={100 - fraction * 100}
        />
        <g class="knob" style:transform="rotate({fraction * 270}deg)">
          <circle
            cx="65.1"
            cy="234.9"
            r="13"
            fill="#fff"
            stroke="var(--accent)"
            stroke-width="5"
          />
        </g>
      </svg>
      <div class="readout">
        <span class="label">{mode.label}</span>
        <span class="temp">{mode.temp}°</span>
      </div>
    </div>
    <div>
      <h1>{appName}</h1>
      <p class="tagline">
        Control your Midea air conditioner on Android, iPhone and Mac.
      </p>
    </div>
    <div class="stores">
      <a class="store" href={playStoreUrl}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path
            d="M4 2.8v18.4c0 .5.5.8.9.6l16-9.2c.4-.2.4-.9 0-1.1L4.9 2.2c-.4-.2-.9.1-.9.6z"
          />
        </svg>
        Android
      </a>
      {#if appStoreUrl}
        <a class="store" href={appStoreUrl}>
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path
              d="M16.4 12.6c0-2.4 2-3.5 2.1-3.6-1.1-1.7-2.9-1.9-3.5-1.9-1.5-.2-2.9.9-3.7.9-.8 0-1.9-.9-3.2-.8-1.6 0-3.1 1-4 2.4-1.7 3-.4 7.4 1.2 9.8.8 1.2 1.8 2.5 3 2.4 1.2 0 1.7-.8 3.1-.8 1.5 0 1.9.8 3.2.8 1.3 0 2.2-1.2 3-2.4.9-1.4 1.3-2.7 1.3-2.8-.1 0-2.5-1-2.5-4zM14 5.4c.7-.8 1.1-1.9 1-3-1 0-2.1.6-2.8 1.4-.6.7-1.2 1.8-1 2.9 1.1.1 2.1-.5 2.8-1.3z"
            />
          </svg>
          iPhone and Mac
        </a>
      {/if}
    </div>
  </main>
  <footer><a href="/privacy">Privacy</a></footer>
</div>

<style>
  .page {
    --fg: #14161c;
    --bg: #f4f6fa;
    --muted: #626a78;
    --track: #e1e5ee;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 40px;
    padding: 56px max(16px, env(safe-area-inset-right)) 32px
      max(16px, env(safe-area-inset-left));
    background: var(--bg);
    color: var(--fg);
  }
  @media (prefers-color-scheme: dark) {
    .page {
      --fg: #eef0f5;
      --bg: #0f1116;
      --muted: #9aa2b1;
      --track: #262a34;
    }
  }
  main {
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 28px;
    text-align: center;
  }
  .dial {
    position: relative;
    width: min(300px, 80vw);
    aspect-ratio: 300 / 262;
  }
  .dial svg {
    position: absolute;
    inset: 0 0 auto;
    width: 100%;
    height: auto;
    overflow: visible;
  }
  .arc {
    transition:
      stroke-dashoffset 900ms cubic-bezier(0.3, 0.7, 0.2, 1),
      stroke 600ms ease;
  }
  .knob {
    transform-origin: 150px 150px;
    transition: transform 900ms cubic-bezier(0.3, 0.7, 0.2, 1);
  }
  .knob circle {
    transition: stroke 600ms ease;
  }
  .readout {
    position: absolute;
    /* the ring's center: 150 of the 262-unit-tall box */
    top: 57.25%;
    inset-inline: 0;
    transform: translateY(-50%);
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 2px;
  }
  .label {
    font-size: 12px;
    font-weight: 600;
    letter-spacing: 0.12em;
    color: var(--accent);
    transition: color 600ms ease;
  }
  .temp {
    font-size: clamp(56px, 18vw, 76px);
    font-weight: 200;
    line-height: 1;
    font-variant-numeric: tabular-nums;
  }
  h1 {
    margin: 0;
    font-size: 34px;
    font-weight: 600;
    letter-spacing: -0.02em;
  }
  .tagline {
    margin: 8px 0 0;
    color: var(--muted);
    font-size: 17px;
    text-wrap: balance;
  }
  .stores {
    display: flex;
    flex-wrap: wrap;
    justify-content: center;
    gap: 12px;
  }
  .store {
    display: inline-flex;
    align-items: center;
    gap: 10px;
    padding: 12px 20px;
    border-radius: 999px;
    background: var(--fg);
    color: var(--bg);
    font-size: 15px;
    font-weight: 500;
    text-decoration: none;
  }
  .store svg {
    width: 20px;
    height: 20px;
    fill: currentColor;
  }
  .store:focus-visible,
  footer a:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 3px;
  }
  footer {
    margin-top: auto;
    font-size: 14px;
    color: var(--muted);
  }
  footer a {
    color: inherit;
  }
  @media (prefers-reduced-motion: reduce) {
    .arc,
    .knob,
    .knob circle,
    .label {
      transition: none;
    }
  }
</style>
