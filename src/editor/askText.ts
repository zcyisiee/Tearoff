import { computePosition, flip, offset, shift } from "@floating-ui/dom";

export interface AskOptions {
  anchor: { getBoundingClientRect(): DOMRect };
  initial?: string;
  placeholder?: string;
  label: string;
  monospace?: boolean;
}

/**
 * One-line inline prompt anchored to a piece of the document (link URL,
 * formula source). Enter confirms, Escape or clicking away cancels.
 */
export function askText(opts: AskOptions): Promise<string | null> {
  return new Promise((resolve) => {
    const box = document.createElement("form");
    box.className = "ask";
    const input = document.createElement("input");
    input.className = "ask__input" + (opts.monospace ? " ask__input--mono" : "");
    input.value = opts.initial ?? "";
    input.placeholder = opts.placeholder ?? "";
    input.setAttribute("aria-label", opts.label);
    input.spellcheck = false;
    const ok = document.createElement("button");
    ok.type = "submit";
    ok.className = "ask__ok";
    ok.textContent = "好";
    box.append(input, ok);
    document.body.append(box);

    let done = false;
    const finish = (value: string | null) => {
      if (done) return;
      done = true;
      document.removeEventListener("pointerdown", onOutside, true);
      box.remove();
      resolve(value);
    };
    const onOutside = (e: PointerEvent) => {
      if (!box.contains(e.target as Node)) finish(null);
    };
    box.addEventListener("submit", (e) => {
      e.preventDefault();
      finish(input.value);
    });
    input.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopPropagation();
        finish(null);
      }
    });
    document.addEventListener("pointerdown", onOutside, true);

    void computePosition(opts.anchor, box, {
      placement: "bottom-start",
      middleware: [offset(6), flip(), shift({ padding: 8 })],
    }).then(({ x, y }) => {
      box.style.left = `${x}px`;
      box.style.top = `${y}px`;
      input.focus();
      input.select();
    });
  });
}
