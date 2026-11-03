"""Batch real FPGA inference with bounded job retry and auditable PNG/JSON/HTML output."""
from pathlib import Path
from dataclasses import asdict,replace
import argparse,datetime,hashlib,html,json,os,secrets,tempfile,time,zlib
from a_image_transfer import ImageClient,TransferError,load_image,save_image

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def atomic_json(path,obj):
    path=Path(path);tmp=None
    try:
        with tempfile.NamedTemporaryFile(mode='w',encoding='utf-8',dir=path.parent,delete=False)as f:
            tmp=Path(f.name);json.dump(obj,f,ensure_ascii=False,indent=2);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path);tmp=None
    finally:
        if tmp is not None:tmp.unlink(missing_ok=True)

def render_report(root,report):
    esc=lambda x:html.escape(str(x),quote=True)
    rows=[]
    for item in report['images']:
        cells=[f'<td><img src="{esc(item["input_png"])}"><br>{esc(item["source"])}</td>']
        for job in item['jobs']:
            if job['status']=='PASS':
                cells.append(f'<td><img src="{esc(job["output_png"])}"><br>slot {job["style"]}; CRC {job["pixel_crc32"]}; {job["stats"]["total_ms"]/1000:.2f}s</td>')
            else:cells.append(f'<td>slot {job["style"]}: {esc(job["status"])}<br>{esc(job.get("error",""))}</td>')
        rows.append('<tr>'+''.join(cells)+'</tr>')
    body='<!doctype html><meta charset="utf-8"><title>FPGA image comparison</title><style>body{font:16px sans-serif;background:#eee}table{border-collapse:collapse}td{background:white;border:1px solid #bbb;padding:8px;vertical-align:top}img{width:320px;max-width:30vw}p{max-width:1100px}</style>'
    body+=f'<h1>FPGA batch: {esc(report["status"])}</h1><p>Outputs are returned by the FPGA. Slot names depend on weights already in Flash; this report does not infer model identity or artistic quality. Network jobs pause camera inference until release. Input previews show the exact padded RGB image sent.</p><table>'+''.join(rows)+'</table>'
    path=root/'comparison.html';tmp=root/'comparison.html.tmp';tmp.write_text(body,encoding='utf-8');os.replace(tmp,path)

def batch(inputs,out,styles=(0,1,2,3),size=(1280,720),ip='192.168.0.2',port=40000,bind_ip='192.168.0.3',interface_index=3,timeout=.25,attempts=5,job_timeout=60,job_retries=1,retry_wait=4,client_factory=ImageClient):
    if not inputs or not styles or len(set(styles))!=len(styles) or any(x not in range(4) for x in styles):raise ValueError('unique styles 0..3 and at least one input required')
    if not 0<=job_retries<=3 or not 3<=retry_wait<=60:raise ValueError('job retries 0..3; retry wait 3..60s')
    sources=[Path(x).resolve(strict=True)for x in inputs]
    # Validate every file before sending to the board.
    for source in sources:load_image(source,styles[0],size)
    root=Path(out).resolve();root.mkdir(parents=True,exist_ok=False)
    report=dict(status='RUNNING',started=datetime.datetime.now().astimezone().isoformat(),endpoint=[ip,port],bind_ip=bind_ip,interface_index=interface_index,size=list(size),styles=list(styles),network_job_pauses_live_inference=True,images=[],host_sources={p.name:sha(p)for p in Path(__file__).parent.glob('*.py')})
    def flush():atomic_json(root/'manifest.json',report);render_report(root,report)
    flush()
    try:
        for number,source in enumerate(sources,1):
            raw,base=load_image(source,styles[0],size)
            item=dict(source=str(source),source_sha256=sha(source),input_descriptor=asdict(base),input_png=f'{number:03d}_input.png',jobs=[]);report['images'].append(item);save_image(root/item['input_png'],raw,base);flush()
            for style in styles:
                d=replace(base,style=style);job=dict(style=style,status='RUNNING',attempts=[]);item['jobs'].append(job);flush()
                for attempt in range(job_retries+1):
                    client=None
                    try:
                        client=client_factory(ip,port,bind_ip,interface_index,timeout,attempts,job_timeout)
                        output,result=client.transfer(raw,d)
                    except (TransferError,OSError)as e:
                        job['attempts'].append(dict(status='FAIL',error=f'{type(e).__name__}: {e}',stats=dict(client.stats)if client is not None else {}));flush()
                        if attempt==job_retries:job.update(status='FAIL',error=str(e));flush()
                        else:time.sleep(retry_wait)
                        continue
                    finally:
                        if client is not None:client.close()
                    # Validation and disk failures must not silently run the model again.
                    if (result.width,result.height,result.style,result.format,result.stride,result.total)!=(d.width,d.height,d.style,1,d.width*3,d.width*d.height*3):raise ValueError('result dimensions/style/format mismatch')
                    filename=f'{number:03d}_slot{style}.png';save_image(root/filename,output,result)
                    job['attempts'].append(dict(status='PASS',stats=dict(client.stats)))
                    job.update(status='PASS',output_png=filename,output_sha256=sha(root/filename),pixel_crc32=f'{zlib.crc32(output):08x}',pixel_sha256=hashlib.sha256(output).hexdigest(),result_descriptor=asdict(result),stats=dict(client.stats));flush();break
                if job['status']=='RUNNING':raise RuntimeError('job did not reach terminal state')
        jobs=[j for i in report['images']for j in i['jobs']]
        report['status']='PASS'if all(j['status']=='PASS'for j in jobs)else'FAIL'
    except BaseException as e:
        terminal='INTERRUPTED'if isinstance(e,KeyboardInterrupt)else'FAIL'
        report.update(status=terminal,error=f'{type(e).__name__}: {e}')
        for item in report['images']:
            for job in item['jobs']:
                if job['status']=='RUNNING':job.update(status=terminal,error=report['error'])
        raise
    finally:
        report['finished']=datetime.datetime.now().astimezone().isoformat();flush()
    return root,report

def main():
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('inputs',nargs='+');ap.add_argument('--out',required=True);ap.add_argument('--styles',nargs='+',type=int,choices=range(4),default=[0,1,2,3]);ap.add_argument('--size',nargs=2,type=int,default=[1280,720]);ap.add_argument('--ip',default='192.168.0.2');ap.add_argument('--port',type=int,default=40000);ap.add_argument('--bind-ip',default='192.168.0.3');ap.add_argument('--interface-index',type=int,default=3);ap.add_argument('--job-retries',type=int,default=1);a=ap.parse_args()
    files=[]
    for arg in a.inputs:
        p=Path(arg)
        files.extend(sorted(x for x in p.iterdir()if x.suffix.lower()in ['.jpg','.jpeg','.png','.bmp','.webp'])if p.is_dir()else[p])
    root,r=batch(files,a.out,a.styles,tuple(a.size),a.ip,a.port,a.bind_ip,a.interface_index,job_retries=a.job_retries)
    print(r['status'],str(root/'comparison.html'));raise SystemExit(0 if r['status']=='PASS'else 1)
if __name__=='__main__':main()
