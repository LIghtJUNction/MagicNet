import { t } from "@/i18n";
import { parse, printParseErrorCode, type ParseError } from "jsonc-parser";

export type EditorPosition = {
  line: number;
  column: number;
};

export type LineRange = EditorPosition & {
  start: number;
  end: number;
};

export type JsonSyntaxError = {
  message: string;
  line: number;
  column: number;
  position: number;
};

const JSON_ERROR_COPY: Record<string, string> = {
  InvalidSymbol: "存在无效字符",
  InvalidNumberFormat: "数字格式不正确",
  PropertyNameExpected: "这里需要属性名",
  ValueExpected: "这里需要一个值",
  ColonExpected: "属性名后缺少冒号",
  CommaExpected: "这里缺少逗号",
  CloseBraceExpected: "缺少右花括号",
  CloseBracketExpected: "缺少右方括号",
  EndOfFileExpected: "末尾还有多余内容",
};

function clampPosition(text: string, position: number): number {
  return Math.max(0, Math.min(position, text.length));
}

export function positionToLineColumn(
  text: string,
  position: number,
): EditorPosition {
  const safePosition = clampPosition(text, position);
  const before = text.slice(0, safePosition);
  const lines = before.split("\n");
  return {
    line: lines.length,
    column: (lines.at(-1)?.length ?? 0) + 1,
  };
}

export function lineColumnToPosition(
  text: string,
  line: number,
  column: number,
): number {
  const lines = text.split("\n");
  const safeLine = Math.max(1, Math.min(line, lines.length));
  const safeColumn = Math.max(
    1,
    Math.min(column, (lines[safeLine - 1]?.length ?? 0) + 1),
  );
  let position = 0;
  for (let index = 0; index < safeLine - 1; index += 1) {
    position += (lines[index]?.length ?? 0) + 1;
  }
  return position + safeColumn - 1;
}

export function parseJsonSyntaxError(text: string): JsonSyntaxError | null {
  if (!text.trim()) return null;
  const errors: ParseError[] = [];
  parse(text, errors, { allowTrailingComma: false, disallowComments: true });
  const error = errors[0];
  if (!error) return null;
  const position = Math.max(0, Math.min(error.offset, text.length));
  const { line, column } = positionToLineColumn(text, position);
  const code = printParseErrorCode(error.error);
  return {
    message: t(JSON_ERROR_COPY[code] ?? "JSON 语法错误"),
    line,
    column,
    position,
  };
}

export function lineRange(text: string, line: number): LineRange {
  const lines = text.split("\n");
  const safeLine = Math.max(1, Math.min(line, lines.length));
  const start = lineColumnToPosition(text, safeLine, 1);
  const end = start + (lines[safeLine - 1]?.length ?? 0);
  return { line: safeLine, column: 1, start, end };
}
