import { Editor } from "@tiptap/core";
import { buildExtensions } from "./extensions";

/**
 * Markdown is the storage format; the editor is a view over it. Two guards
 * keep that view from damaging files:
 *
 * 1. YAML front matter never enters the editor — it is split off on load and
 *    re-attached verbatim on save.
 * 2. Before a note is opened for rich editing we round-trip it once. If the
 *    round trip would lose characters (raw HTML, footnotes, anything the
 *    schema cannot represent) the note opens in source mode instead.
 */

const FRONT_MATTER = /^---\r?\n[\s\S]*?\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/;

export interface SplitDoc {
  frontMatter: string;
  body: string;
}

export function splitFrontMatter(markdown: string): SplitDoc {
  const m = FRONT_MATTER.exec(markdown);
  if (!m) return { frontMatter: "", body: markdown };
  return { frontMatter: m[0], body: markdown.slice(m[0].length) };
}

export function joinFrontMatter(frontMatter: string, body: string): string {
  if (!frontMatter) return body;
  return frontMatter + (body.startsWith("\n") || body === "" ? "" : "\n") + body;
}

/** Serialized markdown always ends with exactly one newline (or is empty). */
export function normalizeOutput(markdown: string): string {
  const trimmed = markdown.replace(/\s+$/, "");
  return trimmed === "" ? "" : trimmed + "\n";
}

/**
 * Characters that carry content rather than markdown syntax. Two documents
 * with the same skeleton differ only in formatting conventions (bullet style,
 * table padding, escapes, blank lines), which is safe to normalize.
 */
export function skeleton(markdown: string): string {
  return markdown
    // setext underlines and thematic breaks are pure syntax
    .replace(/^[ \t]*(=+|-+|\*+|_+)[ \t]*$/gm, "")
    // ordered list markers: "1." and "1)" are equivalent
    .replace(/^([ \t]*)\d+[.)][ \t]/gm, "$1")
    .replace(/[\s\\*_\-#>|`~=+:]/g, "");
}

let probe: Editor | null = null;

function roundTrip(body: string): string {
  if (!probe) {
    probe = new Editor({ element: null, extensions: buildExtensions(), content: "", contentType: "markdown" });
  }
  probe.commands.setContent(body, { contentType: "markdown", emitUpdate: false });
  return probe.getMarkdown();
}

/** True when the rich editor can represent `body` without losing content. */
export function isLossless(body: string): boolean {
  if (body.trim() === "") return true;
  try {
    return skeleton(roundTrip(body)) === skeleton(body);
  } catch {
    return false;
  }
}
