import { ArrowLeft } from "lucide-react";
import { api } from "../lib/api";
import { useStore } from "../lib/store";
import type { Settings } from "../lib/types";
import { IconButton } from "./Menu";

export function SettingsView() {
  const settings = useStore((s) => s.settings);
  const save = useStore((s) => s.saveSettings);
  const setView = useStore((s) => s.setView);
  if (!settings) return null;

  const num = (key: keyof Settings, min: number, max: number, step: number, unit: string) => (
    <label className="set__range">
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={settings[key] as number}
        onChange={(e) => void save({ [key]: Number(e.target.value) })}
      />
      <output>
        {settings[key] as number}
        {unit}
      </output>
    </label>
  );
  const choice = <K extends keyof Settings>(key: K, options: [Settings[K], string][]) => (
    <div className="set__seg" role="radiogroup">
      {options.map(([value, label]) => (
        <button
          key={String(value)}
          type="button"
          role="radio"
          aria-checked={settings[key] === value}
          className={settings[key] === value ? "is-on" : ""}
          onClick={() => void save({ [key]: value })}
        >
          {label}
        </button>
      ))}
    </div>
  );

  return (
    <div className="settings">
      <header className="settings__head">
        <IconButton label="返回" onClick={() => setView("home")}>
          <ArrowLeft size={16} />
        </IconButton>
        <h1>设置</h1>
      </header>

      <section className="set">
        <h2>笔记库</h2>
        <p className="set__path" title={settings.vaultPath}>{settings.vaultPath}</p>
        <div className="set__row">
          <button
            type="button"
            className="btn"
            onClick={async () => {
              const dir = await api.pickDirectory();
              if (dir) void save({ vaultPath: dir });
            }}
          >
            更换
          </button>
          <button type="button" className="btn" onClick={() => void api.openPath(settings.vaultPath)}>
            打开
          </button>
        </div>
      </section>

      <section className="set">
        <h2>面板</h2>
        <div className="set__field">
          <span>位置</span>
          {choice("side", [["left", "左"], ["right", "右"]])}
        </div>
        <div className="set__field">
          <span>边缘唤出</span>
          {choice("edgeActivation", [[true, "开"], [false, "关"]])}
        </div>
        <div className="set__field">
          <span>唤出延迟</span>
          {num("activationDelayMs", 0, 1000, 50, " 毫秒")}
        </div>
        <div className="set__field">
          <span>收起延迟</span>
          {num("hideDelayMs", 0, 2000, 100, " 毫秒")}
        </div>
        <div className="set__field">
          <span>宽度</span>
          {num("panelWidth", 360, 720, 10, " 点")}
        </div>
        <div className="set__field">
          <span>快捷键</span>
          <input
            className="set__text"
            defaultValue={settings.toggleShortcut}
            spellCheck={false}
            aria-label="呼出面板的快捷键"
            onBlur={(e) => e.target.value.trim() !== settings.toggleShortcut && void save({ toggleShortcut: e.target.value.trim() })}
            onKeyDown={(e) => e.key === "Enter" && e.currentTarget.blur()}
          />
        </div>
      </section>

      <section className="set">
        <h2>外观</h2>
        <div className="set__field">
          <span>明暗</span>
          {choice("theme", [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]])}
        </div>
        <div className="set__field">
          <span>字号</span>
          {num("fontSize", 13, 20, 1, " 点")}
        </div>
        <div className="set__field">
          <span>隐藏文件</span>
          {choice("showHiddenFiles", [[true, "显示"], [false, "不显示"]])}
        </div>
      </section>

      <section className="set">
        <h2>诊断</h2>
        <div className="set__row">
          <button type="button" className="btn" onClick={() => void api.openLogs()}>
            打开日志
          </button>
        </div>
      </section>

      <section className="set set--bare">
        <button type="button" className="btn btn--quiet" onClick={() => void api.quit()}>
          退出 Tearoff
        </button>
      </section>
    </div>
  );
}
