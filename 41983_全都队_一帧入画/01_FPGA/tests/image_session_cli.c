#include "image_backend_fixture.h"
/* Host-only line bridge for localhost protocol tests. No FPGA/NN emulation claim. */
int main(void){
 a_image_backend b=fixture_backend();a_image_session s;a_image_reply r;char line[4096],hex[2801];uint8_t payload[A_IMG_CHUNK];
 unsigned op,sid,seq,off,total,now,i,n,v;unsigned long long peer;
 a_image_session_init(&s,&b);setvbuf(stdout,0,_IOLBF,0);
 while(fgets(line,sizeof(line),stdin)){
  if(!strncmp(line,"STATS",5)){printf("stats %u %u %u %u\n",reserve_count,write_count,submit_count,release_count);continue;}
  if(sscanf(line,"%llu %u %u %u %u %u %u %2800s",&peer,&op,&sid,&seq,&off,&total,&now,hex)!=8)return 2;
  n=!strcmp(hex,"-")?0u:(unsigned)strlen(hex)/2u;if(n>A_IMG_CHUNK||op>255)return 3;
  for(i=0;i<n;i++){if(sscanf(hex+2*i,"%2x",&v)!=1)return 4;payload[i]=(uint8_t)v;}
  {a_image_packet p={(uint8_t)op,sid,seq,off,total,payload,(uint16_t)n};
   if(!a_image_session_process(&s,(uint64_t)peer,&p,now,&r))return 5;}
  printf("%u %u %u %u %u ",r.op,r.session,r.sequence,r.offset,r.total);
  if(!r.length)printf("-");else for(i=0;i<r.length;i++)printf("%02x",r.payload[i]);printf("\n");
 }
 return 0;
}
