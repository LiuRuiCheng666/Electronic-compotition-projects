from pathlib import Path
import json,copy,sys,unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from a_net_analyze import audit
class Tests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.original=json.loads((Path(__file__).parent/'data/stress20_reference.json').read_text())
 def test_recorded_stress_is_consistent(self):self.assertEqual(audit(self.original)['status'],'PASS')
 def test_short_run_cannot_be_hour_pass(self):self.assertEqual(audit(self.original,3600)['status'],'FAIL')
 def test_running_is_never_pass(self):
  d=copy.deepcopy(self.original);d['status']='RUNNING';self.assertEqual(audit(d,3600)['status'],'RUNNING')
 def test_changed_output_detected(self):
  d=copy.deepcopy(self.original);d['rounds'][4]['pixel_sha256']='0'*64;self.assertEqual(audit(d)['status'],'FAIL')
 def test_lost_generation_detected(self):
  d=copy.deepcopy(self.original);d['rounds'][4]['stats']['generation']+=1;self.assertEqual(audit(d)['status'],'FAIL')
 def test_failed_recovery_detected(self):
  d=copy.deepcopy(self.original);d['rounds'][4]['video']['NEW']=0;self.assertEqual(audit(d)['status'],'FAIL')
 def test_reboot_detected(self):
  d=copy.deepcopy(self.original);d['rounds'][4]['video']['uptime_ms']=1;self.assertEqual(audit(d)['status'],'FAIL')
 def test_reset_masking_is_not_accepted(self):
  d=copy.deepcopy(self.original);d['reset_or_mode_commands_sent']=True;self.assertEqual(audit(d)['status'],'FAIL')
 def test_current_five_style_log(self):
  d=copy.deepcopy(self.original);d['model_count']=5
  templates=copy.deepcopy(d['rounds'][:4])
  for i,row in enumerate(d['rounds']):
   slot=i%5;template=templates[slot%4];row['slot']=slot
   row['pixel_sha256']=template['pixel_sha256'];row['stats']['output_crc32']=template['stats']['output_crc32']
  result=audit(d);self.assertEqual(result['status'],'PASS');self.assertEqual(result['slots'],[0,1,2,3,4])
 def test_malformed_data_never_passes(self):
  for obj in [None,[],{'status':'PASS','rounds':'wrong'},dict(self.original,rounds=[None]),dict(self.original,elapsed_seconds='bad')]:
   with self.subTest(obj=type(obj).__name__):self.assertEqual(audit(obj)['status'],'FAIL')
if __name__=='__main__':unittest.main(verbosity=2)
