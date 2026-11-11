<script lang="ts">
  import "../app.css";

  let { children } = $props();
</script>

<div
  class="min-h-screen bg-zinc-50 text-zinc-800 dark:bg-zinc-900 dark:text-zinc-200"
>
  {@render children()}
</div>
