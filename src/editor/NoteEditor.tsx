import { useEffect, useMemo, useRef, useState } from "react";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import { BubbleMenu } from "@tiptap/react/menus";
import { api } from "../lib/api";
import { log } from "../lib/log";
import { buildExtensions } from "./extensions";
import { isLossless, joinFrontMatter, normalizeOutput, splitFrontMatter } from "./markdown";
import { NoteSaver } from "./saver";
import { askText } from "./askText";
import { MARKS } from "./actions";
import { ICONS } from "./icons";

interface Props {
  path: string;
  /** mtime from the note list; a change we did not cause means an external edit. */
  modified: number;
  placeholder?: string;
  onEditor?: (editor: Editor | null) => void;
  /** Bump to move the caret to the end of the note. */
  focusSignal?: number;
}

interface Loaded {
  frontMatter: string;
  body: string;
  rich: boolean;
  /** Bumped only when disk content replaces what is shown, forcing a fresh editor. */
  version: number;
}

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const r = new FileReader();
    r.onload = () => resolve(String(r.result).split(",")[1] ?? "");
    r.onerror = () => reject(r.error);
    r.readAsDataURL(file);
  });
}

/**
 * The one editor. The today sheet, cards, opened history rows and the expanded
 * view all render this component with the same schema and the same `.prose`
 * styles — the container around it is the only thing that changes size.
 */
