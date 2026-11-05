#include "../Sources/TelnetProtocol.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
struct output {unsigned char net[8192],display[8192];size_t n,d;};
static int emit(void *context,int channel,const unsigned char *bytes,size_t count){struct output *out=context;assert(count<=8192-(channel==TN_NETWORK?out->n:out->d));if(channel==TN_NETWORK){memcpy(out->net+out->n,bytes,count);out->n+=count;}else{memcpy(out->display+out->d,bytes,count);out->d+=count;}return 0;}
static void peer(struct tn_state *state,struct output *out,const unsigned char *data,size_t count){for(size_t i=0;i<count;i++)assert(tn_peer(state,data+i,1,emit,out)==0);}
static int reject(void *context,int channel,const unsigned char *bytes,size_t count){(void)context;(void)channel;(void)bytes;(void)count;return -1;}
static int count_output(void *context,int channel,const unsigned char *bytes,size_t count){(void)channel;(void)bytes;assert(count<=512);*(size_t*)context+=count;return 0;}
int main(void){
 struct tn_state state;struct output out={0};tn_init(&state,"xterm-256color",0,255,511);
 const unsigned char enable[]={255,253,31},size[]={255,251,31,255,250,31,0,255,255,1,255,255,255,240};peer(&state,&out,enable,sizeof(enable));assert(out.n==sizeof(size)&&!memcmp(out.net,size,sizeof(size)));out.n=0;peer(&state,&out,enable,sizeof(enable));assert(out.n==0);
 const unsigned char disable[]={255,254,31},wont[]={255,252,31};peer(&state,&out,disable,sizeof(disable));assert(out.n==3&&!memcmp(out.net,wont,3));out.n=0;assert(tn_resize(&state,100,40,emit,&out)==0&&out.n==0);
 const unsigned char ttype[]={255,250,24,1,255,240},tt_enable[]={255,253,24},tt_reply[]={255,250,24,0,'x','t','e','r','m','-','2','5','6','c','o','l','o','r',255,240};peer(&state,&out,ttype,sizeof(ttype));assert(out.n==0);peer(&state,&out,tt_enable,sizeof(tt_enable));out.n=0;peer(&state,&out,ttype,sizeof(ttype));assert(out.n==sizeof(tt_reply)&&!memcmp(out.net,tt_reply,sizeof(tt_reply)));
 const unsigned char bad[]={255,253,42,255,251,43},bad_reply[]={255,252,42,255,254,43};out.n=0;peer(&state,&out,bad,sizeof(bad));assert(out.n==sizeof(bad_reply)&&!memcmp(out.net,bad_reply,sizeof(bad_reply)));
 out.n=out.d=0;const unsigned char nvt[]={'a','\r',255,241,0,'b','\r','\n',255,255},shown[]={'a','\r','b','\r','\n',255};peer(&state,&out,nvt,sizeof(nvt));assert(out.d==sizeof(shown)&&!memcmp(out.display,shown,sizeof(shown)));
 out.n=out.d=0;assert(tn_input(&state,(const unsigned char*)"x\r",2,emit,&out)==0);assert(tn_input(&state,(const unsigned char*)"\ny\r",3,emit,&out)==0);assert(tn_finish_input(&state,emit,&out)==0);assert(out.n==6&&!memcmp(out.net,"x\r\ny\r\0",6));assert(out.d==6&&!memcmp(out.display,"x\r\ny\r\n",6));
 out.n=out.d=0;const unsigned char echo[]={255,251,1};peer(&state,&out,echo,sizeof(echo));out.n=0;assert(tn_input(&state,(const unsigned char*)"secret",6,emit,&out)==0&&out.d==0&&out.n==6);peer(&state,&out,(const unsigned char[]){255,252,1},3);out.n=0;assert(tn_input(&state,(const unsigned char[]){8,3,127},3,emit,&out)==0);assert(out.d==8&&!memcmp(out.display,"\b \b^C\b \b",8));
 tn_init(&state,"vt100",2,80,24);out.n=out.d=0;peer(&state,&out,(const unsigned char[]){255,253,0,255,251,0},6);out.n=0;unsigned char all[256];for(int i=0;i<256;i++)all[i]=(unsigned char)i;assert(tn_input(&state,all,256,emit,&out)==0);assert(out.n==257&&out.d==0&&out.net[255]==255&&out.net[256]==255);out.d=0;peer(&state,&out,out.net,out.n);assert(out.d==256&&!memcmp(out.display,all,256));
 tn_init(&state,"vt100",0,80,24);out.n=out.d=0;peer(&state,&out,(const unsigned char[]){255,250,24,1},4);for(int i=0;i<1024;i++)peer(&state,&out,(const unsigned char*)"x",1);peer(&state,&out,(const unsigned char[]){255,240,'O','K'},4);assert(out.n==0&&out.d==2&&!memcmp(out.display,"OK",2));assert(tn_peer(&state,(const unsigned char*)"x",1,reject,NULL)==-1);assert(tn_input(&state,(const unsigned char*)"x",1,reject,NULL)==-1);
 uint32_t random=123456789;size_t emitted=0;tn_init(&state,"xterm-256color",0,80,24);for(int i=0;i<500000;i++){random=random*1664525u+1013904223u;unsigned char byte=(unsigned char)(random>>24);assert(tn_peer(&state,&byte,1,count_output,&emitted)==0);assert(tn_input(&state,&byte,1,count_output,&emitted)==0);if(i%256==0)assert(tn_peer(&state,(const unsigned char[]){255,240},2,count_output,&emitted)==0);}assert(emitted>0);
 puts("PASS: fragmented Telnet negotiation, duplicate suppression, NAWS IAC escaping and disable, terminal type, unsupported options, NVT CR/NUL, echo switching, binary 256-byte fidelity, bounded malformed subnegotiation and callback failures");return 0;
}
