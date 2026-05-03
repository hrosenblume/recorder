const features = [
  {
    title: "Global hotkey",
    description:
      "⌘⇧2 from anywhere on your Mac. Same UX as ⌘⇧3 for screenshots — no app to bring forward, no menu to hunt for.",
  },
  {
    title: "Menu bar native",
    description:
      "Lives in your menu bar with a colorful play-button icon. Turns red while recording. No dock icon, no clutter.",
  },
  {
    title: "Mic narration",
    description:
      "Records the default microphone alongside your screen so you can talk through bugs, demos, or design feedback.",
  },
  {
    title: "Saves where you'd expect",
    description:
      "Files go to ~/Local/Screenshots with the standard macOS naming convention: Recording <date> at <time>.mov.",
  },
  {
    title: "Auto-update",
    description:
      "Checks GitHub Releases once a day. New version drops, you get prompted, click install, done. No third-party update server.",
  },
  {
    title: "Native + open source",
    description:
      "Pure Swift + AppKit + ScreenCaptureKit. ~26 MB resident, 0% CPU at idle. MIT licensed. Built to be cloned and modified.",
  },
];

export function Features() {
  return (
    <section className="mx-auto max-w-5xl px-6 py-20">
      <h2 className="mb-12 text-center text-3xl font-bold tracking-tight">
        What it does
      </h2>
      <div className="grid gap-8 sm:grid-cols-2 lg:grid-cols-3">
        {features.map((f) => (
          <div
            key={f.title}
            className="rounded-xl border border-zinc-800 bg-zinc-900/50 p-6"
          >
            <h3 className="mb-2 text-lg font-semibold">{f.title}</h3>
            <p className="text-sm leading-6 text-zinc-400">{f.description}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
