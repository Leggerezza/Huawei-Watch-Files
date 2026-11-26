import { FsEntry } from './FsStore';

/** Escapes text for HTML text nodes and quoted attributes. */
export function esc(text: string): string {
  let out: string = '';
  for (let i = 0; i < text.length; i++) {
    const c: string = text.charAt(i);
    if (c === '&') {
      out += '&amp;';
    } else if (c === '<') {
      out += '&lt;';
    } else if (c === '>') {
      out += '&gt;';
    } else if (c === '"') {
      out += '&quot;';
    } else if (c === '\'') {
      out += '&#39;';
    } else {
      out += c;
    }
  }
  return out;
}

export function fmtSize(bytes: number): string {
  if (bytes < 0) {
    return '?';
  }
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

/** Percent-encodes a virtual path for use in a query value. */
export function enc(text: string): string {
  return encodeURIComponent(text);
}

const STYLE: string = `
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

function shell(title: string, body: string): string {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">`
    + `<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">`
    + `<title>${esc(title)}</title><style>${STYLE}</style></head><body>${body}</body></html>`;
}

export function loginPage(error: string): string {
  const err: string = error.length > 0 ? `<div class="err">${esc(error)}</div>` : '';
  const body: string = `
<header><b>手表文件</b><small>需要访问码</small></header>
<div class="card">
  <p class="muted">输入手表屏幕上显示的 HTTP 访问码。访问码每次启动都会变化。</p>
  <form method="post" action="/login">
    <input type="password" name="code" inputmode="latin" autocomplete="off" placeholder="访问码" autofocus>    <div class="row" style="margin-top:10px"><button type="submit">进入</button></div>
  </form>
  ${err}
</div>`;
  return shell('手表文件 · 登录', body);
}

export function messagePage(title: string, text: string, backTo: string): string {
  const back: string = backTo.length > 0 ? `<div class="row" style="margin-top:12px"><a class="btn ghost" href="${esc(backTo)}">返回</a></div>` : '';
  const body: string = `
<header><b>${esc(title)}</b></header>
<div class="card"><p>${esc(text)}</p>${back}</div>`;
  return shell(`手表文件 · ${title}`, body);
}

function crumb(path: string): string {
  let html: string = `<a href="/?p=%2F">根目录</a>`;
  if (path === '/') {
    return html;
  }
  const parts: string[] = path.split('/').filter((p: string) => p.length > 0);
  let acc: string = '';
  for (let i = 0; i < parts.length; i++) {
    acc += '/' + parts[i];
    html += ` / <a href="/?p=${enc(acc)}">${esc(parts[i])}</a>`;
  }
  return html;
}

function iconFor(e: FsEntry): string {
  if (e.isDir) {
    return '📁';
  }
  const n: string = e.name.toLowerCase();
  const dot: number = n.lastIndexOf('.');
  const ext: string = dot >= 0 ? n.substring(dot + 1) : '';
  if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'svg'].indexOf(ext) >= 0) {
    return '🖼';
  }
  if (['mp4', 'mov', 'mkv', 'webm', 'avi'].indexOf(ext) >= 0) {
    return '🎬';
  }
  if (['mp3', 'flac', 'wav', 'm4a', 'aac', 'ogg', 'opus', 'amr'].indexOf(ext) >= 0) {
    return '🎵';
  }
  if (['txt', 'md', 'pdf', 'doc', 'docx', 'epub'].indexOf(ext) >= 0) {
    return '📄';
  }
  if (['zip', 'rar', '7z', 'tar', 'gz', 'hap', 'apk'].indexOf(ext) >= 0) {
    return '🗜';
  }
  return '📦';
}

function entryRow(e: FsEntry, dirPath: string): string {
  const full: string = dirPath === '/' ? `/${e.name}` : `${dirPath}/${e.name}`;
  const name: string = esc(e.name);
  const meta: string = e.isDir ? '目录' : fmtSize(e.size);
  if (e.isDir) {
    return `<li><span class="ico">${iconFor(e)}</span>`
      + `<span class="n"><a href="/?p=${enc(full)}">${name}</a></span>`
      + `<span class="m">${meta}</span></li>`;
  }
  return `<li><span class="ico">${iconFor(e)}</span>`
    + `<span class="n"><a href="/dl?p=${enc(full)}">${name}</a></span>`
    + `<span class="m">${meta}</span>`
    + `<form method="post" action="/delete" onsubmit="return confirm('删除 ${esc(e.name)} ?')" style="margin:0">`
    + `<input type="hidden" name="csrf" value="__CSRF__"><input type="hidden" name="p" value="${esc(full)}">`
    + `<button class="ghost" aria-label="删除 ${name}" style="padding:8px 10px;font-size:13px">删</button></form></li>`;
}

