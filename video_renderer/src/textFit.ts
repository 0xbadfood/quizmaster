type TextFitOptions = {
  text: string;
  maxWidth: number;
  maxHeight: number;
  maxFontSize: number;
  minFontSize: number;
  maxLines: number;
  lineHeight: number;
  fontFamily: string;
  fontWeight: number;
};

type TextFitResult = {
  fontSize: number;
  lineHeight: number;
  lines: number;
};

const fallbackWidth = (text: string, fontSize: number) =>
  text.length * fontSize * 0.57;

const lineCount = (
  text: string,
  maxWidth: number,
  fontSize: number,
  measure: (value: string) => number,
) => {
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) {
    return 1;
  }
  let lines = 1;
  let current = words[0];
  for (const word of words.slice(1)) {
    const candidate = `${current} ${word}`;
    if (measure(candidate) <= maxWidth) {
      current = candidate;
    } else {
      lines += 1;
      current = word;
    }
  }
  if (measure(current) > maxWidth) {
    return Number.POSITIVE_INFINITY;
  }
  return lines;
};

export const fitText = (options: TextFitOptions): TextFitResult => {
  const canvas =
    typeof document === "undefined" ? null : document.createElement("canvas");
  const context = canvas?.getContext("2d") ?? null;
  for (
    let fontSize = options.maxFontSize;
    fontSize >= options.minFontSize;
    fontSize -= 1
  ) {
    if (context) {
      context.font = `${options.fontWeight} ${fontSize}px ${options.fontFamily}`;
    }
    const lines = lineCount(
      options.text,
      options.maxWidth,
      fontSize,
      (value) =>
        context?.measureText(value).width ?? fallbackWidth(value, fontSize),
    );
    const height = lines * fontSize * options.lineHeight;
    if (lines <= options.maxLines && height <= options.maxHeight) {
      return { fontSize, lineHeight: options.lineHeight, lines };
    }
  }
  return {
    fontSize: options.minFontSize,
    lineHeight: options.lineHeight,
    lines: options.maxLines,
  };
};