export function NoteEditor({ path, modified, placeholder, onEditor, focusSignal }: Props) {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const saver = useRef<NoteSaver | null>(null);
  const pathRef = useRef(path);
  pathRef.current = path;

  // Load once per mount. A rename keeps the same mount and only retargets the saver.
  useEffect(() => {
    let alive = true;
    void api.readNote(path).then((doc) => {
      if (!alive) return;
      const { frontMatter, body } = splitFrontMatter(doc.content);
      saver.current = new NoteSaver(path, doc.content, doc.modified);
      const rich = isLossless(body);
      if (!rich) log.info(`${path} opens in source mode (rich editing would lose content)`);
      setLoaded({ frontMatter, body, rich, version: 0 });
      saver.current.onExternalContent = (content) => {
        const next = splitFrontMatter(content);
        setLoaded((prev) => ({ ...next, rich: isLossless(next.body), version: (prev?.version ?? 0) + 1 }));
      };
    });
    return () => {
      alive = false;
      saver.current?.dispose();
      saver.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    saver.current?.retarget(path);
  }, [path]);

  // External edits: the list reports an mtime that is not ours → reload, unless we have unsaved typing.
  useEffect(() => {
    const s = saver.current;
    if (!s || !loaded || s.dirty || modified === 0 || s.baseModified === modified) return;
    let alive = true;
    void api.readNote(pathRef.current).then((doc) => {
      if (!alive || !saver.current || saver.current.dirty || doc.content === saver.current.savedContent) {
        if (alive && saver.current && !saver.current.dirty) saver.current.accept(saver.current.savedContent, doc.modified);
        return;
      }
      saver.current.accept(doc.content, doc.modified);
      const { frontMatter, body } = splitFrontMatter(doc.content);
      setLoaded((prev) => ({ frontMatter, body, rich: isLossless(body), version: (prev?.version ?? 0) + 1 }));
    });
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [modified]);

  if (!loaded) return <div className="prose prose--loading" aria-busy="true" />;
  if (!loaded.rich) {
    return <SourceEditor key={loaded.version} loaded={loaded} saver={saver} onEditor={onEditor} />;
  }
  return (
    <RichEditor
      key={loaded.version}
      loaded={loaded}
      saver={saver}
      pathRef={pathRef}
      placeholder={placeholder}
      onEditor={onEditor}
      focusSignal={focusSignal}
    />
  );
}

function RichEditor({
  loaded,
  saver,
  pathRef,
  placeholder,
  onEditor,
  focusSignal,
}: {
  loaded: Loaded;
  saver: React.RefObject<NoteSaver | null>;
  pathRef: React.RefObject<string>;
  placeholder?: string;
  onEditor?: (editor: Editor | null) => void;
  focusSignal?: number;
}) {
  const editorRef = useRef<Editor | null>(null);
  /** Serialization of the document as loaded; null once the user has changed it. */
  const baseline = useRef<string | null>(null);
  const extensions = useMemo(
    () =>
      buildExtensions({
        placeholder,
        interactive: true,
        resolveImage: (src) => api.resolveAsset(pathRef.current, src),
        onMathClick: (kind, latex, pos) => {
          const editor = editorRef.current;
          if (!editor) return;
          const dom = editor.view.nodeDOM(pos) as HTMLElement | null;
          if (!dom) return;
          void askText({ anchor: dom, initial: latex, label: "公式", monospace: true }).then((next) => {
            if (next === null) return;
            if (kind === "inline") editor.chain().setNodeSelection(pos).updateInlineMath({ latex: next.trim() }).focus().run();
            else editor.chain().setNodeSelection(pos).updateBlockMath({ latex: next.trim() }).focus().run();
          });
        },
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  );

  const editor = useEditor({
    extensions,
    content: loaded.body,
    contentType: "markdown",
    shouldRerenderOnTransaction: false,
    editorProps: {
      attributes: { class: "prose", spellcheck: "false" },
      handlePaste(_view, event) {
        const files = [...(event.clipboardData?.files ?? [])].filter((f) => f.type.startsWith("image/"));
        if (!files.length) return false;
        event.preventDefault();
        void (async () => {
          for (const file of files) {
            const ext = file.type.split("/")[1]?.replace("jpeg", "jpg") ?? "png";
            const src = await api.saveImage(pathRef.current, `pasted.${ext}`, await fileToBase64(file));
            editorRef.current?.chain().focus().setImage({ src }).run();
          }
        })();
        return true;
      },
      handleClickOn(_view, _pos, node, _nodePos, event) {
        const link = (event.target as HTMLElement).closest("a");
        if (link && (event.metaKey || event.ctrlKey) && node) {
          const href = link.getAttribute("href");
          if (href) void api.openPath(href);
          return true;
        }
        return false;
      },
    },
    onCreate({ editor }) {
      baseline.current = normalizeOutput(editor.getMarkdown());
    },
    onUpdate({ editor }) {
      const s = saver.current;
      if (!s) return;
      const md = normalizeOutput(editor.getMarkdown());
      // Opening a note must never rewrite it: until the document differs from
      // what the file parsed to, there is nothing to save — even though our
      // serialization may format tables or bullets differently from the file.
      if (md === baseline.current) {
        if (s.dirty) s.schedule(s.savedContent);
        return;
      }
      baseline.current = null;
      s.schedule(joinFrontMatter(loaded.frontMatter, md));
    },
    onBlur() {
      void saver.current?.flush();
    },
  });
  editorRef.current = editor;

  useEffect(() => {
    onEditor?.(editor);
    return () => onEditor?.(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [editor]);

  useEffect(() => {
    if (focusSignal) editor?.commands.focus("end");
  }, [focusSignal, editor]);

  return (
    <>
      <EditorContent editor={editor} />
      {editor && (
        <BubbleMenu editor={editor} className="bubble" options={{ placement: "top", offset: 8 }}>
          {MARKS.map((a) => {
            const Icon = ICONS[a.id];
            return (
              <button
                key={a.id}
                type="button"
                className="bubble__btn"
                title={`${a.label}  ${a.shortcut ?? ""}`}
                aria-label={a.label}
                onMouseDown={(e) => {
                  e.preventDefault();
                  a.run(editor);
                }}
              >
                <Icon size={15} strokeWidth={2} />
              </button>
            );
          })}
        </BubbleMenu>
      )}
    </>
  );
}

/**
 * Fallback for notes the rich schema cannot hold without loss (raw HTML,
 * footnotes…). Same typography, plain markdown text, nothing is rewritten
 * except what the user types.
 */
function SourceEditor({
  loaded,
  saver,
  onEditor,
}: {
  loaded: Loaded;
  saver: React.RefObject<NoteSaver | null>;
  onEditor?: (editor: Editor | null) => void;
}) {
  const [text, setText] = useState(loaded.body);
  const ref = useRef<HTMLTextAreaElement>(null);
  useEffect(() => {
    onEditor?.(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  useEffect(() => setText(loaded.body), [loaded.body]);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }, [text]);

  return (
    <div className="source">
      <span className="source__note">MD</span>
      <textarea
        ref={ref}
        className="prose source__text"
        value={text}
        spellCheck={false}
        onChange={(e) => {
          setText(e.target.value);
          saver.current?.schedule(joinFrontMatter(loaded.frontMatter, e.target.value));
        }}
        onBlur={() => void saver.current?.flush()}
      />
    </div>
  );
}
