export function Hero() {
  return (
    <section className="flex flex-col items-center justify-center px-6 pt-32 pb-20">
      <div
        className="mb-6 flex h-20 w-20 items-center justify-center rounded-3xl shadow-2xl"
        style={{
          background:
            "linear-gradient(135deg, rgb(99 92 235) 0%, rgb(217 107 181) 100%)",
        }}
        aria-label="Recorder icon"
      >
        <svg viewBox="0 0 24 24" width="36" height="36" fill="white">
          <path d="M8 5.5v13l11-6.5z" />
        </svg>
      </div>
      <h1 className="text-center text-5xl font-bold tracking-tight sm:text-6xl">
        Screen recording,
        <br />
        one tap.
      </h1>
      <p className="mt-6 max-w-xl text-center text-lg leading-8 text-zinc-400">
        A macOS menu bar app. Hit{" "}
        <kbd className="rounded border border-zinc-700 bg-zinc-900 px-2 py-0.5 text-sm font-mono text-zinc-200">
          ⌘⇧2
        </kbd>{" "}
        to start. Hit it again to stop. Mic audio so you can describe the
        problem. Files land in ~/Local/Screenshots.
      </p>
      <div className="mt-10 flex gap-4">
        <a
          href="https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip"
          className="rounded-full bg-white px-6 py-3 text-sm font-semibold text-black transition-colors hover:bg-zinc-200"
        >
          Download for Mac
        </a>
        <a
          href="#install"
          className="rounded-full border border-zinc-700 px-6 py-3 text-sm font-semibold text-zinc-300 transition-colors hover:border-zinc-500 hover:text-white"
        >
          How to install
        </a>
      </div>
    </section>
  );
}
