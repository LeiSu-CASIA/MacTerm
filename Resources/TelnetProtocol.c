#include "TelnetProtocol.h"
#include <string.h>
enum {BINARY=0,ECHO=1,SGA=3,TTYPE=24,NAWS=31,SE=240,SB=250,WILL=251,WONT=252,DO=253,DONT=254,IAC=255};
static int emit_byte(tn_emit emit,void *context,int channel,unsigned char byte){return emit(context,channel,&byte,1);}
static int wire_byte(tn_emit emit,void *context,unsigned char byte){if(emit_byte(emit,context,TN_NETWORK,byte))return -1;return byte==IAC ? emit_byte(emit,context,TN_NETWORK,byte) : 0;}
static int command(tn_emit emit,void *context,unsigned char verb,unsigned char option){unsigned char data[]={IAC,verb,option};return emit(context,TN_NETWORK,data,sizeof(data));}
static int window_size(struct tn_state *state,tn_emit emit,void *context){
 unsigned char start[]={IAC,SB,NAWS},end[]={IAC,SE},data[]={state->columns>>8,state->columns&255,state->rows>>8,state->rows&255};
 if(emit(context,TN_NETWORK,start,sizeof(start)))return -1;
 for(size_t i=0;i<sizeof(data);i++)if(wire_byte(emit,context,data[i]))return -1;
 return emit(context,TN_NETWORK,end,sizeof(end));
}
void tn_init(struct tn_state *state,const char *terminal,int echo_mode,uint16_t columns,uint16_t rows){memset(state,0,sizeof(*state));strncpy(state->terminal,terminal,64);state->echo_mode=echo_mode;state->columns=columns;state->rows=rows;}
int tn_finish_input(struct tn_state *state,tn_emit emit,void *context){if(!state->output_cr)return 0;state->output_cr=0;return emit_byte(emit,context,TN_NETWORK,0);}
static int negotiate(struct tn_state *state,unsigned char verb,unsigned char option,tn_emit emit,void *context){
 // Only accept peer-initiated options. With no outstanding local requests there
 // are no WANT states; duplicate positive requests must not generate replies.
 if(verb==DO){
  if(option!=BINARY&&option!=SGA&&option!=TTYPE&&option!=NAWS)return command(emit,context,WONT,option);
  if(state->local[option])return 0;
  if(option==BINARY&&tn_finish_input(state,emit,context))return -1;
  state->local[option]=1;if(command(emit,context,WILL,option))return -1;
  return option==NAWS ? window_size(state,emit,context) : 0;
 }
 if(verb==DONT){if(!state->local[option])return 0;state->local[option]=0;return command(emit,context,WONT,option);}
 if(verb==WILL){
  if(option!=BINARY&&option!=ECHO&&option!=SGA)return command(emit,context,DONT,option);
  if(state->remote[option])return 0;state->remote[option]=1;return command(emit,context,DO,option);
 }
 if(!state->remote[option])return 0;state->remote[option]=0;return command(emit,context,DONT,option);
}
static int peer_data(struct tn_state *state,unsigned char byte,tn_emit emit,void *context){
 if(!state->remote[BINARY]&&state->input_cr&&byte==0){state->input_cr=0;return 0;}
 state->input_cr=!state->remote[BINARY]&&byte=='\r';return emit_byte(emit,context,TN_DISPLAY,byte);
}
static void sub_byte(struct tn_state *state,unsigned char byte){if(state->sb_count<sizeof(state->sb))state->sb[state->sb_count++]=byte;else state->sb_overflow=1;}
static int subnegotiation(struct tn_state *state,tn_emit emit,void *context){
 if(state->sb_overflow||state->sb_count!=2||state->sb[0]!=TTYPE||state->sb[1]!=1||!state->local[TTYPE])return 0;
 unsigned char start[]={IAC,SB,TTYPE,0},end[]={IAC,SE};if(emit(context,TN_NETWORK,start,sizeof(start)))return -1;
 for(size_t i=0;state->terminal[i];i++)if(wire_byte(emit,context,(unsigned char)state->terminal[i]))return -1;
 return emit(context,TN_NETWORK,end,sizeof(end));
}
int tn_peer(struct tn_state *state,const unsigned char *bytes,size_t count,tn_emit emit,void *context){
 for(size_t i=0;i<count;i++){unsigned char byte=bytes[i];switch(state->parser){
 case 0:if(byte==IAC)state->parser=1;else if(peer_data(state,byte,emit,context))return -1;break;
 case 1:
  if(byte==IAC){state->parser=0;if(peer_data(state,byte,emit,context))return -1;}
  else if(byte>=WILL&&byte<=DONT){state->verb=byte;state->parser=2;}
  else if(byte==SB){state->sb_count=0;state->sb_overflow=0;state->parser=3;}
  else state->parser=0;break;
 case 2:state->parser=0;if(negotiate(state,state->verb,byte,emit,context))return -1;break;
 case 3:if(byte==IAC)state->parser=4;else sub_byte(state,byte);break;
 case 4:
  if(byte==SE){state->parser=0;if(subnegotiation(state,emit,context))return -1;}
  else {if(byte==IAC)sub_byte(state,byte);else state->sb_overflow=1;state->parser=3;}break;
 default:return -1;
 }}return 0;
}
static int echo_input(struct tn_state *state,unsigned char byte,tn_emit emit,void *context){
 int enabled=state->echo_mode==1||(state->echo_mode==0&&!state->remote[ECHO]);
 if(!enabled){state->echo_cr=0;return 0;}
 if(byte=='\n'&&state->echo_cr){state->echo_cr=0;return 0;}
 state->echo_cr=byte=='\r';
 if(byte=='\r'||byte=='\n')return emit(context,TN_DISPLAY,(const unsigned char*)"\r\n",2);
 if(byte==8||byte==127)return emit(context,TN_DISPLAY,(const unsigned char*)"\b \b",3);
 if(byte<32&&byte!=9){unsigned char visible[]={'^',(unsigned char)(byte+64)};return emit(context,TN_DISPLAY,visible,sizeof(visible));}
 return emit_byte(emit,context,TN_DISPLAY,byte);
}
int tn_input(struct tn_state *state,const unsigned char *bytes,size_t count,tn_emit emit,void *context){
 for(size_t i=0;i<count;i++){unsigned char byte=bytes[i];if(echo_input(state,byte,emit,context))return -1;
  if(state->local[BINARY]){if(wire_byte(emit,context,byte))return -1;continue;}
  if(state->output_cr){state->output_cr=0;if(byte=='\n'){if(wire_byte(emit,context,byte))return -1;continue;}if(emit_byte(emit,context,TN_NETWORK,0))return -1;}
  if(byte=='\r'){if(wire_byte(emit,context,byte))return -1;state->output_cr=1;}
  else if(byte=='\n'){unsigned char newline[]={'\r','\n'};if(emit(context,TN_NETWORK,newline,sizeof(newline)))return -1;}
  else if(wire_byte(emit,context,byte))return -1;
 }return 0;
}
int tn_resize(struct tn_state *state,uint16_t columns,uint16_t rows,tn_emit emit,void *context){if(state->columns==columns&&state->rows==rows)return 0;state->columns=columns;state->rows=rows;return state->local[NAWS] ? window_size(state,emit,context) : 0;}
