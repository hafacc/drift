<script lang="ts">
  import { appName } from "#lib/app.ts";
</script>

<svelte:head>
  <title>{appName} privacy policy</title>
</svelte:head>

<main class="mx-auto max-w-2xl px-4 py-12 leading-relaxed sm:py-16">
  <a class="text-sm text-zinc-500 underline dark:text-zinc-400" href="/"
    >{appName}</a
  >
  <h1 class="mt-6 text-3xl font-semibold tracking-tight">Privacy</h1>
  <p class="mt-6">
    {appName}
    doesn't collect or share any data about you. There are no accounts, ads,
    analytics, or tracking.
  </p>

  <h2 class="mt-10 text-xl font-semibold">Your air conditioner</h2>
  <p class="mt-3">
    The app talks to your air conditioner directly over your home Wi-Fi. Its
    settings and readings stay on your devices.
  </p>

  <h2 class="mt-10 text-xl font-semibold">Setup</h2>
  <p class="mt-3">
    Newer air conditioners need a key before the app can talk to them. During
    setup you sign in with your Midea account, and the app asks Midea's cloud
    for that key, sending your Midea email and password and the air
    conditioner's ID. This happens only during setup and can take a few
    requests. Your email and password are sent only to Midea, are never saved,
    and are cleared once setup ends. After setup the app never contacts the
    cloud.
  </p>

  <h2 class="mt-10 text-xl font-semibold">On your device</h2>
  <p class="mt-3">
    The key is kept in your device's secure storage and is removed when you
    forget the air conditioner. On Android it's also removed when you uninstall
    the app, and it's left out of backups and transfers to a new phone.
  </p>

  <h2 class="mt-10 text-xl font-semibold">Contact</h2>
  <p class="mt-3">
    <a class="underline" href="mailto:support@drift.hafa.cc">support@drift.hafa.cc</a>
  </p>

  <p class="mt-10 text-sm text-zinc-500 dark:text-zinc-400">
    Last updated November 11, 2026.
  </p>
</main>
