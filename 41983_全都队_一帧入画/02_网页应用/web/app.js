"use strict";
const $ = id => document.getElementById(id);
const state = {token:null,device:null,upload:null,job:null,slot:3,pending:false,uploading:false,requestKey:null,lastHistory:"",timer:null};
const terminal = new Set(["completed","failed","cancelled","interrupted"]);
function toast(message){$("toast").textContent=message;$("toast").hidden=false;clearTimeout(window.toastTimer);window.toastTimer=setTimeout(()=>$("toast").hidden=true,6000)}
const observer = new IntersectionObserver(entries=>entries.forEach(e=>{if(e.isIntersecting){e.target.classList.add("seen");observer.unobserve(e.target)}}),{threshold:.08});
document.documentElement.classList.add("js-motion");
document.querySelectorAll(".reveal").forEach((e,i)=>{e.style.transitionDelay=(i%3)*80+"ms";observer.observe(e)});
function openPage(id){document.querySelectorAll("main>.page").forEach(p=>p.classList.toggle("active",p.id===id));document.querySelectorAll(".nav-item").forEach(b=>b.classList.toggle("active",b.dataset.go===id));window.scrollTo(0,0);if(id==="archive"&&state.token)renderHistory().catch(e=>toast(e.message));if(id==="home")document.querySelectorAll("#home .reveal").forEach(x=>observer.observe(x))}
document.querySelectorAll("[data-go]").forEach(b=>b.addEventListener("click",e=>{e.preventDefault();openPage(b.dataset.go)}));
document.querySelectorAll("[data-entry]").forEach(b=>b.onclick=()=>{openPage("device");toast("在设备页连接USB串口后，可切换"+(b.dataset.entry==="camera"?"摄像头":"HDMI")+"输入")});
async function api(path,body,options={}){
  const headers={...options.headers};
  if(body!==undefined){headers["X-Yizhen-Token"]=state.token||"";if(!options.binary)headers["Content-Type"]="application/json"}
  const response=await fetch(path,{method:body===undefined?"GET":"POST",headers,body:body===undefined?undefined:options.binary?body:JSON.stringify(body)});
  const value=await response.json();if(!response.ok)throw new Error(value.error||"请求失败");return value;
}
function busy(){return state.pending||state.uploading||Boolean(state.device?.active_job||state.device?.operation)||Boolean(state.job&&!terminal.has(state.job.status))}
function updateButtons(){
  const blocked=busy(),recovery=state.device?.recovery_required||state.device?.storage_error;
  $("start").disabled=!state.token||blocked||recovery||!state.upload||!state.device?.network?.image_ready;
  $("cancel").disabled=!state.job||terminal.has(state.job.status)||["saving","release","done","cancelling"].includes(state.job.phase);
  $("choose").disabled=blocked;document.querySelectorAll("[data-slot]").forEach(e=>e.disabled=blocked);
  $("connect").disabled=blocked||!state.token;
  $("refresh-health").disabled=blocked||!state.device?.serial?.online;
  $("recover").disabled=blocked||!state.token||!state.device?.network?.online;
  document.querySelectorAll("[data-control]").forEach(e=>e.disabled=blocked||recovery||!state.device?.serial?.online);
}
function timeLabel(seconds){return seconds?new Date(seconds*1000).toLocaleString("zh-CN"):"尚未采样"}
function renderDevice(device,fill=false){
  state.device=device;
  $("net-pill").textContent=device.offline_fixture?"● 测试UDP端点":device.network.image_ready?"● 网口图片就绪":"○ 网口未就绪";
  $("serial-pill").textContent=device.offline_fixture?"● 模拟串口":device.serial.online?"● 串口已连接":"○ 串口未连接";
  $("app-status").textContent=device.offline_fixture?"离线协议测试 · 非FPGA推理":device.recovery_required?"需要检查并释放上次会话":device.active_job?"板端图片任务进行中":"本地服务就绪 · "+(device.network.image_ready||device.serial.online?"设备已连接":"设备未连接");
  $("device-stamp").textContent=device.serial.online?"USB串口已连接":"USB串口未连接";
  const messages=["网口："+(device.network.image_ready?"图片会话探测通过":device.network.error||"未就绪"),"串口："+(device.serial.online?(device.serial.raw?.match(/firmware=([^\r\n]+)/)?.[1]||device.serial.port):device.serial.error||"未连接")];
  if(device.storage_error)messages.push("记录存储异常，请保存现有结果，检查磁盘空间并重启："+device.storage_error);
  if(device.recovery_required)messages.push("上次取消/错误的会话释放尚未确认，先点击“检查并恢复会话”。");
  $("connection-state").textContent=messages.join("；");
  if(fill){const c=device.config;$("board-address").value=c.ip+":"+c.port;$("bind-ip").value=c.bind_ip;$("interface-index").value=c.interface_index??"";$("serial-port").value=c.serial_port;$("transport").value=c.transport}
  const h=device.health;
  $("health-summary").textContent=h?["最近采样："+timeLabel(h.checked_at),"本地采集 "+(h.values.video.CAP??"—")+" fps","实际新结果 "+(h.values.video.NEW??"—")+" fps","HDMI刷新 "+(h.values.video.HDMI??"—")+" Hz","活动槽位 "+(h.values.nnstatus.active_model??"—"),"模型CRC "+(h.values["weights status"].crc_verified===1?"通过":"未通过"),"摄像头 "+(h.values["camera status"]?.camera_ready===1?"就绪":"未就绪"),"HDMI输入 "+(h.values["hdmi status"]?.pll_lock===1?"已锁定":"未锁定")].join(" · "):"尚无有效健康采样；图片任务期间暂停串口查询。";
  $("health-detail").textContent=JSON.stringify({network:device.network,serial:device.serial,health:h},null,2);
  if(h){
    const flags={source:h.values["source status"].override===0?"buttons":h.values["source status"].active?.toLowerCase(),style:String(h.values.nnstatus.active_model),light:h.values.light.mode===3?"auto":h.values.light.mode===0?"off":null};
    document.querySelectorAll("[data-control]").forEach(e=>{if(e.dataset.control in flags)e.classList.toggle("selected",e.dataset.value===flags[e.dataset.control])});
  }
  updateButtons();
}
function compareMode(wipe){$("comparison").classList.toggle("wipe",wipe);$("wipe-tools").hidden=!wipe;$("parallel").classList.toggle("selected",!wipe);$("wipe").classList.toggle("selected",wipe)}
$("parallel").onclick=()=>compareMode(false);$("wipe").onclick=()=>compareMode(true);
$("wipe-range").oninput=e=>$("comparison").style.setProperty("--split",e.target.value+"%");
function clearOutput(){ $("output").hidden=true;$("empty-result").hidden=false;$("output-label").textContent="等待本次板端结果";$("download").hidden=true;$("download").removeAttribute("href");$("result-info").textContent="尚未获得本次结果";$("report-link").hidden=true}
function setUpload(upload){
  state.upload=upload;state.requestKey=null;$("original").src=upload.preview_url;$("original").alt="本次实际提交的1280×720图片";
  $("origin-label").textContent="提交预览 / ORIGINAL";$("canvas-title").textContent="你的这一帧";
  $("image-info").textContent=upload.name+" · 等比缩放/白色补边至1280 × 720";
  clearOutput();compareMode(false);$("task-state").textContent="图片准备完成，连接网口后开始板端绘画";updateButtons();
}
async function chooseFile(file){
  if(busy())return toast("任务结束后再更换图片");
  if(!file||file.size>20*1024*1024)return toast("请选择20MiB以内的单帧图片");
  state.uploading=true;state.upload=null;state.job=null;clearOutput();updateButtons();$("task-state").textContent="正在解码并生成实际提交预览…";
  try{const u=await api("/api/uploads",file,{binary:true,headers:{"Content-Type":"application/octet-stream","X-Upload-Name":encodeURIComponent(file.name)}});u.name=file.name;setUpload(u)}
  catch(e){$("task-state").textContent="图片准备失败："+e.message;toast(e.message)}
  finally{state.uploading=false;$("file").value="";updateButtons()}
}
$("choose").onclick=()=>$("file").click();
$("file").onchange=e=>chooseFile(e.target.files[0]);
$("drop-zone").ondragover=e=>{e.preventDefault();$("drop-zone").classList.add("drag")};
$("drop-zone").ondragleave=()=>$("drop-zone").classList.remove("drag");
$("drop-zone").ondrop=e=>{e.preventDefault();$("drop-zone").classList.remove("drag");chooseFile(e.dataTransfer.files[0])};
document.querySelectorAll("[data-slot]").forEach(b=>b.onclick=()=>{if(busy())return;state.slot=Number(b.dataset.slot);state.requestKey=null;document.querySelectorAll("[data-slot]").forEach(e=>e.classList.toggle("selected",e===b));$("current-slot").textContent="SLOT "+state.slot;toast("新图片任务将使用槽位 "+state.slot+"；不会改动屏幕全局风格")});
const phases={preparing:["准备图片",0],capability:["探测板端图片能力",0],begin:["申请板端缓存",0],upload:["正在上传图片",1],commit:["输入校验与板端处理",2],ready_status:["板端处理，等待结果",2],download:["正在接收结果",3],release:["正在释放板端会话",3],saving:["CRC已通过，正在保存结果",4],done:["本次结果已校验并保存",5],failed:["任务失败",0],cancelled:["任务已取消",0],cancelling:["正在取消并清理会话",0],interrupted:["上次任务状态未确认",0]};
function renderJob(job){
  state.job=job;localStorage.setItem("yizhen-last-job",job.id);if(terminal.has(job.status)){if(state.requestKey===job.idempotency_key)state.requestKey=null;try{if(JSON.parse(localStorage.getItem("yizhen-pending-submit")||"null")?.key===job.idempotency_key)localStorage.removeItem("yizhen-pending-submit")}catch{}}
  const [label,index]=phases[job.phase]||[job.phase,0];
  [...$("phases").children].forEach((e,i)=>{e.classList.toggle("done",i<index);e.classList.toggle("current",i===index&&!terminal.has(job.status))});
  $("task-state").textContent=label+(job.error?"："+job.error:"")+(job.storage_warning?"；"+job.storage_warning:"");
  $("task-label").textContent=job.id.slice(0,8).toUpperCase()+" / SLOT "+job.slot;
  $("hdmi-title").textContent=label;$("hdmi-sub").textContent="网页状态 · HDMI反馈取决于实际烧录版本";
  document.querySelector(".hdmi-orb").classList.toggle("busy",!terminal.has(job.status));
  const transfer=job.phase==="upload"||job.phase==="download";
  $("transfer-progress").hidden=!transfer;
  if(transfer){const bytes=job.phase==="upload"?job.upload_bytes:job.download_bytes,total=job.phase==="upload"?job.upload_total:job.download_total;
    $("byte-progress").max=total;$("byte-progress").value=bytes;$("byte-label").textContent=(bytes/1024/1024).toFixed(2)+" / "+(total/1024/1024).toFixed(2)+" MiB · "+Math.min(100,Math.floor(bytes/total*100))+"%"}
  $("elapsed").textContent="总用时 "+((job.finished_at||Date.now()/1000)-job.created_at).toFixed(1)+" s";
  if(job.status==="completed"){
    $("output").src=job.result_url;$("output").alt=job.execution==="offline_identity_fixture"?"离线协议夹具返回的图像，不是FPGA推理":"本次FPGA返回且CRC校验通过的图像";$("output").hidden=false;$("empty-result").hidden=true;
    $("output-label").textContent=(job.execution==="offline_identity_fixture"?"离线回环测试 / SLOT ":"FPGA RESULT / SLOT ")+job.slot;$("result-info").textContent="CRC32 "+job.stats.output_crc32+" · 已保存";
    $("download").textContent="保存本次作品 ↓";$("download").href=job.result_url;$("download").download="yizhen_"+job.id.slice(0,8)+".png";$("download").hidden=false;
    $("report-link").href="/api/jobs/"+job.id+"/report";$("report-link").hidden=false;
  }else if(terminal.has(job.status)){$("report-link").href="/api/jobs/"+job.id+"/report";$("report-link").hidden=false}
  updateButtons();
}
$("start").onclick=async()=>{
  if(busy()||!state.upload)return;
  state.pending=true;clearOutput();updateButtons();
  const fingerprint=state.upload.id+":"+state.slot;
  let saved;try{saved=JSON.parse(localStorage.getItem("yizhen-pending-submit")||"null")}catch{}
  const key=state.requestKey||(saved?.fingerprint===fingerprint?saved.key:crypto.randomUUID());state.requestKey=key;
  localStorage.setItem("yizhen-pending-submit",JSON.stringify({fingerprint,key}));
  try{const job=await api("/api/jobs",{upload_id:state.upload.id,slot:state.slot,idempotency_key:key});renderJob(job)}
  catch(e){toast(e.message);$("task-state").textContent="提交未确认："+e.message+"；重试将沿用同一任务键"}
  finally{state.pending=false;updateButtons()}
};
$("cancel").onclick=async()=>{if(!state.job)return;try{renderJob(await api("/api/jobs/"+state.job.id+"/cancel",{}))}catch(e){toast(e.message)}};
async function renderHistory(){
  const jobs=await api("/api/history");const signature=JSON.stringify(jobs.map(j=>[j.id,j.status,j.updated_at]));
  if(signature===state.lastHistory)return;state.lastHistory=signature;
  const host=$("history-list");host.replaceChildren();
  for(const job of jobs){
    const card=document.createElement("article");card.className="history-row";
    if(job.status==="completed"){const img=document.createElement("img");img.src=job.result_url;img.alt="已校验任务缩略图";card.append(img)}
    const copy=document.createElement("div"),title=document.createElement("h3"),meta=document.createElement("p"),buttons=document.createElement("div");
    title.textContent=job.name||"图片任务";
    meta.textContent=(job.execution==="offline_identity_fixture"?"离线夹具 / 非FPGA · ":"")+timeLabel(job.created_at)+" · SLOT "+job.slot+" · "+({completed:"已校验保存",failed:"失败",cancelled:"已取消",running:"进行中",interrupted:"待恢复"}[job.status]||job.status);
    const view=document.createElement("button");view.className="button quiet";view.textContent="查看任务";view.onclick=()=>showSaved(job.id);
    const report=document.createElement("a");report.href="/api/jobs/"+job.id+"/report";report.textContent="任务报告 ↗";
    buttons.append(view,report);
    if(job.status==="completed"){const result=document.createElement("a");result.href=job.result_url;result.download="yizhen_"+job.id.slice(0,8)+".png";result.textContent="保存PNG ↓";buttons.append(result)}
    copy.append(title,meta,buttons);card.append(copy);host.append(card);
  }
  if(!jobs.length){const p=document.createElement("p");p.textContent="还没有本应用的任务记录。";host.append(p)}
}
async function showSaved(id){
  try{const job=await api("/api/jobs/"+id);state.upload={id:job.upload_id,preview_url:job.preview_url,name:job.name};$("original").src=job.preview_url;$("original").alt="本次实际提交的1280×720图片";$("origin-label").textContent="本次提交 / ORIGINAL";$("canvas-title").textContent="任务 "+job.id.slice(0,8);$("image-info").textContent=job.name+" · 1280 × 720";clearOutput();renderJob(job);openPage("studio")}
  catch(e){toast(e.message)}
}
function configFromForm(){
  const match=$("board-address").value.trim().match(/^([0-9.]+):([0-9]+)$/);if(!match)throw new Error("板卡地址格式应为 192.168.0.2:40000");
  return {ip:match[1],port:Number(match[2]),bind_ip:$("bind-ip").value.trim(),interface_index:$("interface-index").value.trim()?Number($("interface-index").value):null,serial_port:$("serial-port").value.trim().toUpperCase(),baud:115200,transport:$("transport").value};
}
$("connect").onclick=async()=>{state.pending=true;updateButtons();$("connection-state").textContent="正在分别探测网口与串口，请稍候…";try{renderDevice(await api("/api/device/connect",configFromForm()));toast("连接探测结束，请查看两条通路各自的结果")}catch(e){toast(e.message);$("connection-state").textContent=e.message}finally{state.pending=false;updateButtons()}};
$("refresh-health").onclick=async()=>{state.pending=true;updateButtons();try{renderDevice(await api("/api/device/refresh",{}));toast("已读取新的板端状态")}catch(e){toast(e.message)}finally{state.pending=false;updateButtons()}};
$("recover").onclick=async()=>{state.pending=true;updateButtons();$("connection-state").textContent="检查空会话能否申请并释放；不会执行模型…";try{await api("/api/device/recover",{});renderDevice(await api("/api/device"));toast("空会话申请与释放通过，可继续任务；摄像头更新仍需读取状态确认")}catch(e){toast("恢复未确认："+e.message);$("connection-state").textContent="会话恢复未确认："+e.message}finally{state.pending=false;updateButtons()}};
document.querySelectorAll("[data-control]").forEach(b=>b.onclick=async()=>{
  state.pending=true;updateButtons();$("control-state").textContent="正在发送请求并查询状态…";
  try{
    const result=await api("/api/device/control",{type:b.dataset.control,value:b.dataset.value});
    $("control-state").textContent=(result.confirmed?"已接受 · 查询已确认。":"已接受 · 仍需确认。")+result.note;
    if(result.confirmed){document.querySelectorAll('[data-control="'+b.dataset.control+'"]').forEach(e=>e.classList.toggle("selected",e===b))}
    if(b.dataset.control==="roi"){const cfg={full:["5%","5%","90%","90%"],center:["25%","15%","50%","70%"],left:["5%","5%","45%","90%"],right:["50%","5%","45%","90%"]}[b.dataset.value];["left","top","width","height"].forEach((k,i)=>document.querySelector(".roi-figure>div").style[k]=cfg[i])}
  }catch(e){$("control-state").textContent="操作失败："+e.message;toast(e.message)}
  finally{state.pending=false;updateButtons()}
});
async function poll(){
  try{
    renderDevice(await api("/api/device"));
    const id=state.device.active_job||(state.job&&!terminal.has(state.job.status)?state.job.id:null);
    if(id){const job=await api("/api/jobs/"+id);if(!state.upload||state.upload.id!==job.upload_id){state.upload={id:job.upload_id,name:job.name,preview_url:job.preview_url};$("original").src=job.preview_url;clearOutput()}renderJob(job);
      if(terminal.has(job.status)){state.requestKey=null;localStorage.removeItem("yizhen-pending-submit");await renderHistory()}}
  }catch(e){$("app-status").textContent="本地服务暂不可达；已有任务不会因页面断线而自动重发"}
  state.timer=setTimeout(poll,1000);
}
async function boot(){
  updateButtons();
  try{
    const value=await api("/api/bootstrap");state.token=value.token;renderDevice(value.device,true);
    for(const port of value.ports){const option=document.createElement("option");option.value=port.port;option.label=port.description;$("serial-ports").append(option)}
    await renderHistory();
    const id=value.device.active_job||localStorage.getItem("yizhen-last-job");
    if(id){try{await showSaved(id)}catch{}}
    poll();
  }catch(e){$("app-status").textContent="请从启动应用.cmd打开本地服务";toast("本地服务未连接："+e.message)}
}
boot();
