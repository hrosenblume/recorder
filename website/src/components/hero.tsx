"use client";

import { useState } from "react";

const claudePrompt =
  "Download and install Recorder: curl -LO https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip && unzip -o Recorder.app.zip -d /Applications && rm Recorder.app.zip && xattr -cr /Applications/Recorder.app && open /Applications/Recorder.app";

export function Hero() {
  const [copied, setCopied] = useState(false);

  function copy() {
    navigator.clipboard.writeText(claudePrompt);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

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
        Hit{" "}
        <kbd className="rounded border border-zinc-700 bg-zinc-900 px-2 py-0.5 text-sm font-mono text-zinc-200">
          ⌘⇧2
        </kbd>{" "}
        to record your screen with mic narration.
      </p>

      <div className="mt-10">
        <a
          href="https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip"
          className="inline-block rounded-full bg-white px-8 py-3 text-sm font-semibold text-black transition-colors hover:bg-zinc-200"
        >
          Download for Mac
        </a>
      </div>

      <div className="mt-12 w-full max-w-2xl">
        <p className="mb-3 text-center text-sm font-medium text-zinc-400">
          Or prompt Claude Code to do it
        </p>
        <div className="group relative rounded-lg border border-zinc-800 bg-zinc-950 p-4 font-mono text-sm">
          <pre className="overflow-x-auto whitespace-pre-wrap text-zinc-300">
            {claudePrompt}
          </pre>
          <button
            onClick={copy}
            className="absolute right-3 top-3 rounded border border-zinc-700 bg-zinc-800 px-2 py-1 text-xs text-zinc-400 transition-opacity hover:text-white"
          >
            {copied ? "Copied" : "Copy"}
          </button>
        </div>
      </div>
    </section>
  );
}
