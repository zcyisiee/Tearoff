import { useEditorState, type Editor } from "@tiptap/react";
import { BLOCKS, MARKS, type Action } from "./actions";
import { ICONS } from "./icons";

const PRIMARY = ["task", "bullet", "ordered", "h1", "h2", "quote", "codeblock"];
const INSERT = ["rule", "table", "math"];

/**
 * The strip under a focused sheet: every structure a note can have is one
 * click (or the shortcut in the tooltip) away, so nobody has to type markdown.
 */
export function FormatBar({ editor }: { editor: Editor }) {
  const active = useEditorState({
    editor,
    selector: ({ editor }) => [...BLOCKS, ...MARKS].filter((a) => a.isActive?.(editor)).map((a) => a.id).join(","),
  });
  const on = new Set(active.split(","));
  const byId = (id: string) => BLOCKS.find((a) => a.id === id) ?? MARKS.find((a) => a.id === id)!;

  const button = (a: Action) => {
    const Icon = ICONS[a.id];
    return (
      <button
        key={a.id}
        type="button"
        className={"fbar__btn" + (on.has(a.id) ? " is-on" : "")}
        title={a.shortcut ? `${a.label}  ${a.shortcut}` : a.label}
        aria-label={a.label}
        aria-pressed={on.has(a.id)}
        // mousedown, not click: the editor must never lose its selection.
        onMouseDown={(e) => {
          e.preventDefault();
          a.run(editor);
        }}
      >
        <Icon size={16} strokeWidth={1.9} />
      </button>
    );
  };

  return (
    <div className="fbar" role="toolbar" aria-label="格式">
      {PRIMARY.map((id) => button(byId(id)))}
      <span className="fbar__sep" />
      {MARKS.map(button)}
      <span className="fbar__sep" />
      {INSERT.map((id) => button(byId(id)))}
    </div>
  );
}
