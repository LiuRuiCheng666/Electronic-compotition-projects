(() => {
"use strict";
document.body.classList.add("scifi");
const canvas=document.getElementById("art-3d"), frame=document.getElementById("art-frame");
const toggle=document.getElementById("motion-toggle"), theme=document.getElementById("theme-toggle");
const reduced=matchMedia("(prefers-reduced-motion: reduce)");
let paused=reduced.matches,time=0,last=0,visible=true,targetX=0,targetY=0,mouseX=0,mouseY=0;
function syncMotion(){document.body.classList.toggle("motion-paused",paused);toggle.textContent=paused?"开启动效":"暂停动效";toggle.setAttribute("aria-pressed",String(paused));if(frame.classList.contains("gl-ready")){document.getElementById("render-status").textContent=paused?"WEBGL / PAUSED":"WEBGL / LIVE 3D";document.getElementById("scene-mode").textContent=paused?"3D / PAUSED":"LIVE 3D VISUAL";}}
syncMotion();
toggle.onclick=()=>{paused=!paused;syncMotion()};
theme.onclick=()=>{const dark=document.body.classList.toggle("scifi");theme.textContent=dark?"科幻模式":"宣纸模式";theme.setAttribute("aria-pressed",String(dark));if(render)render(time)};
reduced.addEventListener("change",e=>{paused=e.matches;syncMotion()});
frame.addEventListener("pointermove",e=>{if(paused)return;const b=frame.getBoundingClientRect();targetX=((e.clientX-b.left)/b.width-.5)*2;targetY=((e.clientY-b.top)/b.height-.5)*2});
frame.addEventListener("pointerleave",()=>{targetX=targetY=0});
new IntersectionObserver(e=>{visible=e[0].isIntersecting},{threshold:.05}).observe(frame);
let gl=null,render=null;
try{gl=canvas.getContext("webgl",{alpha:true,antialias:true,powerPreference:"low-power"})}catch(e){}
function fallback(label){canvas.hidden=true;frame.classList.remove("gl-ready");document.getElementById("render-status").textContent=label;document.getElementById("scene-mode").textContent="STATIC VISUAL / 兼容模式";}
if(!gl){fallback("3D FALLBACK / 视觉降级");return}
const vs="attribute vec3 aPosition;uniform float uTime,uYaw,uPitch,uAspect;varying vec3 vWorld;varying float vDepth;void main(){vWorld=aPosition;float c=cos(uYaw),s=sin(uYaw);vec3 p=vec3(c*aPosition.x+s*aPosition.z,aPosition.y,-s*aPosition.x+c*aPosition.z);c=cos(uPitch);s=sin(uPitch);p=vec3(p.x,c*p.y-s*p.z,s*p.y+c*p.z);float d=7.0-p.z;vDepth=d;gl_Position=vec4(p.x*1.65/uAspect,p.y*1.65,(30.1/29.9)*d-(6.0/29.9),d);gl_PointSize=2.0+6.0/d;}";
const fs="precision mediump float;uniform float uTime,uPass,uDark;varying vec3 vWorld;varying float vDepth;void main(){float sd=(vWorld.z-2.9*sin(uTime*.45))/.14;float scan=exp(-sd*sd);float h=clamp((vWorld.y+.85)/2.7,0.0,1.0);vec3 col=mix(vec3(.035,.10,.16),vec3(.17,.39,.46),h);float a=.95;if(uPass>.5&&uPass<1.5){col=mix(vec3(.23,.62,.66),vec3(.74,.93,.83),h);a=.24+h*.27;}if(uPass>1.5&&uPass<2.5){float d=length(gl_PointCoord-vec2(.5));if(d>.5)discard;col=vec3(.56,.81,.85);a=(1.0-d*2.0)*(.2+.5*abs(sin(vWorld.x*2.7+uTime*.6)));}if(uPass>2.5){col=vec3(.88,.58,.34);a=.34;}col=mix(col,vec3(1.0,.67,.36),scan*.85);a+=scan*.25;if(uDark<.5){col=mix(vec3(.20,.32,.25),vec3(.54,.65,.48),h);if(uPass>.5)col=mix(vec3(.42,.53,.39),vec3(.67,.34,.21),scan);a*=.9;}float fog=clamp((12.0-vDepth)/7.0,.15,1.0);gl_FragColor=vec4(col,a*fog);}";
function shader(type,src){const s=gl.createShader(type);gl.shaderSource(s,src);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s}
let program;
try{program=gl.createProgram();gl.attachShader(program,shader(gl.VERTEX_SHADER,vs));gl.attachShader(program,shader(gl.FRAGMENT_SHADER,fs));gl.linkProgram(program);if(!gl.getProgramParameter(program,gl.LINK_STATUS))throw Error(gl.getProgramInfoLog(program));}catch(e){fallback("VISUAL FALLBACK");return}
gl.useProgram(program);
const loc={pos:gl.getAttribLocation(program,"aPosition"),time:gl.getUniformLocation(program,"uTime"),yaw:gl.getUniformLocation(program,"uYaw"),pitch:gl.getUniformLocation(program,"uPitch"),aspect:gl.getUniformLocation(program,"uAspect"),pass:gl.getUniformLocation(program,"uPass"),dark:gl.getUniformLocation(program,"uDark")};
function height(x,z){return -.9+2.0*Math.exp(-((x+1.1)*(x+1.1)*1.5+(z+.3)*(z+.3)*1.9))+1.7*Math.exp(-((x-.95)*(x-.95)*1.7+(z+.6)*(z+.6)*2.2))+.7*Math.exp(-(x*x*.9+(z-1.2)*(z-1.2)*1.3))+.11*Math.sin(x*6+z*4)*Math.exp(-.2*(x*x+z*z));}
const N=82,vertices=[],lines=[],points=[];
function point(i,j){const x=(i/N-.5)*6.1,z=(j/N-.5)*5.3;return [x,height(x,z),z]}
for(let i=0;i<N;i++)for(let j=0;j<N;j++){const a=point(i,j),b=point(i+1,j),c=point(i,j+1),d=point(i+1,j+1);vertices.push(...a,...b,...c,...b,...d,...c);if(i%2===0)lines.push(...a,...c);if(j%2===0)lines.push(...a,...b);if(i%5===0&&j%5===0)points.push(...a)}
let seed=17;function rand(){seed=(seed*1664525+1013904223)>>>0;return seed/4294967296}
for(let i=0;i<190;i++)points.push((rand()-.5)*7.5,rand()*3.5-.2,(rand()-.5)*5.5);
const ring=[];for(let i=0;i<180;i++){const a=i*Math.PI*2/180,b=(i+1)*Math.PI*2/180;ring.push(Math.cos(a)*3.1,-.62+Math.sin(a)*.4,Math.sin(a)*2.8,Math.cos(b)*3.1,-.62+Math.sin(b)*.4,Math.sin(b)*2.8)}
function buffer(arr){const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array(arr),gl.STATIC_DRAW);return {b,count:arr.length/3}}
const mesh=buffer(vertices),wire=buffer(lines),stars=buffer(points),orbit=buffer(ring);
function draw(buf,mode,pass){gl.bindBuffer(gl.ARRAY_BUFFER,buf.b);gl.vertexAttribPointer(loc.pos,3,gl.FLOAT,false,0,0);gl.enableVertexAttribArray(loc.pos);gl.uniform1f(loc.pass,pass);gl.drawArrays(mode,0,buf.count)}
render=t=>{const w=frame.clientWidth,h=frame.clientHeight,dpr=Math.min(devicePixelRatio||1,1.8);if(w<=0||h<=0)return;if(canvas.width!==Math.round(w*dpr)||canvas.height!==Math.round(h*dpr)){canvas.width=Math.round(w*dpr);canvas.height=Math.round(h*dpr)}gl.viewport(0,0,canvas.width,canvas.height);gl.clearColor(0,0,0,0);gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);gl.uniform1f(loc.aspect,w/h);gl.uniform1f(loc.time,t);gl.uniform1f(loc.yaw,-.35+Math.sin(t*.12)*.22+mouseX*.25);gl.uniform1f(loc.pitch,.65+mouseY*.12);gl.uniform1f(loc.dark,document.body.classList.contains("scifi")?1:0);gl.enable(gl.BLEND);gl.blendFunc(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA);gl.enable(gl.DEPTH_TEST);gl.enable(gl.POLYGON_OFFSET_FILL);gl.polygonOffset(1,1);draw(mesh,gl.TRIANGLES,0);gl.disable(gl.POLYGON_OFFSET_FILL);gl.depthMask(false);gl.blendFunc(gl.SRC_ALPHA,gl.ONE);draw(wire,gl.LINES,1);draw(stars,gl.POINTS,2);gl.uniform1f(loc.yaw,t*.06-.35);draw(orbit,gl.LINES,3);gl.depthMask(true)};
frame.classList.add("gl-ready");syncMotion();
render(0);
function tick(ts){requestAnimationFrame(tick);const dt=last?Math.min((ts-last)/1000,.05):0;last=ts;if(paused||document.hidden||!visible)return;time+=dt;mouseX+=(targetX-mouseX)*.05;mouseY+=(targetY-mouseY)*.05;frame.style.transform="perspective(1100px) rotateY("+(mouseX*4)+"deg) rotateX("+(-mouseY*2.5)+"deg)";render(time)}
requestAnimationFrame(tick);
canvas.addEventListener("webglcontextlost",e=>{e.preventDefault();paused=true;syncMotion();fallback("CONTEXT LOST / 视觉降级")});
new ResizeObserver(()=>render(time)).observe(frame);
})();
