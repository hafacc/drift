<script lang="ts">
  import { appName } from "#lib/app.ts";
</script>

<svelte:head>
  <title>{appName} support</title>
</svelte:head>

<main class="mx-auto max-w-2xl px-4 py-12 leading-relaxed sm:py-16">
  <a class="text-sm text-zinc-500 underline dark:text-zinc-400" href="/"
    >{appName}</a
  >
  <h1 class="mt-6 text-3xl font-semibold tracking-tight">Support</h1>
  <p class="mt-6">
    Questions, problems, or an air conditioner {appName} can't reach? Email
    <a class="underline" href="mailto:support@drift.hafa.cc"
      >support@drift.hafa.cc</a
    >.
  </p>
  <p class="mt-3">
    Found a bug or have an idea?
    <a class="underline" href="https://github.com/hafacc/drift/issues/new"
      >Open an issue on GitHub</a
    >. {appName} is open source; its code is
    <a class="underline" href="https://github.com/hafacc/drift">on GitHub</a>.
  </p>

  <h2 class="mt-10 text-xl font-semibold">What you need</h2>
  <p class="mt-3">
    A Midea Wi-Fi air conditioner that's already added to a Midea account, and
    your phone or Mac on the same Wi-Fi network as the air conditioner.
  </p>

  <h2 class="mt-10 text-xl font-semibold">
    If setup can't find your air conditioner
  </h2>
  <p class="mt-3">
    Allow {appName}
    to find devices on your local network when it asks. On iPhone and Mac you
    can turn this on later in Settings, under Privacy &amp; Security, Local
    Network. Check that your device isn't on a guest network or a VPN, and that
    the air conditioner shows as online in the Midea app.
  </p>

  <h2 class="mt-10 text-xl font-semibold">Warranty</h2>
  <p class="mt-3">
    {appName}
    is provided as is, without warranty of any kind. Use it at your own risk.
  </p>
</main>
