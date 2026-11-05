#ifndef MACTERM_TELNET_PROTOCOL_H
#define MACTERM_TELNET_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
#define TN_NETWORK 0
#define TN_DISPLAY 1
typedef int (*tn_emit)(void *,int,const unsigned char *,size_t);
struct tn_state {
 unsigned char local[256],remote[256],parser,verb,sb[256];
 size_t sb_count;int sb_overflow,input_cr,output_cr,echo_cr,echo_mode;
 uint16_t columns,rows;char terminal[65];
};
void tn_init(struct tn_state *,const char *,int,uint16_t,uint16_t);
int tn_peer(struct tn_state *,const unsigned char *,size_t,tn_emit,void *);
int tn_input(struct tn_state *,const unsigned char *,size_t,tn_emit,void *);
int tn_finish_input(struct tn_state *,tn_emit,void *);
int tn_resize(struct tn_state *,uint16_t,uint16_t,tn_emit,void *);
#endif
