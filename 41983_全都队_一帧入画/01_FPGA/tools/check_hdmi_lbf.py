"""Read all actual CPU initialized bytes from final native Efinity LBF."""
from pathlib import Path
import os,hashlib,json,re,subprocess,argparse
P=Path(__file__).resolve().parents[1];E=Path(os.environ.get('EFINITY_HOME','D:/Efinity/2026.1'));os.environ['EFINITY_HOME']=E.as_posix()
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--lbf',type=Path,default=P/'work_pnr/ti60f225_oob.lbf')
lbf=parser.parse_args().lbf.resolve()
D=P/'integration_tests/hdmi_lbf_readback';D.mkdir(exist_ok=True)
data=bytearray(32768)
for i in range(4):
 cmd=[str(E/'bin/efx_bram_edit.exe'),'--family','Titanium','--project',str(P/'ti60f225_oob.xml'),'--mem_info',str(P/'outflow/ti60f225_oob.raminfo.pb'),'--place',str(P/'outflow/ti60f225_oob.place'),'--lbf',str(lbf),'--mode','read','--memory',f'u_c_soc/u_EfxSapphireSoc/system_ramA_logic/ram_symbol{i}']
 r=subprocess.run(cmd,cwd=P,capture_output=True,text=True,errors='replace');(D/f'lane{i}.log').write_text(r.stdout+r.stderr,encoding='utf-8')
 assert not r.returncode and 'ERROR' not in r.stdout+r.stderr
 m=re.search(r'\*\*\*\*\* Memory .*?\n([01]+)',r.stdout,re.S);assert m,'Missing initialized lane'
 bits=m[1];assert len(bits)==65536
 data[i::4]=bytes(int(bits[j:j+8][::-1],2) for j in range(0,len(bits),8))
binary=P/'embedded_sw/soc/software/standalone/uart/nnObserverDemo/build/nnObserverDemo.bin'
assert data==binary.read_bytes()+bytes(32768-binary.stat().st_size)
report={'status':'PASS','method':'Read-only extraction of actual native routed LBF in its native work directory','lbf_file':str(lbf),'ram_bytes':32768,'firmware_bytes':binary.stat().st_size,'firmware_sha256':sha(binary),'readback_padded_sha256':hashlib.sha256(data).hexdigest(),'lbf_sha256':sha(lbf)}
reference=P/'implementation_reference/ti60f225_oob.lbf'
if reference.exists():
 assert sha(reference)==sha(lbf),'Reference LBF differs from actual implementation'
 report['reference_lbf_sha256']=sha(reference)
(P/'HDMI_LBF_AUDIT.json').write_text(json.dumps(report,indent=2),encoding='utf-8');print(json.dumps(report,indent=2))
