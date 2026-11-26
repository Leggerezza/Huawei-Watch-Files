// preview-page.js - renders the watch web UI to a static file for browser-based
// layout/interaction checks when the device is not reachable.
//
// This is a *preview harness*, not a server: it reproduces the markup and CSS
// emitted by entry/src/main/ets/services/WebUi.ets with sample entries, so the
// page can be inspected in a real browser. End-to-end behaviour is still only
// proven against the watch.
'use strict';
const fs = require('fs');
const path = require('path');

const STYLE = `
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0f1115;color:#e5e7eb;font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,"PingFang SC","Microsoft YaHei",sans-serif}
header{position:sticky;top:0;background:#151922;border-bottom:1px solid #232a36;padding:10px 14px;display:flex;justify-content:space-between;align-items:center;gap:8px}
header b{font-size:16px}
header small{color:#8b93a7}
nav{padding:8px 14px;color:#8b93a7;font-size:13px;word-break:break-all}
nav a{color:#93c5fd;text-decoration:none}
main{padding:0 10px 90px}
ul{list-style:none;margin:0;padding:0}
li{display:flex;align-items:center;gap:10px;padding:11px 6px;border-bottom:1px solid #1c2230}
li .n{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
li .n a{color:#e5e7eb;text-decoration:none}
li .m{color:#8b93a7;font-size:12px;white-space:nowrap}
.ico{width:22px;text-align:center;color:#93c5fd;flex:0 0 22px}
button,.btn{background:#1d4ed8;color:#fff;border:0;border-radius:8px;padding:8px 12px;font-size:14px}
button.ghost,.btn.ghost{background:#232a36;color:#cbd5e1}
button.danger{background:#b91c1c}
input[type=text],input[type=password],input[type=file]{background:#0b0e14;border:1px solid #2b3444;color:#e5e7eb;border-radius:8px;padding:8px;font-size:14px;width:100%}
footer{position:fixed;left:0;right:0;bottom:0;background:#151922;border-top:1px solid #232a36;padding:10px 14px}
.bar{height:5px;background:#232a36;border-radius:3px;overflow:hidden;margin-top:8px}
.bar i{display:block;height:100%;width:0;background:#22c55e;transition:width .15s}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.card{background:#151922;border:1px solid #232a36;border-radius:12px;padding:14px;margin:10px}
.muted{color:#8b93a7;font-size:13px}
.err{color:#fca5a5;font-size:13px;margin-top:8px}
`;

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function fmtSize(b) {
  if (b < 1024) return b + ' B';
  if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
  if (b < 1024 * 1024 * 1024) return (b / 1024 / 1024).toFixed(1) + ' MB';
  return (b / 1024 / 1024 / 1024).toFixed(2) + ' GB';
}
function iconFor(e) {
  if (e.dir) return '📁';
  const n = e.name.toLowerCase();
  const dot = n.lastIndexOf('.');
  const ext = dot >= 0 ? n.substring(dot + 1) : '';
  if (['jpg','jpeg','png','gif','webp','bmp','heic','svg'].includes(ext)) return '🖼';
  if (['mp4','mov','mkv','webm','avi'].includes(ext)) return '🎬';
  if (['mp3','flac','wav','m4a','aac','ogg','opus','amr'].includes(ext)) return '🎵';
  if (['txt','md','pdf','doc','docx','epub'].includes(ext)) return '📄';
  if (['zip','rar','7z','tar','gz','hap','apk'].includes(ext)) return '🗜';
  return '📦';
}

const entries = [
  { name: 'Images', dir: true, size: 0 },
  { name: 'Videos', dir: true, size: 0 },
  { name: 'Audio', dir: true, size: 0 },
  { name: 'Documents', dir: true, size: 0 },
  { name: 'Archives', dir: true, size: 0 },
  { name: 'Others', dir: true, size: 0 },
  { name: 'readme.txt', dir: false, size: 58 },
  { name: '假期照片.jpg', dir: false, size: 482113 },
  { name: 'a-very-long-file-name-that-should-be-truncated-in-the-row.mkv', dir: false, size: 91234567 }
];

const csrf = '0123456789abcdef0123456789abcdef';
const rows = entries.map((e) => {
  const meta = e.dir ? '目录' : fmtSize(e.size);
  const name = esc(e.name);
  if (e.dir) {
    return `<li><span class="ico">${iconFor(e)}</span><span class="n"><a href="#">${name}</a></span><span class="m">${meta}</span></li>`;
  }
  return `<li><span class="ico">${iconFor(e)}</span>`
    + `<span class="n"><a href="#">${name}</a></span>`
    + `<span class="m">${meta}</span>`
    + `<form method="post" action="#" onsubmit="return confirm('删除 ${name} ?')" style="margin:0">`
    + `<input type="hidden" name="csrf" value="${csrf}"><input type="hidden" name="p" value="/${name}">`
    + `<button class="ghost" style="padding:4px 8px;font-size:12px">删</button></form></li>`;
}).join('');

const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>手表文件</title><style>${STYLE}</style></head><body>
<header><b>手表文件</b><small>可用 9.9 GB / 14.0 GB</small></header>
<nav><a href="#">根目录</a></nav>
<main>
  <div class="row" style="padding:0 6px 10px">
    <form method="post" action="#" class="row" style="margin:0;flex:1">
      <input type="hidden" name="csrf" value="${csrf}">
      <input type="hidden" name="p" value="/">
      <input type="text" name="name" placeholder="新建文件夹" style="flex:1;min-width:120px">
      <button class="ghost" type="submit">创建</button>
    </form>
  </div>
  <ul>${rows}</ul>
</main>
<footer>
  <div class="row">
    <input type="file" id="f" multiple style="flex:1">
    <button id="up">上传</button>
  </div>
  <div class="bar"><i id="pb"></i></div>
  <div class="muted" id="st">当前目录：/</div>
</footer>
<script>
(function(){
  var st = document.getElementById('st');
  var pb = document.getElementById('pb');
  var btn = document.getElementById('up');
  var input = document.getElementById('f');
  // Preview harness: no server behind this page, so report what a real
  // upload would have sent instead of failing silently.
  btn.onclick = function(){
    if(!input.files.length){ st.textContent = '先选择文件'; return; }
    for (var i=0;i<input.files.length;i++){
      var f = input.files[i];
      console.log('would PUT /upload?p=%2F&name=' + encodeURIComponent(f.name) + ' bytes=' + f.size);
      pb.style.width = '100%';
      st.textContent = f.name + ' 已选择（预览模式，未发送）';
    }
  };
})();
</script>
</body></html>`;

const outDir = path.join(__dirname, '..', 'preview');
fs.mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, 'index.html');
fs.writeFileSync(outFile, html, 'utf8');
console.log('written ' + outFile + ' (' + html.length + ' bytes)');
