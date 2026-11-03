"""Video frames through the real FPGA image endpoint; no PC style inference."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "deps"))
import argparse, hashlib, json, math, threading, time, zlib
from dataclasses import asdict
import cv2
from PIL import Image, ImageOps
from a_image_transfer import ImageClient, ImageDesc, save_image, pack_rgbx7
from a_image_batch import atomic_json

class LatestFrame:
    """One bounded slot. Producer overwrites stale frames; never queues a video."""
    def __init__(self):
        self.condition=threading.Condition(); self.item=None; self.done=False; self.error=None; self.dropped=0
    def put(self, item):
        with self.condition:
            if self.item is not None: self.dropped+=1
            self.item=item; self.condition.notify_all()
    def finish(self, error=None):
        with self.condition:
            self.done=True; self.error=error; self.condition.notify_all()
    def take(self):
        with self.condition:
            while self.item is None and not self.done: self.condition.wait(.2)
            if self.item is None:
                if self.error: raise RuntimeError(self.error)
                return None
            item=self.item; self.item=None; return item

def prepare(frame, style):
    image=Image.fromarray(cv2.cvtColor(frame,cv2.COLOR_BGR2RGB))
    image=ImageOps.pad(image,(1280,720),method=Image.Resampling.LANCZOS,color="white")
    raw=image.tobytes()
    return raw,ImageDesc(1280,720,1,style,3840,len(raw),zlib.crc32(raw))

def produce(cap, fps, slot, stop):
    start=time.perf_counter(); index=0
    try:
        while not stop.is_set():
            ok,frame=cap.read()
            if not ok: break
            if stop.wait(max(0,start+index/fps-time.perf_counter())): break
            slot.put((index,index/fps,time.perf_counter(),frame)); index+=1
        slot.finish()
    except BaseException as e: slot.finish(str(e))

def run(args, client_factory=ImageClient):
    source=Path(args.input).resolve(strict=True)
    if not math.isfinite(args.sample_seconds) or args.sample_seconds<=0 or args.max_frames<1: raise ValueError("positive sample interval and frame bound required")
    root=Path(args.out).resolve(); root.mkdir(parents=True,exist_ok=False)
    report=dict(client_version="video-r2-packed",status="RUNNING",mode=args.mode,source=str(source),style=args.style,frames=[],size=[1280,720],network_realtime=False,transport=getattr(args,"transport","rgb888"),packed_requires_firmware="v0.23-videofast")
    preview=None; cap=None; client=None; thread=None; stop=threading.Event(); slot=LatestFrame(); started=time.perf_counter()
    def flush():
        report["elapsed_seconds"]=time.perf_counter()-started
        report["processed_fps"]=len(report["frames"])/max(.000001,report["elapsed_seconds"])
        report["dropped_latest_slot"]=slot.dropped
        atomic_json(root/"video_report.json",report)
    try:
        if getattr(args,"preview_port",None) is not None:
            from a_video_preview import Preview
            preview=Preview(args.preview_port);report["preview_url"]=f"http://127.0.0.1:{preview.port}/";print(report["preview_url"],flush=True)
        cap=cv2.VideoCapture(str(source))
        if not cap.isOpened(): raise ValueError("video decoder could not open source")
        fps=float(cap.get(cv2.CAP_PROP_FPS))
        if not math.isfinite(fps) or fps<=0: raise ValueError("video has no valid frame rate")
        report.update(source_fps=fps,source_frame_count=int(cap.get(cv2.CAP_PROP_FRAME_COUNT)))
        flush()
        if args.mode=="latest":
            thread=threading.Thread(target=produce,args=(cap,fps,slot,stop),daemon=True);thread.start()
        client=client_factory(args.ip,40000,args.bind_ip,args.interface_index,job_timeout=60,transfer_timeout=180)
        previous_generation=None
        for number in range(args.max_frames):
            if args.mode=="latest":
                item=slot.take()
                if item is None: break
                index,pts,available,frame=item
            else:
                index=round(number*args.sample_seconds*fps)
                if not cap.set(cv2.CAP_PROP_POS_FRAMES,index): raise RuntimeError("video seek failed")
                ok,frame=cap.read()
                if not ok: break
                pts=index/fps; available=time.perf_counter()
            raw,desc=prepare(frame,args.style)
            if getattr(args,"transport","rgb888")=="packed": raw,desc=pack_rgbx7(raw,desc)
            before=dict(client.stats)
            output,result=client.transfer(raw,desc)
            if (result.width,result.height,result.format,result.style,result.stride,result.total)!=(1280,720,1,args.style,3840,2764800): raise ValueError("unexpected result descriptor")
            generation=client.stats["generation"]
            if previous_generation is not None and (generation-previous_generation)&0xffffffff!=1: raise ValueError("nonconsecutive generation; another client may be active")
            previous_generation=generation
            filename=f"frame_{number:04d}"
            save_image(root/(filename+"_input.png"),raw,desc)
            save_image(root/(filename+"_result.png"),output,result)
            counters={k:client.stats[k]-before.get(k,0) for k in ("sent","retransmissions","bad_datagrams","foreign_datagrams")}
            row=dict(number=number,source_frame=index,source_seconds=pts,age_at_result_seconds=time.perf_counter()-available,generation=generation,input_crc32=f"{desc.crc32:08x}",output_crc32=f"{result.crc32:08x}",pixel_sha256=hashlib.sha256(output).hexdigest(),input_png=filename+"_input.png",output_png=filename+"_result.png",result=asdict(result),timing={k:client.stats[k]for k in ("upload_ms","task_wait_ms","download_ms","total_ms")},counters=counters)
            report["frames"].append(row); flush(); print(json.dumps(row),flush=True)
            if preview is not None:
                left=cv2.imread(str(root/row["input_png"]));right=cv2.imread(str(root/row["output_png"]))
                canvas=cv2.hconcat([cv2.resize(left,(640,360)),cv2.resize(right,(640,360))])
                cv2.putText(canvas,f'Source {pts:.3f}s | actual FPGA result | low-rate stream',(10,25),cv2.FONT_HERSHEY_SIMPLEX,.6,(0,0,255),2)
                ok,jpeg=cv2.imencode('.jpg',canvas,[cv2.IMWRITE_JPEG_QUALITY,90])
                if not ok:raise RuntimeError("preview JPEG encode failed")
                preview.publish(jpeg.tobytes(),dict(status="RUNNING",source_frame=index,source_seconds=pts,completed_frames=len(report["frames"])))
        if not report["frames"]: raise ValueError("no video frames processed")
        # A storyboard preview, explicitly 1 fps; not an inference-rate claim.
        storyboard_writer=cv2.VideoWriter(str(root/"storyboard_1fps.avi"),cv2.VideoWriter_fourcc(*"MJPG"),1,(1280,360))
        if not storyboard_writer.isOpened(): raise RuntimeError("preview encoder unavailable")
        try:
            for row in report["frames"]:
                left=cv2.imread(str(root/row["input_png"])); right=cv2.imread(str(root/row["output_png"]))
                canvas=cv2.hconcat([cv2.resize(left,(640,360)),cv2.resize(right,(640,360))])
                cv2.putText(canvas,f'Source {row["source_seconds"]:.3f}s | FPGA result | preview 1fps',(12,26),cv2.FONT_HERSHEY_SIMPLEX,.6,(0,0,255),2)
                storyboard_writer.write(canvas)
        finally: storyboard_writer.release()
        check=cv2.VideoCapture(str(root/"storyboard_1fps.avi")); decoded=0
        try:
            while check.read()[0]: decoded+=1
        finally: check.release()
        if decoded!=len(report["frames"]): raise RuntimeError("preview decode count mismatch")
        report.update(status="PASS",storyboard_frames=decoded,storyboard_fps=1)
    except BaseException as e:
        report.update(status="INTERRUPTED"if isinstance(e,KeyboardInterrupt)else"FAIL",error=f"{type(e).__name__}: {e}")
        if client is not None: report["last_client_stats"]=dict(client.stats)
        raise
    finally:
        stop.set()
        if thread is not None: thread.join(timeout=5)
        if thread is not None and thread.is_alive():
            report.update(status="FAIL",cleanup_error="video decoder thread did not stop")
        elif cap is not None: cap.release()
        if client is not None: client.close()
        if preview is not None:
            flush()
            preview.close()
        flush()
        rows="".join(f'<tr><td>{r["source_seconds"]:.3f}s</td><td><img src="{r["input_png"]}"></td><td><img src="{r["output_png"]}"></td></tr>'for r in report["frames"])
        (root/"comparison.html").write_text('<!doctype html><meta charset="utf-8"><style>img{width:480px}body{font:16px sans-serif}</style><h1>FPGA video frames</h1><p>Source timestamps shown. Processing is slower than real time. Latest mode drops stale frames.</p><table>'+rows+'</table>',encoding="utf-8")
    return report

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument("input");ap.add_argument("--out",required=True);ap.add_argument("--mode",choices=["sample","latest"],default="sample");ap.add_argument("--sample-seconds",type=float,default=1);ap.add_argument("--max-frames",type=int,default=4);ap.add_argument("--style",type=int,choices=range(4),default=3);ap.add_argument("--ip",default="192.168.0.2");ap.add_argument("--bind-ip",default="192.168.0.3");ap.add_argument("--interface-index",type=int,default=3)
    ap.add_argument("--transport",choices=["packed","rgb888"],default="packed"); ap.add_argument("--preview-port",type=int,default=None); args=ap.parse_args();print(json.dumps(run(args),indent=2))
if __name__=="__main__": main()
