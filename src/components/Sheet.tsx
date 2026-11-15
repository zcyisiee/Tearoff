import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { Editor } from "@tiptap/react";
import { Maximize2, Minimize2, MoreHorizontal, Pin, PinOff } from "lucide-react";
import { NoteEditor } from "../editor/NoteEditor";
import { FormatBar } from "../editor/FormatBar";
import { api } from "../lib/api";
import { useStore } from "../lib/store";
import { IconButton, Menu, type MenuState } from "./Menu";

const MORPH_MS = 300;
const MORPH_EASE = "cubic-bezier(0.22, 0.9, 0.24, 1)";

interface Props {
  path: string;
  modified: number;
  variant: "today" | "card" | "row";
  /** Heading content; for notes this is the editable title. */
  heading: ReactNode;
  pinned?: boolean;
  /** Pinned-card ordering key, enables 上移/下移. */
  cardKey?: string;
  placeholder?: string;
  focusSignal?: number;
  onCollapseRow?: () => void;
}

/**
 * A sheet of paper holding one note. Expanding does not open a different
 * view: this very element is lifted out of the list (a spacer keeps its slot)
 * and its box animates to fill the panel, then back. Same DOM, same editor,
 * same styles — there is nothing to mismatch.
 */
export function Sheet({ path, modified, variant, heading, pinned, cardKey, placeholder, focusSignal, onCollapseRow }: Props) {
  const expanded = useStore((s) => s.expanded === path);
  const setExpanded = useStore((s) => s.setExpanded);
  const setPinned = useStore((s) => s.setPinned);
  const deleteNote = useStore((s) => s.deleteNote);
  const moveCard = useStore((s) => s.moveCard);
  const exists = modified !== 0;

  const [editor, setEditor] = useState<Editor | null>(null);
  const [menu, setMenu] = useState<MenuState | null>(null);
  const [clipped, setClipped] = useState(false);
  const el = useRef<HTMLElement>(null);
  const body = useRef<HTMLDivElement>(null);
  const spacer = useRef<HTMLDivElement>(null);
  /** Box of the sheet just before the expanded state flips, for the FLIP. */
  const fromRect = useRef<DOMRect | null>(null);
  const [lifted, setLifted] = useState(false);
  const [slotHeight, setSlotHeight] = useState(0);

  const toggle = () => {
    const node = el.current;
    if (!node) return;
    if (!expanded) {
      fromRect.current = node.getBoundingClientRect();
      setSlotHeight(fromRect.current.height);
      setLifted(true);
      setExpanded(path);
    } else {
      collapse();
    }
  };

  const collapse = () => {
    const node = el.current;
    const slot = spacer.current?.getBoundingClientRect();
    if (!node || !slot || matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setLifted(false);
      setExpanded(null);
      return;
    }
    const from = node.getBoundingClientRect();
    body.current?.scrollTo({ top: 0 });
    const anim = node.animate(
      [box(from), box(slot)],
      { duration: MORPH_MS, easing: MORPH_EASE },
    );
    anim.onfinish = anim.oncancel = () => {
      setLifted(false);
      setExpanded(null);
    };
  };

  // Expand: runs after the element has become fixed/full-size, animates from where it was.
  useLayoutEffect(() => {
    const node = el.current;
    const from = fromRect.current;
    if (!expanded || !node || !from) return;
    fromRect.current = null;
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    const to = node.getBoundingClientRect();
    node.animate([box(from), box(to)], { duration: MORPH_MS, easing: MORPH_EASE });
  }, [expanded]);

  // Another sheet took over, or Escape cleared the state from outside.
  useEffect(() => {
    if (!expanded && lifted && !el.current?.getAnimations().length) setLifted(false);
  }, [expanded, lifted]);

  useEffect(() => {
    if (!expanded) return;
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape" && !e.defaultPrevented) {
        e.preventDefault();
        e.stopPropagation();
        collapse();
      }
    };
    window.addEventListener("keydown", key, true);
    return () => window.removeEventListener("keydown", key, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expanded]);

  // Fade the bottom edge only when a clamped sheet actually hides text.
  useEffect(() => {
    const node = body.current;
    if (!node) return;
    const check = () => setClipped(node.scrollHeight > node.clientHeight + 2);
    const ro = new ResizeObserver(check);
    ro.observe(node);
    if (node.firstElementChild) ro.observe(node.firstElementChild);
    check();
    return () => ro.disconnect();
  }, [editor, expanded]);

  const openMenu = (e: React.MouseEvent) => {
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    setMenu({
      x: r.right - 150,
      y: r.bottom + 4,
      items: [
        ...(cardKey
          ? ([
              { label: "上移", onSelect: () => void moveCard(cardKey, -1) },
              { label: "下移", onSelect: () => void moveCard(cardKey, 1) },
              "sep",
            ] as const)
          : []),
        { label: "在文件管理器中显示", disabled: !exists, onSelect: () => void api.revealNote(path) },
        "sep",
        { label: "移到废纸篓", danger: true, disabled: !exists, onSelect: () => void deleteNote(path) },
      ],
    });
  };

  const isLifted = expanded || lifted;

  return (
    <>
      {isLifted && <div ref={spacer} className="sheet-slot" style={{ height: slotHeight }} />}
      <article
        ref={el}
        className={`sheet sheet--${variant}` + (isLifted ? " is-expanded" : "")}
        data-clipped={clipped && !isLifted ? "" : undefined}
        data-note={path}
      >
        <header className="sheet__head">
          <div className="sheet__heading">{heading}</div>
          <div className="sheet__tools">
            {variant !== "today" && (
              <IconButton label={pinned ? "取消固定" : "固定在主页"} active={pinned} onClick={() => void setPinned(path, !pinned)}>
                {pinned ? <PinOff size={15} /> : <Pin size={15} />}
              </IconButton>
            )}
            <IconButton label={isLifted ? "收起  Esc" : "展开"} onClick={toggle}>
              {isLifted ? <Minimize2 size={15} /> : <Maximize2 size={15} />}
            </IconButton>
            <IconButton label="更多" onClick={openMenu}>
              <MoreHorizontal size={15} />
            </IconButton>
          </div>
        </header>
        <div ref={body} className="sheet__body">
          <NoteEditor path={path} modified={modified} placeholder={placeholder} onEditor={setEditor} focusSignal={focusSignal} />
        </div>
        {editor && (
          <footer className="sheet__foot">
            <FormatBar editor={editor} />
          </footer>
        )}
        {variant === "row" && !isLifted && onCollapseRow && (
          <button type="button" className="sheet__fold" onClick={onCollapseRow}>
            收起
          </button>
        )}
      </article>
      {menu && <Menu menu={menu} onClose={() => setMenu(null)} />}
    </>
  );
}

function box(r: DOMRect): Keyframe {
  return { top: `${r.top}px`, left: `${r.left}px`, width: `${r.width}px`, height: `${r.height}px` };
}
