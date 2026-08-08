import { writeFile } from "node:fs/promises";

const debugPort = process.argv[2] || "9224";
const url = process.argv[3];
const outputPrefix = process.argv[4] || "/tmp/quiz-webui";
const username = process.argv[5];
const password = process.argv[6];
if (!url || !username || !password) {
  throw new Error("usage: webui_qa.mjs DEBUG_PORT URL OUTPUT_PREFIX USER PASSWORD");
}

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
const consoleErrors = [];
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.method === "Runtime.exceptionThrown") consoleErrors.push(message.params.exceptionDetails?.text || "Runtime exception");
  if (message.method === "Log.entryAdded" && message.params.entry.level === "error") consoleErrors.push(message.params.entry.text);
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
async function evaluate(expression) {
  const result = await command("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function screenshot(path) {
  const result = await command("Page.captureScreenshot", { format: "png", fromSurface: true, captureBeyondViewport: false });
  await writeFile(path, Buffer.from(result.data, "base64"));
}
async function navigate(target) {
  await command("Page.navigate", { url: target });
  await pause(1200);
}

await command("Page.enable");
await command("Runtime.enable");
await command("Log.enable");
await command("Emulation.setDeviceMetricsOverride", { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
await navigate(url);
await evaluate(`fetch('/api/auth/login', {method:'POST', headers:{'Content-Type':'application/json'}, body:${JSON.stringify(JSON.stringify({ username, password }))}}).then(r => { if (!r.ok) throw new Error('login failed'); return r.json(); })`);
await navigate(url);

const desktop = await evaluate(`(() => ({
  readyState: document.readyState,
  viewport: [innerWidth, innerHeight],
  documentSize: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  categoryCount: document.querySelectorAll('.category-item').length,
  stageCount: document.querySelectorAll('.stage-navigation button').length,
  metricCount: document.querySelectorAll('.metric').length,
  title: document.querySelector('.category-masthead h1')?.textContent || null,
  sidebar: document.querySelector('.category-sidebar')?.getBoundingClientRect().toJSON(),
  inspector: document.querySelector('.context-inspector')?.getBoundingClientRect().toJSON(),
}))()`);
await screenshot(`${outputPrefix}-desktop.png`);

await evaluate(`document.querySelector('.stage-navigation button:nth-child(2)').click()`);
await pause(900);
const questions = await evaluate(`(() => ({
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  rows: document.querySelectorAll('.question-row').length,
  selectedQuestion: document.querySelector('.question-row.selected .question-main strong')?.textContent || null,
  editorVisible: Boolean(document.querySelector('.question-inspector')),
  summaryStats: document.querySelectorAll('.bank-stat').length,
  table: document.querySelector('.question-table-shell')?.getBoundingClientRect().toJSON(),
}))()`);
await screenshot(`${outputPrefix}-questions.png`);

await evaluate(`document.querySelector('.question-actions .button.primary').click()`);
await pause(300);
const generationDialog = await evaluate(`(() => ({
  visible: Boolean(document.querySelector('.dialog')),
  title: document.querySelector('.dialog h2')?.textContent || null,
  fields: document.querySelectorAll('.dialog input, .dialog select').length,
  providers: [...document.querySelectorAll('.dialog form > label:first-child select option')].map(option => option.textContent).filter(text => text !== 'Select a provider'),
  selectedProvider: document.querySelector('.dialog form > label:first-child select option:checked')?.textContent || null,
  model: document.querySelector('.dialog input[list="generation-models"]')?.value || null,
  submitDisabled: document.querySelector('.dialog-actions .button.primary')?.disabled,
}))()`);
await screenshot(`${outputPrefix}-generation.png`);
await evaluate(`document.querySelector('.dialog header .icon-button').click()`);
await pause(200);

await evaluate(`document.querySelector('.stage-navigation button:nth-child(3)').click()`);
await pause(700);
const sets = await evaluate(`(() => ({
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  rows: document.querySelectorAll('.set-row').length,
  selectedSet: document.querySelector('.set-row.selected .set-identity strong')?.textContent || null,
  inspectorVisible: Boolean(document.querySelector('.set-inspector')),
  questionsInInspector: document.querySelectorAll('.set-question-list li').length,
  summaryStats: document.querySelectorAll('.bank-stat').length,
}))()`);
await screenshot(`${outputPrefix}-sets.png`);

await evaluate(`[...document.querySelectorAll('.category-item')].find(button => button.querySelector('.category-copy strong')?.textContent === 'Birds')?.click()`);
await pause(700);
await evaluate(`document.querySelector('.question-actions .button.primary')?.click()`);
await pause(250);
const selectionDialog = await evaluate(`(() => ({
  visible: Boolean(document.querySelector('.dialog')),
  title: document.querySelector('.dialog h2')?.textContent || null,
  capacity: document.querySelector('.selection-capacity')?.textContent || null,
  count: document.querySelector('.dialog input[type="number"]')?.value || null,
  submitDisabled: document.querySelector('.dialog-actions .button.primary')?.disabled,
}))()`);
await screenshot(`${outputPrefix}-set-selection.png`);
await evaluate(`document.querySelector('.dialog header .icon-button')?.click()`);
await pause(200);

await evaluate(`document.querySelector('.stage-navigation button:nth-child(4)').click()`);
await pause(900);
const visuals = await evaluate(`(() => ({
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  cards: document.querySelectorAll('.visual-card').length,
  selectedAsset: document.querySelector('.visual-card.selected .visual-card-copy strong')?.textContent || null,
  inspectorVisible: Boolean(document.querySelector('.visual-inspector')),
  summaryStats: document.querySelectorAll('.bank-stat').length,
  generated: [...document.querySelectorAll('.bank-stat')].find(item => item.textContent.includes('Generated'))?.querySelector('strong')?.textContent || null,
}))()`);
await screenshot(`${outputPrefix}-visuals.png`);
await evaluate(`[...document.querySelectorAll('.question-actions .button')].find(button => button.textContent.includes('Plan prompts'))?.click()`);
await pause(250);
const visualPromptDialog = await evaluate(`(() => ({
  visible: Boolean(document.querySelector('.dialog')),
  title: document.querySelector('.dialog h2')?.textContent || null,
  roleOptions: document.querySelectorAll('.role-options input:checked').length,
  model: document.querySelector('.dialog input[list="visual-prompt-models"]')?.value || null,
  submitDisabled: document.querySelector('.dialog-actions .button.primary')?.disabled,
}))()`);
await screenshot(`${outputPrefix}-visual-prompts.png`);
await evaluate(`document.querySelector('.dialog header .icon-button')?.click()`);
await pause(200);

await evaluate(`[...document.querySelectorAll('.visual-selection-bar .button')].find(button => button.textContent.includes('Select all tiles'))?.click()`);
await pause(150);
const visualBulkSelection = await evaluate(`(() => ({
  selected: document.querySelectorAll('.visual-card input[type="checkbox"]:checked').length,
  selectionText: document.querySelector('.visual-selection-bar > span')?.textContent || null,
  generateText: [...document.querySelectorAll('.question-actions .button')].find(button => button.textContent.includes('Generate'))?.textContent || null,
}))()`);
await evaluate(`[...document.querySelectorAll('.question-actions .button')].find(button => button.textContent.includes('Generate'))?.click()`);
await pause(250);
const visualGenerationDialog = await evaluate(`(() => ({
  visible: Boolean(document.querySelector('.dialog')),
  title: document.querySelector('.dialog h2')?.textContent || null,
  providers: [...document.querySelectorAll('.dialog form > label:first-child select option')].map(option => option.textContent).filter(text => text !== 'Select a provider'),
  submitDisabled: document.querySelector('.dialog-actions .button.primary')?.disabled,
}))()`);
await screenshot(`${outputPrefix}-visual-generation.png`);
await evaluate(`document.querySelector('.dialog header .icon-button')?.click()`);
await pause(200);

await evaluate(`[...document.querySelectorAll('.category-item')].find(button => button.querySelector('.category-copy strong')?.textContent === 'Animals')?.click()`);
await pause(900);
await screenshot(`${outputPrefix}-visuals-populated.png`);

await evaluate(`document.querySelector('.stage-navigation button:nth-child(5)').click()`);
await pause(900);
const audioWorkspace = await evaluate(`(() => ({
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  rows: document.querySelectorAll('.audio-row').length,
  players: document.querySelectorAll('.audio-row audio').length,
  selectedQuestion: document.querySelector('.audio-row.selected .audio-question-copy strong')?.textContent || null,
  inspectorVisible: Boolean(document.querySelector('.audio-inspector')),
  summaryStats: document.querySelectorAll('.bank-stat').length,
  attention: [...document.querySelectorAll('.bank-stat')].find(item => item.textContent.includes('Attention'))?.querySelector('strong')?.textContent || null,
}))()`);
await screenshot(`${outputPrefix}-audio.png`);
await evaluate(`[...document.querySelectorAll('.question-actions .button')].find(button => button.textContent.includes('Retry attention'))?.click()`);
await pause(250);
const audioGenerationDialog = await evaluate(`(() => ({
  visible: Boolean(document.querySelector('.dialog')),
  title: document.querySelector('.dialog h2')?.textContent || null,
  providers: [...document.querySelectorAll('.dialog form > label:first-child select option')].map(option => option.textContent).filter(text => text !== 'Select a provider'),
  repairAttempts: document.querySelector('.dialog input[type="number"]')?.value || null,
  submitDisabled: document.querySelector('.dialog-actions .button.primary')?.disabled,
}))()`);
await screenshot(`${outputPrefix}-audio-generation.png`);
await evaluate(`document.querySelector('.dialog header .icon-button')?.click()`);
await pause(200);

await evaluate(`document.querySelector('.stage-navigation button:nth-child(6)').click()`);
await pause(800);
const publishWorkspace = await evaluate(`(() => ({
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  gates: document.querySelectorAll('.publish-readiness .readiness-row').length,
  blockedGates: document.querySelectorAll('.publish-readiness .status-badge.blocked').length,
  releases: document.querySelectorAll('.release-row').length,
  currentVersion: document.querySelector('.release-hero strong')?.textContent || null,
  publishDisabled: [...document.querySelectorAll('.question-actions .button')].find(button => button.textContent.includes('Publish category'))?.disabled,
  inspectorVisible: Boolean(document.querySelector('.release-inspector')),
}))()`);
await screenshot(`${outputPrefix}-publish.png`);
const publishCanOpen = !publishWorkspace.publishDisabled;
if (publishCanOpen) {
  await evaluate(`[...document.querySelectorAll('.question-actions .button')].find(button => button.textContent.includes('Publish category'))?.click()`);
  await pause(250);
}
const publishDialog = await evaluate(`(() => ({
  visible: Boolean(document.querySelector('.dialog')),
  title: document.querySelector('.dialog h2')?.textContent || null,
  forceVersion: document.querySelector('.dialog input[type="checkbox"]')?.checked ?? null,
  submitDisabled: document.querySelector('.dialog-actions .button.primary')?.disabled ?? null,
}))()`);
if (publishCanOpen) {
  await screenshot(`${outputPrefix}-publish-dialog.png`);
  await evaluate(`document.querySelector('.dialog header .icon-button')?.click()`);
  await pause(200);
}

await evaluate(`document.querySelector('.mode-switch button:nth-child(2)').click()`);
await pause(500);
const admin = await evaluate(`(() => ({
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  providerCount: document.querySelectorAll('.provider-item').length,
  selectedProvider: document.querySelector('.provider-editor h1')?.textContent || null,
  fieldCount: document.querySelectorAll('.provider-editor input, .provider-editor textarea').length,
  diagnosticsVisible: Boolean(document.querySelector('.provider-diagnostics')),
}))()`);
await screenshot(`${outputPrefix}-admin.png`);

await evaluate(`[...document.querySelectorAll('.provider-item')].find(button => button.textContent.includes('Quiz narrator'))?.click()`);
await pause(300);
const vibevoiceAdmin = await evaluate(`(() => ({
  selectedProvider: document.querySelector('.provider-editor h1')?.textContent || null,
  referenceTranscript: [...document.querySelectorAll('.provider-editor label')].find(label => label.textContent.includes('Reference transcript'))?.querySelector('textarea')?.value || null,
  referenceAudio: [...document.querySelectorAll('.provider-editor label, .provider-upload-field')].find(label => label.textContent.includes('Reference audio'))?.querySelector('input:not([type="file"])')?.value || null,
  wavUploadVisible: [...document.querySelectorAll('.upload-button')].some(label => label.textContent.includes('Upload WAV')),
}))()`);
await screenshot(`${outputPrefix}-admin-vibevoice.png`);

await evaluate(`document.querySelector('.mode-switch button:first-child').click()`);
await pause(300);

await command("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: true, screenWidth: 390, screenHeight: 844 });
await pause(700);
const mobile = await evaluate(`(() => ({
  viewport: [innerWidth, innerHeight],
  documentSize: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
  horizontalOverflow: document.documentElement.scrollWidth > innerWidth,
  header: document.querySelector('.app-header')?.getBoundingClientRect().toJSON(),
  stages: document.querySelector('.stage-navigation')?.getBoundingClientRect().toJSON(),
  canvas: document.querySelector('.question-canvas')?.getBoundingClientRect().toJSON(),
  table: document.querySelector('.question-table-shell')?.getBoundingClientRect().toJSON(),
  bodyOverflowX: getComputedStyle(document.body).overflowX,
}))()`);
await screenshot(`${outputPrefix}-mobile.png`);
console.log(JSON.stringify({ desktop, questions, generationDialog, sets, selectionDialog, visuals, visualPromptDialog, visualBulkSelection, visualGenerationDialog, audioWorkspace, audioGenerationDialog, publishWorkspace, publishDialog, admin, vibevoiceAdmin, mobile, consoleErrors }, null, 2));
socket.close();
