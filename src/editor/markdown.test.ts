import { describe, expect, test } from "vitest";
import { Editor } from "@tiptap/core";
import { buildExtensions } from "./extensions";
import { isLossless, joinFrontMatter, normalizeOutput, skeleton, splitFrontMatter } from "./markdown";

function rt(md: string): string {
  const e = new Editor({ element: null, extensions: buildExtensions(), content: md, contentType: "markdown" });
  const out = normalizeOutput(e.getMarkdown());
  e.destroy();
  return out;
}

describe("round trip keeps supported markdown byte-identical", () => {
  const exact: Record<string, string> = {
    inline: "今天做了 **很多** 事，*斜体*，~~删除~~，==高亮==，`code`，[链接](https://a.b/c_d)。\n",
    tasks: "- [ ] 待办一\n- [x] 已完成\n  - [ ] 嵌套\n",
    lists: "- 列表\n- 第二\n  1. 有序\n  2. 二\n",
    headings: "# 一\n\n## 二\n\n### 三\n\n正文\n",
    quote: "> 引用\n",
    code: "```python\ndef f(x):\n    return x_1 * 2\n```\n",
    rule: "上\n\n---\n\n下\n",
    image: "![图](assets/a.png)\n",
    inlineMath: "注意力 $\\mathrm{softmax}(QK^\\top / \\sqrt{d_k})V$ 结束\n",
    blockMath: "$$\n\\sum_{i=1}^n a_i\n$$\n",
  };
  for (const [name, md] of Object.entries(exact)) {
    test(name, () => expect(rt(md)).toBe(md));
  }
});

describe("round trip is idempotent", () => {
  const samples = [
    "| a | b |\n|---|---|\n| 1 | 2 |\n",
    "* 星号\n* 列表\n\n1) 括号\n2) 序号\n",
    "Setext\n======\n\n    indented\n",
    "snake_case_name 和 2*3*4 [[wiki]]\n",
  ];
  for (const md of samples) {
    test(JSON.stringify(md.slice(0, 20)), () => {
      const once = rt(md);
      expect(rt(once)).toBe(once);
      expect(skeleton(once)).toBe(skeleton(md));
    });
  }
});

describe("math is not confused with prices", () => {
  test("dollar amounts stay text", () => {
    const md = "花了 $5 和 $10 买书\n";
    expect(rt(md)).toBe(md);
  });
});

describe("lossless guard", () => {
  test("accepts normalizable syntax", () => {
    expect(isLossless("* a\n* b\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")).toBe(true);
    expect(isLossless("")).toBe(true);
  });
  test("rejects raw html", () => {
    expect(isLossless("按 <kbd>Ctrl</kbd> 键\n")).toBe(false);
    expect(isLossless("<div align=\"center\">x</div>\n")).toBe(false);
  });
  test("rejects footnotes", () => {
    expect(isLossless("脚注[^1]\n\n[^1]: note\n")).toBe(false);
  });
});

describe("front matter", () => {
  test("is split and restored verbatim", () => {
    const md = "---\ntitle: front\ntags: [a]\n---\n\n正文\n";
    const { frontMatter, body } = splitFrontMatter(md);
    expect(frontMatter).toBe("---\ntitle: front\ntags: [a]\n---\n");
    expect(joinFrontMatter(frontMatter, body)).toBe(md);
    expect(joinFrontMatter(frontMatter, normalizeOutput(rt(body)))).toBe("---\ntitle: front\ntags: [a]\n---\n\n正文\n");
  });
  test("a leading thematic break is not front matter", () => {
    expect(splitFrontMatter("---\n\n正文\n").frontMatter).toBe("");
    expect(splitFrontMatter("正文\n").body).toBe("正文\n");
  });
});
