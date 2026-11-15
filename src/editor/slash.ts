import { Extension, type Editor, type Range } from "@tiptap/core";
import { Suggestion } from "@tiptap/suggestion";
import { computePosition, flip, offset, shift } from "@floating-ui/dom";
import { BLOCKS, type Action } from "./actions";

/**
 * "/" at the start of a word opens a block menu. Typing filters by label or
 * keyword; ↑/↓ + Enter picks. Plain DOM so it has no render lag while typing.
 */
export const SlashMenu = Extension.create({
  name: "slashMenu",
  addProseMirrorPlugins() {
    return [
      Suggestion<Action>({
        editor: this.editor,
        char: "/",
        allowSpaces: false,
        startOfLine: false,
        items: ({ query }) => {
          const q = query.toLowerCase();
          return BLOCKS.filter((a) => a.label.includes(query) || a.keywords.includes(q)).slice(0, 8);
        },
        command: ({ editor, range, props }: { editor: Editor; range: Range; props: Action }) => {
          editor.chain().focus().deleteRange(range).run();
          props.run(editor);
        },
        render: () => {
          let el: HTMLDivElement | null = null;
          let items: Action[] = [];
          let index = 0;
          let pick: (a: Action) => void = () => {};

          const paint = () => {
            if (!el) return;
            el.replaceChildren(
              ...items.map((a, i) => {
                const row = document.createElement("button");
                row.type = "button";
                row.className = "slash__item" + (i === index ? " is-active" : "");
                const label = document.createElement("span");
                label.textContent = a.label;
                row.append(label);
                if (a.shortcut) {
                  const k = document.createElement("kbd");
                  k.textContent = a.shortcut;
                  row.append(k);
                }
                row.addEventListener("mousedown", (e) => {
                  e.preventDefault();
                  pick(a);
                });
                return row;
              }),
            );
            el.hidden = items.length === 0;
            el.querySelector(".is-active")?.scrollIntoView({ block: "nearest" });
          };
          const place = (rect: (() => DOMRect | null) | null | undefined) => {
            const r = rect?.();
            if (!el || !r) return;
            void computePosition({ getBoundingClientRect: () => r }, el, {
              placement: "bottom-start",
              middleware: [offset(6), flip(), shift({ padding: 8 })],
            }).then(({ x, y }) => {
              if (el) Object.assign(el.style, { left: `${x}px`, top: `${y}px` });
            });
          };

          return {
            onStart(props) {
              el = document.createElement("div");
              el.className = "slash";
              document.body.append(el);
              items = props.items;
              index = 0;
              pick = (a) => props.command(a);
              paint();
              place(props.clientRect);
            },
            onUpdate(props) {
              items = props.items;
              index = 0;
              pick = (a) => props.command(a);
              paint();
              place(props.clientRect);
            },
            onKeyDown({ event }) {
              if (!items.length) return false;
              if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                index = (index + (event.key === "ArrowDown" ? 1 : items.length - 1)) % items.length;
                paint();
                return true;
              }
              if (event.key === "Enter" || event.key === "Tab") {
                pick(items[index]);
                return true;
              }
              if (event.key === "Escape") {
                el?.remove();
                el = null;
                return true;
              }
              return false;
            },
            onExit() {
              el?.remove();
              el = null;
            },
          };
        },
      }),
    ];
  },
});
