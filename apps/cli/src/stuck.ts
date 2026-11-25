import { release } from "node:os";

const ISSUES_URL = "https://github.com/marc-aurele-besner/lacrew/issues/new";
const MAX_ERROR_CHARS = 800;

export interface StuckInput {
  /** argv after the binary, e.g. ["deploy", "--anvil"] */
  argv: string[];
  /** Lines the command printed to stderr. */
  errorLines: string[];
  cliVersion: string;
}

/** Drop anything that looks like a secret before it goes into a URL. */
export function redact(text: string): string {
  return text
    .replace(/\b0x[0-9a-fA-F]{64}\b/g, "[redacted-key]")
    .replace(/\b(\w*(?:KEY|SECRET|TOKEN|PASSWORD)\w*)=\S+/gi, "$1=[redacted]")
    .replace(/(\w+:\/\/)[^\s/@]+@/g, "$1[redacted]@");
}

/** The command reached: names only, never flags or their values (they may hold keys or URLs). */
export function stepReached(argv: string[]): string {
  const words: string[] = [];
  for (const a of argv) {
    if (a.startsWith("-")) break;
    words.push(a);
    if (words.length === 2) break;
  }
  return `lacrew ${words.join(" ")}`.trim();
}

export function buildStuckUrl(input: StuckInput): string {
  const step = stepReached(input.argv);
  const error = redact(input.errorLines.join("\n").trim()).slice(-MAX_ERROR_CHARS);
  const params = new URLSearchParams({
    template: "quickstart.yml",
    title: `[quickstart] stuck at: ${step}`,
    step,
    error,
    cli_version: input.cliVersion,
    environment: `Node ${process.version}, ${process.platform} ${release()}`,
  });
  return `${ISSUES_URL}?${params.toString()}`;
}

export function stuckLine(input: StuckInput): string {
  return `Stuck? Tell us: ${buildStuckUrl(input)}`;
}

/** Record what a command prints to stderr, so the link can carry the error. */
export function captureStderr(): { lines: string[] } {
  const lines: string[] = [];
  const original = console.error.bind(console);
  console.error = (...args: unknown[]) => {
    lines.push(args.map((a) => (a instanceof Error ? a.message : String(a))).join(" "));
    original(...args);
  };
  return { lines };
}
