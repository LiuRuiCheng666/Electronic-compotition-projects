import sys,unittest,tempfile,argparse,time,zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from a_video_transfer import *
class FakeClient:
    instances=[]
    def __init__(self,*args,**kwargs):
        self.stats={k:0 for k in ('sent','retransmissions','bad_datagrams','foreign_datagrams')};self.closed=False;self.n=0;self.instances.append(self)
    def close(self):self.closed=True
    def transfer(self,raw,desc):
        self.n+=1;self.stats.update(generation=self.n,sent=self.n*3,**{k:1 for k in ('upload_ms','task_wait_ms','download_ms','total_ms')})
        return raw,desc
class BrokenClient(FakeClient):
    def transfer(self,*args):raise RuntimeError('injected failure')
class VideoTests(unittest.TestCase):
    def test_latest_slot_is_bounded(self):
        slot=LatestFrame()
        for n in range(1000):slot.put(n)
        self.assertEqual(slot.take(),999);self.assertEqual(slot.dropped,999)
        slot.finish();self.assertIsNone(slot.take())
    def test_producer_error(self):
        slot=LatestFrame();slot.finish('decode failure')
        with self.assertRaisesRegex(RuntimeError,'decode failure'):slot.take()
    def test_bgr_conversion_and_padding(self):
        import numpy as np
        frame=np.zeros((10,10,3),dtype=np.uint8);frame[:]=(11,22,33)
        raw,d=prepare(frame,2);self.assertEqual(d.total,2764800)
        self.assertEqual(raw[:3],b'\xff\xff\xff');self.assertEqual(raw[(360*1280+640)*3:][:3],bytes((33,22,11)))
    def execute(self,factory=FakeClient,unicode_paths=False,style=3,preview_port=None):
        root=Path(self.tmp.name)/'中文目录' if unicode_paths else Path(self.tmp.name)
        root.mkdir(exist_ok=True);source=root/'输入.avi' if unicode_paths else root/'input.avi'
        import numpy as np
        writer=cv2.VideoWriter(str(source),cv2.VideoWriter_fourcc(*'MJPG'),10,(64,48))
        self.assertTrue(writer.isOpened())
        for n in range(10):writer.write(np.full((48,64,3),n*20,dtype=np.uint8))
        writer.release()
        self.assertTrue(source.is_file())
        a=argparse.Namespace(input=str(source),out=str(root/'out'),mode='sample',sample_seconds=.2,max_frames=3,style=style,preview_port=preview_port,ip='unused',bind_ip='unused',interface_index=None)
        return run(a,client_factory=factory)
    def setUp(self):self.tmp=tempfile.TemporaryDirectory()
    def tearDown(self):self.tmp.cleanup()
    def test_sample_end_to_end_local_fixture(self):
        r=self.execute();self.assertEqual(r['status'],'PASS');self.assertEqual([f['source_frame']for f in r['frames']],[0,2,4]);self.assertEqual(r['storyboard_frames'],3);self.assertTrue(FakeClient.instances[-1].closed)
    def test_unicode_paths_slot4_and_live_preview(self):
        r=self.execute(unicode_paths=True,style=4,preview_port=0)
        self.assertEqual(r['status'],'PASS');self.assertEqual(r['storyboard_frames'],3)
        self.assertTrue(all(f['result']['style']==4 for f in r['frames']))
        self.assertTrue((Path(self.tmp.name)/'中文目录/out/storyboard_1fps.avi').is_file())
    def test_unicode_png_keeps_bgr_channels(self):
        f=Path(self.tmp.name)/'中文帧.png';Image.new('RGB',(16,16),(12,34,56)).save(f)
        self.assertEqual(read_frame_image(f)[0,0].tolist(),[56,34,12])
    def test_five_style_descriptor_boundary(self):
        d=ImageDesc(1,1,1,4,3,3,0)
        self.assertEqual(ImageDesc.unpack(d.pack()),d)
        with self.assertRaises(ValueError):ImageDesc(1,1,1,5,3,3,0).validate()
    def test_failure_report_and_close(self):
        with self.assertRaisesRegex(RuntimeError,'injected failure'):self.execute(BrokenClient)
        r=json.loads((Path(self.tmp.name)/'out/video_report.json').read_text());self.assertEqual(r['status'],'FAIL');self.assertTrue(BrokenClient.instances[-1].closed)
if __name__=='__main__':unittest.main()
