import sys,unittest,zlib,tempfile
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'host'))
from a_image_transfer import ImageDesc,ImageClient,TransferError,pack_rgbx7,save_image
class PackedTests(unittest.TestCase):
 def test_all_byte_values_and_zero_x(self):
  raw=bytes(range(256))*3;desc=ImageDesc(256,1,1,2,768,len(raw),zlib.crc32(raw));packed,p=pack_rgbx7(raw,desc)
  self.assertEqual(p.format,3);self.assertEqual(p.total,1024)
  for i in range(256):self.assertEqual(packed[i*4:i*4+4],bytes((raw[i*3]>>1,raw[i*3+1]>>1,raw[i*3+2]>>1,0)))
  self.assertEqual(p.crc32,zlib.crc32(packed))
 def test_old_firmware_fails_before_begin(self):
  raw=bytes([5,7,9]);d=ImageDesc(1,1,1,0,3,3,zlib.crc32(raw));raw,d=pack_rgbx7(raw,d)
  client=ImageClient('127.0.0.1',bind_ip='127.0.0.1');seen=[]
  def ack(p,*args):seen.append(p);return None,(0,0x8000,7,0)
  client._ack=ack
  try:
   with self.assertRaisesRegex(TransferError,'lacks packed'):client.transfer(raw,d)
  finally:client.close()
  self.assertEqual(len(seen),1);self.assertEqual(seen[0].payload,b'CAP1');self.assertNotIn('cancel_attempted',client.stats)
 def test_bad_source_crc_rejected(self):
  with self.assertRaises(ValueError):pack_rgbx7(bytes([0,1,2]),ImageDesc(1,1,1,0,3,3,0))
 def test_packed_preview_is_quantized_rgb8(self):
  from PIL import Image
  raw=bytes([19,87,255]);d=ImageDesc(1,1,1,0,3,3,zlib.crc32(raw));raw,d=pack_rgbx7(raw,d)
  with tempfile.TemporaryDirectory()as temp:
   p=Path(temp)/'in.png';save_image(p,raw,d)
   with Image.open(p)as im:self.assertEqual(im.getpixel((0,0)),(18,86,254))
if __name__=='__main__':unittest.main()
