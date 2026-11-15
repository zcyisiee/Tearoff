import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";
import { TaskList, TaskItem } from "@tiptap/extension-list";
import Highlight from "@tiptap/extension-highlight";
import Image from "@tiptap/extension-image";
import { Table, TableRow, TableHeader, TableCell } from "@tiptap/extension-table";
import { Placeholder } from "@tiptap/extensions";
import { CodeBlockLowlight } from "@tiptap/extension-code-block-lowlight";
import { common, createLowlight } from "lowlight";
import { BlockMath, InlineMath } from "@tiptap/extension-mathematics";
import { Extension, type Extensions } from "@tiptap/core";
import { SlashMenu } from "./slash";
import { editLink } from "./actions";

const lowlight = createLowlight(common);

/**
 * `$…$` is math only under pandoc's rule: no space just inside the
 * delimiters and no digit right after the closing one — so "$5 和 $10" stays
 * plain text instead of being swallowed (and re-spaced) as a formula.
 */
const PandocInlineMath = InlineMath.extend({
  markdownTokenizer: {
    name: "inlineMath",
    level: "inline" as const,
    start: (src: string) => src.indexOf("$"),
    tokenize: (src: string) => {
      const match = /^\$(?!\s)((?:\\.|[^$\\\n])+?)(?<!\s)\$(?![\d$])/.exec(src);
      if (!match) return undefined;
      return { type: "inlineMath", raw: match[0], latex: match[1] };
    },
  },
});

/** Shortcuts beyond the StarterKit defaults. ⌘T is the long-standing "make this a to-do". */
const Keys = Extension.create({
  name: "tearoffKeys",
  addKeyboardShortcuts() {
    return {
      "Mod-t": () => this.editor.commands.toggleTaskList(),
      "Mod-k": () => {
        void editLink(this.editor);
        return true;
      },
    };
  },
});

export interface ExtensionOptions {
  placeholder?: string;
  /** Interactive extras (slash menu, shortcuts). Off for the headless round-trip probe. */
  interactive?: boolean;
  onMathClick?: (kind: "inline" | "block", latex: string, pos: number) => void;
  /** Maps a markdown image src (possibly note-relative) to a loadable URL. */
  resolveImage?: (src: string) => string;
}

/**
 * The one and only schema. Card previews, the today sheet and the expanded
 * editor all mount this exact set, so what you see never changes with size.
 */
export function buildExtensions(opts: ExtensionOptions = {}): Extensions {
  const resolve = opts.resolveImage;
  const NoteImage = resolve
    ? Image.extend({
        addNodeView() {
          return ({ node }) => {
            const img = document.createElement("img");
            img.src = resolve(node.attrs.src ?? "");
            if (node.attrs.alt) img.alt = node.attrs.alt;
            if (node.attrs.title) img.title = node.attrs.title;
            img.draggable = false;
            return { dom: img };
          };
        },
      })
    : Image;

  return [
    StarterKit.configure({
      codeBlock: false,
      link: { openOnClick: false, autolink: true, HTMLAttributes: { rel: "noopener" } },
    }),
    CodeBlockLowlight.configure({ lowlight, defaultLanguage: null }),
    TaskList,
    TaskItem.configure({ nested: true }),
    Highlight,
    NoteImage,
    Table.configure({ resizable: false }),
    TableRow,
    TableHeader,
    TableCell,
    BlockMath.configure({
      katexOptions: { throwOnError: false, displayMode: true },
      onClick: (node, pos) => opts.onMathClick?.("block", node.attrs.latex, pos),
    }),
    PandocInlineMath.configure({
      katexOptions: { throwOnError: false },
      onClick: (node, pos) => opts.onMathClick?.("inline", node.attrs.latex, pos),
    }),
    Placeholder.configure({ placeholder: opts.placeholder ?? "" }),
    Markdown.configure({ indentation: { style: "space", size: 2 } }),
    ...(opts.interactive ? [SlashMenu, Keys] : []),
  ];
}
