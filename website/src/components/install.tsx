"use client";

import { useState } from "react";

const steps = [
  {
    label: "Download",
    code: "# Download here, unzip it, and move to /Applications",
    link: "https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip",
  },
  {
    label: "Strip the quarantine flag",
    code: "xattr -cr /Applications/Recorder.app",
  },
  {
    label: "Launch",
    text: "Double-click Recorder in /Applications. The icon shows up in the menu bar. Press ⌘⇧2 to start a recording.",
  },
];

const claudePrompt =
  "Download and install Recorder: curl -LO https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip && unzip -o Recorder.app.zip -d /Applications && rm Recorder.app.zip && xattr -cr /Applications/Recorder.app && open /Applications/Recorder.app";

export function Install() {
  const [copied, setCopied] = useState<number | null>(null);
  const [promptCopied, setPromptCopied] = useState(false);

  function copy(text: string, index: number) {
    navigator.clipboard.writeText(text);
    setCopied(index);
    setTimeout(() => setCopied(null), 2000);
  }

  function copyPrompt() {
    navigator.clipboard.writeText(claudePrompt);
    setPromptCopied(true);
    setTimeout(() => setPromptCopied(false), 2000);
  }

  return (
    <section id="install" className="mx-auto max-w-2xl px-6 py-20">
      <h2 className="mb-12 text-center text-3xl font-bold tracking-tight">
        Install in 3 steps
      </h2>
      <div className="space-y-6">
        {steps.map((step, i) => (
          <div key={step.label}>
            <div className="mb-2 text-sm font-medium text-zinc-400">
              {i + 1}. {step.label}
            </div>
            <div className="group relative rounded-lg border border-zinc-800 bg-zinc-900 p-4 font-mono text-sm">
              {"link" in step ? (
                <p className="text-zinc-300">
                  Download{" "}
                  <a href={step.link} className="underline hover:text-white">
                    here
                  </a>
                  , unzip it, and move to /Applications
                </p>
              ) : "text" in step ? (
                <p className="text-zinc-300">{step.text}</p>
              ) : (
                <>
                  <pre className="overflow-x-auto whitespace-pre text-zinc-300">
                    {step.code}
                  </pre>
                  <button
                    onClick={() => copy(step.code!, i)}
                    className="absolute right-3 top-3 rounded border border-zinc-700 bg-zinc-800 px-2 py-1 text-xs text-zinc-400 opacity-0 transition-opacity group-hover:opacity-100 hover:text-white"
                  >
                    {copied === i ? "Copied" : "Copy"}
                  </button>
                </>
              )}
            </div>
          </div>
        ))}
      </div>

      <div className="mt-14 rounded-xl border border-zinc-800 bg-zinc-900/60 p-6">
        <p className="mb-3 text-center text-sm font-medium text-zinc-400">
          Or prompt Claude to do it
        </p>
        <div className="group relative rounded-lg border border-zinc-700 bg-zinc-950 p-4 font-mono text-sm">
          <pre className="overflow-x-auto whitespace-pre-wrap text-zinc-300">
            {claudePrompt}
          </pre>
          <button
            onClick={() => copyPrompt()}
            className="absolute right-3 top-3 rounded border border-zinc-700 bg-zinc-800 px-2 py-1 text-xs text-zinc-400 opacity-0 transition-opacity group-hover:opacity-100 hover:text-white"
          >
            {promptCopied ? "Copied" : "Copy"}
          </button>
        </div>
      </div>

      <div className="mt-12 text-center text-sm text-zinc-500">
        First launch: macOS will ask for Screen Recording and Microphone permission.
        Grant both, then quit and relaunch Recorder once (TCC requires it).
      </div>
    </section>
  );
}
