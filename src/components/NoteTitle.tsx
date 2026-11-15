import { useEffect, useRef, useState } from "react";
import { useStore } from "../lib/store";

/** Note title that renames the file in place: click, type, Enter. */
export function NoteTitle({ path, title }: { path: string; title: string }) {
  const rename = useStore((s) => s.renameNote);
  const [draft, setDraft] = useState(title);
  const input = useRef<HTMLInputElement>(null);
  const fresh = /^未命名( \d+)?$/.test(title);

  useEffect(() => setDraft(title), [title]);
  useEffect(() => {
    // A brand-new note asks for its name first.
    if (fresh && Date.now() - mountedAt.current < 400) {
      input.current?.focus();
      input.current?.select();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  const mountedAt = useRef(Date.now());

  const commit = async () => {
    if (draft.trim() === title || !draft.trim()) return setDraft(title);
    if ((await rename(path, draft)) === null) setDraft(title);
  };

  return (
    <input
      ref={input}
      className="title"
      value={draft}
      aria-label="笔记标题"
      spellCheck={false}
      onChange={(e) => setDraft(e.target.value.replace(/[\\/:*?"<>|]/g, ""))}
      onBlur={() => void commit()}
      onKeyDown={(e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          const sheet = e.currentTarget.closest(".sheet");
          e.currentTarget.blur();
          (sheet?.querySelector(".ProseMirror, .source__text") as HTMLElement | null)?.focus();
        } else if (e.key === "Escape") {
          e.stopPropagation();
          setDraft(title);
          e.currentTarget.blur();
        }
      }}
    />
  );
}