/** JSON for an inline <script>: escapes '<' so a file name cannot close the tag. */
function jsStr(text: string): string {
  return JSON.stringify(text).replace(/</g, '\\u003c').replace(/>/g, '\\u003e').replace(/&/g, '\\u0026');
}

export interface PageInput {
  path: string;
  entries: FsEntry[];
  free: number;
  total: number;
  csrf: string;
  classify: boolean;
}

export function browsePage(input: PageInput): string {
  let rows: string = '';
  const dirPath: string = input.path === '/' ? '' : input.path;
  if (input.path !== '/') {
    const parent: string = input.path.lastIndexOf('/') <= 0 ? '/' : input.path.substring(0, input.path.lastIndexOf('/'));
    rows += `<li><span class="ico">↩</span><span class="n"><a href="/?p=${enc(parent)}">.. 上一级</a></span></li>`;
  }
  for (let i = 0; i < input.entries.length; i++) {
    rows += entryRow(input.entries[i], dirPath === '' ? '/' : dirPath);
  }
  if (input.entries.length === 0) {
    rows = `<li><span class="m" style="padding:10px">这个目录是空的</span></li>`;
  }

  const body: string = `
<header><b>手表文件</b><small>可用 ${fmtSize(input.free)} / ${fmtSize(input.total)}</small></header>
<nav>${crumb(input.path)}</nav>
<main>
  <div class="row" style="padding:0 6px 10px">
    <form method="post" action="/mkdir" class="row" style="margin:0;flex:1">
      <input type="hidden" name="csrf" value="${esc(input.csrf)}">
      <input type="hidden" name="p" value="${esc(input.path)}">
      <input type="text" name="name" placeholder="新建文件夹" autocomplete="off" style="flex:1;min-width:120px">
      <button class="ghost" type="submit">创建</button>
    </form>
  </div>
  <ul>${rows.replace(/__CSRF__/g, esc(input.csrf))}</ul>
</main>
<footer>
  <div class="row">
    <input type="file" id="f" multiple style="flex:1">
    <button id="up">上传</button>
  </div>
  <div class="bar"><i id="pb"></i></div>
  <div class="muted" id="st">当前目录：${esc(input.path)}</div>
</footer>
<script>
(function(){
  var dir = ${jsStr(input.path)};
  var csrf = ${jsStr(input.csrf)};
  var btn = document.getElementById('up');
  var input = document.getElementById('f');
  var pb = document.getElementById('pb');
  var st = document.getElementById('st');
  btn.onclick = async function(){
    if(!input.files.length){ st.textContent = '先选择文件'; return; }
    btn.disabled = true;
    for (var i=0;i<input.files.length;i++){
      var f = input.files[i];
      var url = '/upload?p=' + encodeURIComponent(dir) + '&name=' + encodeURIComponent(f.name) + '&csrf=' + encodeURIComponent(csrf);
      await new Promise(function(resolve){
        var x = new XMLHttpRequest();
        x.open('POST', url);
        x.setRequestHeader('Content-Type','application/octet-stream');
        x.upload.onprogress = function(e){
          if(e.lengthComputable){
            var pct = Math.round(e.loaded*100/e.total);
            pb.style.width = pct + '%';
            st.textContent = f.name + ' ' + pct + '%';
          }
        };
        x.onload = function(){
          st.textContent = x.status < 400 ? (f.name + ' 上传完成') : (f.name + ' 失败: ' + x.status);
          resolve();
        };
        x.onerror = function(){ st.textContent = f.name + ' 网络错误'; resolve(); };
        x.send(f);
      });
    }
    btn.disabled = false;
    setTimeout(function(){ location.reload(); }, 600);
  };
})();
</script>`;
  return shell('手表文件', body);
}
