import { writeFile } from "node:fs/promises";

const debugPort = process.argv[2] || "9223";
const url = process.argv[3];
const outputPrefix = process.argv[4] || "/tmp/quiz-mobile";
if (!url) throw new Error("usage: mobile_qa.mjs DEBUG_PORT URL [OUTPUT_PREFIX]");

const pages = await fetch(`http://127.0.0.1:${debugPort}/json`).then((response) => response.json());
const page = pages.find((candidate) => candidate.type === "page");
if (!page) throw new Error("Chrome exposes no debuggable page");

const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let nextId = 1;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (!message.id) return;
  const operation = pending.get(message.id);
  if (!operation) return;
  pending.delete(message.id);
  if (message.error) operation.reject(new Error(JSON.stringify(message.error)));
  else operation.resolve(message.result);
});

function command(method, params = {}) {
  const id = nextId++;
  socket.send(JSON.stringify({ id, method, params }));
  return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
}

const pause = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
await command("Page.enable");
await command("Runtime.enable");
await command("Emulation.setDeviceMetricsOverride", {
  width: 390,
  height: 844,
  deviceScaleFactor: 1,
  mobile: true,
  screenWidth: 390,
  screenHeight: 844,
});
await command("Page.navigate", { url });
await pause(1200);

async function evaluate(expression) {
  const result = await command("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}

async function screenshot(path) {
  const result = await command("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false,
  });
  await writeFile(path, Buffer.from(result.data, "base64"));
}

const layout = await evaluate(`(() => {
  const selectors = ['.app', '.header', '.score', '#speak', '.question-card', '.answers', '.answer:last-child'];
  const boxes = Object.fromEntries(selectors.map((selector) => {
    const node = document.querySelector(selector);
    const rect = node?.getBoundingClientRect();
    return [selector, rect ? { x: rect.x, y: rect.y, width: rect.width, height: rect.height, right: rect.right, bottom: rect.bottom } : null];
  }));
  return { innerWidth, innerHeight, scrollWidth: document.documentElement.scrollWidth, scrollHeight: document.documentElement.scrollHeight, readyState: document.readyState, boxes };
})()`);
await screenshot(`${outputPrefix}-initial.png`);

const interaction = await evaluate(`(() => {
  document.querySelector('[data-option-id="opt1_bark"]').click();
  return {
    score: document.getElementById('score').textContent,
    feedbackVisible: document.getElementById('feedback').classList.contains('visible'),
    wrongClass: document.querySelector('[data-option-id="opt1_bark"]').className,
    correctClass: document.querySelector('[data-option-id="opt2_roar"]').className,
    allDisabled: [...document.querySelectorAll('.answer')].every((answer) => answer.disabled),
  };
})()`);
await pause(250);
await screenshot(`${outputPrefix}-answered.png`);

console.log(JSON.stringify({ layout, interaction }, null, 2));
socket.close();
