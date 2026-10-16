"use strict";
const $ = id => document.getElementById(id);
const token = location.hash.slice(1);
history.replaceState(null, "", location.pathname);
async function post(path, data) {
  const response = await fetch(path, {method: "POST", headers: {"Content-Type": "application/json", "X-Title-Token": token}, body: JSON.stringify(data)});
  const result = await response.json();
  if (!response.ok) throw Error(result.error || "request_failed");
  return result;
}
const labels = {loading: "正在生成建议…", ready: "建议已生成，选择采用后可编辑。", error: "生成失败；仍可手动输入标题。", edited: "已保留你输入的文字，下方建议可手动复制。", applied: "已填入建议；点击保存前不会应用。"};
const controller = new TitleSuggestions({
  request: data => post("/suggest", data), cancel: requestId => { post("/cancel", {requestId}).catch(() => {}); },
  readValue: () => $("title").value, writeValue: value => { $("title").value = value; },
  render: info => {
    $("state").textContent = (labels[info.state] || "") + (info.cached ? "（缓存）" : "") + (info.error ? ` ${info.error}` : "");
    $("suggestion").textContent = info.title || "";
    $("use").disabled = info.state !== "ready";
    $("again").disabled = info.state === "loading";
  }
});
$("title").addEventListener("input", () => controller.input());
$("open").addEventListener("click", () => {
  $("title").value = $("saved").textContent;
  $("dialog").showModal();
  controller.open($("thread").value, [{role: "user", text: $("context").value}]);
});
$("cancel").addEventListener("click", () => $("dialog").close());
$("dialog").addEventListener("close", () => controller.close());
$("dialog").addEventListener("cancel", () => controller.close());
$("use").addEventListener("click", () => controller.useSuggestion());
$("again").addEventListener("click", () => controller.generate());
$("form").addEventListener("submit", event => {
  event.preventDefault();
  if (!$("title").value.trim()) return;
  $("saved").textContent = $("title").value.trim();
  $("dialog").close();
});
addEventListener("pagehide", () => controller.close());
post("/status", {}).then(info => {
  $("mode").textContent = info.mode === "live" ? "当前：真实 API 模式。打开预览会产生一次模型调用。" : "当前：模拟模式，不调用模型，不产生费用。";
  $("open").disabled = false;
}).catch(() => { $("mode").textContent = "连接失败：请重新打开服务启动时显示的完整链接。"; });
