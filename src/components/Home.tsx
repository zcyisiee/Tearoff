import { useEffect, useMemo, useState } from "react";
import { api } from "../lib/api";
import { groupOf, monthDay, shortDay, weekday, dayKey } from "../lib/dates";
import { selectCards, selectHistory, sortStamp, todayPath, useStore } from "../lib/store";
import type { NoteMeta, SearchHit } from "../lib/types";
import { FolderCardView } from "./FolderCardView";
import { NoteTitle } from "./NoteTitle";
import { Sheet } from "./Sheet";

function headingFor(note: NoteMeta, today: string) {
  if (note.dailyDate) {
    return (
      <span className="title title--static">
        {monthDay(note.dailyDate)} <small>{shortDay(note.dailyDate, today) === monthDay(note.dailyDate) ? weekday(note.dailyDate) : shortDay(note.dailyDate, today)}</small>
      </span>
    );
  }
  return <NoteTitle path={note.path} title={note.title} />;
}

export function Home() {
  const notes = useStore((s) => s.notes);
  const folderCards = useStore((s) => s.folderCards);
  const today = useStore((s) => s.today);
  const openRow = useStore((s) => s.openRow);
  const setOpenRow = useStore((s) => s.setOpenRow);
  const query = useStore((s) => s.query);
  const searching = useStore((s) => s.searching);
  const focusToday = useStore((s) => s.focusToday);

  const cards = useMemo(() => selectCards({ notes, folderCards, today }), [notes, folderCards, today]);
  const history = useMemo(() => selectHistory({ notes, today }), [notes, today]);
  const todayNote = notes.find((n) => n.path === todayPath(today));

  const groups = useMemo(() => {
    const out: { name: string; notes: NoteMeta[] }[] = [];
    for (const n of history) {
      const name = groupOf(n.dailyDate ?? dayKey(sortStamp(n)), today);
      if (out.at(-1)?.name === name) out.at(-1)!.notes.push(n);
      else out.push({ name, notes: [n] });
    }
    return out;
  }, [history, today]);

  if (searching && query.trim()) return <SearchResults query={query} />;

  return (
    <div className="home">
      <section aria-label="今天">
        <Sheet
          key={today}
          path={todayPath(today)}
          modified={todayNote?.modified ?? 0}
          variant="today"
          focusSignal={focusToday}
          heading={
            <h1 className="today__date">
              {monthDay(today)}
              <span>{weekday(today)}</span>
            </h1>
          }
        />
      </section>

      {cards.length > 0 && (
        <section className="cards" aria-label="固定的卡片">
          {cards.map((c) =>
            c.kind === "note" ? (
              <Sheet
                key={c.key}
                path={c.note.path}
                modified={c.note.modified}
                variant="card"
                pinned
                cardKey={c.key}
                heading={headingFor(c.note, today)}
              />
            ) : (
              <FolderCardView key={c.key} card={c.card} cardKey={c.key} />
            ),
          )}
        </section>
      )}

      <section className="history" aria-label="之前的笔记">
        {groups.map((g) => (
          <div key={g.name} className="history__group">
            <h2 className="history__label">{g.name}</h2>
            {g.notes.map((n) =>
              openRow === n.path ? (
                <Sheet
                  key={n.path}
                  path={n.path}
                  modified={n.modified}
                  variant="row"
                  heading={headingFor(n, today)}
                  onCollapseRow={() => setOpenRow(null)}
                />
              ) : (
                <button key={n.path} type="button" className="row" onClick={() => setOpenRow(n.path)}>
                  <span className="row__when">{shortDay(n.dailyDate ?? dayKey(n.modified), today)}</span>
                  <span className="row__text">
                    {!n.dailyDate && <strong>{n.title}</strong>}
                    <span>{n.preview}</span>
                  </span>
                </button>
              ),
            )}
          </div>
        ))}
      </section>
    </div>
  );
}

function SearchResults({ query }: { query: string }) {
  const [hits, setHits] = useState<SearchHit[] | null>(null);
  const notes = useStore((s) => s.notes);
  const setOpenRow = useStore((s) => s.setOpenRow);
  const setSearching = useStore((s) => s.setSearching);
  const setPinnedScroll = (path: string) => {
    const note = notes.find((n) => n.path === path);
    setSearching(false);
    if (note && !note.pinned) setOpenRow(path);
    requestAnimationFrame(() =>
      document.querySelector(`[data-note="${CSS.escape(path)}"]`)?.scrollIntoView({ block: "start", behavior: "smooth" }),
    );
  };

  useEffect(() => {
    let alive = true;
    const t = setTimeout(() => void api.search(query).then((h) => alive && setHits(h)), 120);
    return () => {
      alive = false;
      clearTimeout(t);
    };
  }, [query]);

  return (
    <div className="home">
      <section className="history">
        {hits && hits.length === 0 && <p className="history__empty">没有结果</p>}
        {hits?.map((h) => (
          <button key={h.path} type="button" className="row" onClick={() => setPinnedScroll(h.path)}>
            <span className="row__text">
              <strong>{h.title}</strong>
              <span>{h.snippet}</span>
            </span>
          </button>
        ))}
      </section>
    </div>
  );
}
