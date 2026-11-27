/**
 * "Stuck? Tell us" — a prefilled GitHub issue link printed after a CLI error.
 *
 * The link carries only what a maintainer needs to reproduce a failed
 * quickstart: the command that failed, the error text, and versions. Nothing is
 * sent anywhere; the user opens the link and reads the issue before submitting.
 * The error text is scrubbed first, because stack traces and RPC errors do
 * contain private keys, API keys, URLs with tokens and home-directory paths.
 */

const ISSUES_NEW = "https://github.com/lacrew/lacrew/issues/new";
const TEMPLATE = "quickstart-stuck.yml";
/** Keep the URL well under GitHub's ~8 KB request-line limit. */
const MAX_ERROR_CHARS = 1500;

/** Scrub secrets and local paths out of free text before it goes in a URL. */
export function redact(text: string): string {
  return (
    text
      // 32-byte hex values (private keys; tx hashes lose little by being cut)
      .replace(/\b0x[0-9a-fA-F]{64}\b/g, "0x<redacted>")
      // Authorization headers
      .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 <redacted>")
      // key=value / key: value pairs for anything that smells like a secret
      .replace(
        /\b([A-Za-z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSPHRASE|MNEMONIC|AUTH)[A-Za-z0-9_]*)\s*[=:]\s*\S+/gi,
        "$1=<redacted>",
      )
      // Provider-style secret prefixes (sk-…, ghp_…, etc.)
      .replace(/\b(?:sk|pk|ghp|gho|ghs|xox[abp])[-_][A-Za-z0-9_-]{16,}/g, "<redacted>")
      // Credentials and query-string keys inside URLs (RPC providers put keys there)
      .replace(/\/\/[^/\s@]+@/g, "//<redacted>@")
      .replace(/([?&](?:apikey|api_key|key|token|access_token)=)[^&\s]+/gi, "$1<redacted>")
      .replace(
        /(https?:\/\/[^\s/]*(?:alchemy|infura|quicknode|ankr)[^\s/]*\/\S*?\/)[A-Za-z0-9_-]{16,}/gi,
        "$1<redacted>",
      )
      // Home directories
      .replace(/\/(?:Users|home)\/[^/\s]+/g, "/~")
      .replace(/[A-Za-z]:\\Users\\[^\\\s]+/g, "~")
  );
}

export interface StuckContext {
  /** The subcommand that failed, e.g. `deploy`. Arguments are never included. */
  command?: string;
  error: unknown;
  cliVersion: string;
  nodeVersion?: string;
  platform?: string;
}

function errorText(err: unknown): string {
  if (err instanceof Error) return `${err.name}: ${err.message}`;
  if (typeof err === "string") return err;
  return JSON.stringify(err) ?? String(err);
}

export function stuckUrl(ctx: StuckContext): string {
  const message = redact(errorText(ctx.error)).slice(0, MAX_ERROR_CHARS);
  const versions = [
    `lacrew-cli ${ctx.cliVersion}`,
    `node ${ctx.nodeVersion ?? process.version}`,
    ctx.platform ?? `${process.platform}-${process.arch}`,
  ].join("\n");
  const where = ctx.command ? `lacrew ${ctx.command}` : "lacrew CLI";
  const params = new URLSearchParams({
    template: TEMPLATE,
    title: `Stuck: ${where}`,
    step: `CLI: ${where}`,
    error: message,
    versions,
  });
  return `${ISSUES_NEW}?${params.toString()}`;
}

/** The lines printed under an error. */
export function stuckHint(ctx: StuckContext): string {
  return `\nStuck? Tell us (opens a prefilled GitHub issue; nothing is sent until you submit it):\n  ${stuckUrl(ctx)}`;
}
