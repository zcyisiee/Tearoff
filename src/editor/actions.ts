import type { Editor } from "@tiptap/core";
import { askText } from "./askText";

const mac = typeof navigator !== "undefined" && /Mac/i.test(navigator.platform);
const MOD = mac ? "⌘" : "Ctrl+";
const SHIFT = mac ? "⇧" : "Shift+";
const ALT = mac ? "⌥" : "Alt+";

export interface Action {
  id: string;
  label: string;
  /** Extra words the slash menu matches on (pinyin initials, english). */
  keywords: string;
  shortcut?: string;
  isActive?: (e: Editor) => boolean;
  run: (e: Editor) => void;
}

function selectionAnchor(editor: Editor) {
  return {
    getBoundingClientRect() {
      const { from, to } = editor.state.selection;
      const a = editor.view.coordsAtPos(from);
      const b = editor.view.coordsAtPos(to);
      return new DOMRect(a.left, a.top, Math.max(1, b.right - a.left), b.bottom - a.top);
    },
  };
}

export async function editLink(editor: Editor) {
  const current = (editor.getAttributes("link").href as string | undefined) ?? "";
  const url = await askText({ anchor: selectionAnchor(editor), initial: current, placeholder: "粘贴或输入网址", label: "链接地址" });
  if (url === null) return editor.commands.focus();
  const chain = editor.chain().focus().extendMarkRange("link");
  if (url.trim() === "") return chain.unsetLink().run();
  const href = /^[a-z][a-z0-9+.-]*:|^[/#]/i.test(url.trim()) ? url.trim() : `https://${url.trim()}`;
  if (editor.state.selection.empty && !current) {
    return editor.chain().focus().insertContent({ type: "text", text: href, marks: [{ type: "link", attrs: { href } }] }).run();
  }
  return chain.setLink({ href }).run();
}

export async function insertMath(editor: Editor, block: boolean) {
  const latex = await askText({
    anchor: selectionAnchor(editor),
    placeholder: "LaTeX，例如 \\frac{a}{b}",
    label: "公式",
    monospace: true,
  });
  if (!latex?.trim()) return editor.commands.focus();
  if (block) editor.chain().focus().insertBlockMath({ latex: latex.trim() }).run();
  else editor.chain().focus().insertInlineMath({ latex: latex.trim() }).run();
}

/** Inline marks — bubble bar and format bar. */
export const MARKS: Action[] = [
  { id: "bold", label: "加粗", keywords: "bold jc", shortcut: `${MOD}B`, isActive: (e) => e.isActive("bold"), run: (e) => e.chain().focus().toggleBold().run() },
  { id: "italic", label: "斜体", keywords: "italic xt", shortcut: `${MOD}I`, isActive: (e) => e.isActive("italic"), run: (e) => e.chain().focus().toggleItalic().run() },
  { id: "strike", label: "删除线", keywords: "strike scx", shortcut: `${MOD}${SHIFT}S`, isActive: (e) => e.isActive("strike"), run: (e) => e.chain().focus().toggleStrike().run() },
  { id: "highlight", label: "高亮", keywords: "highlight gl", shortcut: `${MOD}${SHIFT}H`, isActive: (e) => e.isActive("highlight"), run: (e) => e.chain().focus().toggleHighlight().run() },
  { id: "code", label: "行内代码", keywords: "code dm", shortcut: `${MOD}E`, isActive: (e) => e.isActive("code"), run: (e) => e.chain().focus().toggleCode().run() },
  { id: "link", label: "链接", keywords: "link lj", shortcut: `${MOD}K`, isActive: (e) => e.isActive("link"), run: (e) => void editLink(e) },
];

/** Block types — format bar and slash menu. */
export const BLOCKS: Action[] = [
  { id: "task", label: "待办", keywords: "todo task db daiban", shortcut: `${MOD}T`, isActive: (e) => e.isActive("taskList"), run: (e) => e.chain().focus().toggleTaskList().run() },
  { id: "bullet", label: "列表", keywords: "bullet list lb liebiao", shortcut: `${MOD}${SHIFT}8`, isActive: (e) => e.isActive("bulletList"), run: (e) => e.chain().focus().toggleBulletList().run() },
  { id: "ordered", label: "编号列表", keywords: "ordered number bh bianhao", shortcut: `${MOD}${SHIFT}7`, isActive: (e) => e.isActive("orderedList"), run: (e) => e.chain().focus().toggleOrderedList().run() },
  { id: "h1", label: "大标题", keywords: "h1 heading bt biaoti", shortcut: `${MOD}${ALT}1`, isActive: (e) => e.isActive("heading", { level: 1 }), run: (e) => e.chain().focus().toggleHeading({ level: 1 }).run() },
  { id: "h2", label: "中标题", keywords: "h2 heading bt biaoti", shortcut: `${MOD}${ALT}2`, isActive: (e) => e.isActive("heading", { level: 2 }), run: (e) => e.chain().focus().toggleHeading({ level: 2 }).run() },
  { id: "h3", label: "小标题", keywords: "h3 heading bt biaoti", shortcut: `${MOD}${ALT}3`, isActive: (e) => e.isActive("heading", { level: 3 }), run: (e) => e.chain().focus().toggleHeading({ level: 3 }).run() },
  { id: "quote", label: "引用", keywords: "quote yy yinyong", shortcut: `${MOD}${SHIFT}B`, isActive: (e) => e.isActive("blockquote"), run: (e) => e.chain().focus().toggleBlockquote().run() },
  { id: "codeblock", label: "代码块", keywords: "code dmk daimakuai", shortcut: `${MOD}${ALT}C`, isActive: (e) => e.isActive("codeBlock"), run: (e) => e.chain().focus().toggleCodeBlock().run() },
  { id: "rule", label: "分割线", keywords: "divider hr fgx fengexian", run: (e) => e.chain().focus().setHorizontalRule().run() },
  { id: "table", label: "表格", keywords: "table bg biaoge", run: (e) => e.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
  { id: "math", label: "公式", keywords: "math latex gs gongshi", run: (e) => void insertMath(e, false) },
  { id: "mathblock", label: "独立公式", keywords: "math block latex gs gongshi", run: (e) => void insertMath(e, true) },
];
