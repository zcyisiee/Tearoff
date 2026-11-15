import {
  Bold, Italic, Strikethrough, Highlighter, Code, Link2, ListTodo, List, ListOrdered,
  Heading1, Heading2, Heading3, TextQuote, SquareCode, Minus, Table, Sigma, SquareSigma,
  type LucideIcon,
} from "lucide-react";

export const ICONS: Record<string, LucideIcon> = {
  bold: Bold,
  italic: Italic,
  strike: Strikethrough,
  highlight: Highlighter,
  code: Code,
  link: Link2,
  task: ListTodo,
  bullet: List,
  ordered: ListOrdered,
  h1: Heading1,
  h2: Heading2,
  h3: Heading3,
  quote: TextQuote,
  codeblock: SquareCode,
  rule: Minus,
  table: Table,
  math: Sigma,
  mathblock: SquareSigma,
};
