#include "TelnetProtocol.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <termios.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static volatile sig_atomic_t stopping=0,resized=1;
static void stop_signal(int number){(void)number;stopping=1;}
static void resize_signal(int number){(void)number;resized=1;}
struct buffer {unsigned char bytes[65536];size_t count;};
struct raw_buffer {unsigned char bytes[8192];size_t count,position;};
struct channels {struct buffer network,display;int discard_network;};
static int emit(void *context,int channel,const unsigned char *bytes,size_t count){struct channels *channels=context;if(channel==TN_NETWORK&&channels->discard_network)return 0;struct buffer *buffer=channel==TN_NETWORK ? &channels->network : &channels->display;if(count>sizeof(buffer->bytes)-buffer->count)return -1;memcpy(buffer->bytes+buffer->count,bytes,count);buffer->count+=count;return 0;}
static int flush(int fd,struct buffer *buffer){ssize_t count=write(fd,buffer->bytes,buffer->count);if(count<0&&(errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR))return 0;if(count<=0)return -1;buffer->count-=(size_t)count;memmove(buffer->bytes,buffer->bytes+count,buffer->count);return 0;}
static double now(void){struct timespec time;clock_gettime(CLOCK_MONOTONIC,&time);return time.tv_sec+time.tv_nsec/1e9;}
struct resolver {const char *host,*service;struct addrinfo *addresses;int result,notify;};
static void *resolve(void *context){struct resolver *resolver=context;struct addrinfo hints={0};hints.ai_family=AF_UNSPEC;hints.ai_socktype=SOCK_STREAM;hints.ai_flags=AI_NUMERICSERV;resolver->result=getaddrinfo(resolver->host,resolver->service,&hints,&resolver->addresses);unsigned char done=1;while(write(resolver->notify,&done,1)<0&&errno==EINTR){};return NULL;}
static int connect_host(struct resolver *resolver,double deadline){
 for(struct addrinfo *address=resolver->addresses;address&&!stopping;address=address->ai_next){
  if(now()>=deadline){errno=ETIMEDOUT;return -1;}
  int fd=socket(address->ai_family,address->ai_socktype,address->ai_protocol);if(fd<0)continue;
  int flags=fcntl(fd,F_GETFL);if(flags<0||fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0||fcntl(fd,F_SETFD,FD_CLOEXEC)<0){close(fd);continue;}
  if(connect(fd,address->ai_addr,address->ai_addrlen)==0)return fd;
  if(errno!=EINPROGRESS){int failure=errno;close(fd);errno=failure;continue;}
  while(!stopping&&now()<deadline){struct pollfd descriptor={fd,POLLOUT,0};int result=poll(&descriptor,1,100);if(result<0&&errno==EINTR)continue;if(result<0)break;if(result==0)continue;int failure=0;socklen_t size=sizeof(failure);if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&failure,&size)<0)break;if(!failure)return fd;errno=failure;break;}
  int failure=now()>=deadline ? ETIMEDOUT : errno;close(fd);errno=failure;
 }return -1;
}
static int number(const char *text,int limit){char *end;errno=0;long value=strtol(text,&end,10);return !errno&&*text&&!*end&&value>0&&value<=limit ? (int)value : 0;}
int main(int argc,char **argv){
 if(argc!=6||!number(argv[2],65535)||!number(argv[3],600)||!strlen(argv[1])||strlen(argv[1])>255||!strlen(argv[4])||strlen(argv[4])>64||(strcmp(argv[5],"automatic")&&strcmp(argv[5],"on")&&strcmp(argv[5],"off"))){fprintf(stderr,"[Telnet] 无效连接参数\r\n");return 2;}
 for(size_t i=0;argv[1][i];i++)if((unsigned char)argv[1][i]<=32||(unsigned char)argv[1][i]==127){fprintf(stderr,"[Telnet] 主机名无效\r\n");return 2;}
 for(size_t i=0;argv[4][i];i++){unsigned char c=(unsigned char)argv[4][i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.')){fprintf(stderr,"[Telnet] 终端类型无效\r\n");return 2;}}
 struct sigaction action={0};action.sa_handler=stop_signal;sigemptyset(&action.sa_mask);sigaction(SIGHUP,&action,NULL);sigaction(SIGINT,&action,NULL);sigaction(SIGTERM,&action,NULL);action.sa_handler=resize_signal;sigaction(SIGWINCH,&action,NULL);signal(SIGPIPE,SIG_IGN);
 int result=0,fd=-1,local_raw=0,notify[2]={-1,-1},resolved=0;int input_flags=fcntl(STDIN_FILENO,F_GETFL),output_flags=fcntl(STDOUT_FILENO,F_GETFL);struct termios original;struct resolver resolver={argv[1],argv[2],NULL,0,-1};pthread_t resolver_thread;
 if(isatty(STDIN_FILENO)){if(tcgetattr(STDIN_FILENO,&original)<0){perror("[Telnet] terminal");return 1;}struct termios raw=original;cfmakeraw(&raw);if(tcsetattr(STDIN_FILENO,TCSANOW,&raw)<0)return 1;local_raw=1;}
 if(input_flags<0||output_flags<0||fcntl(STDIN_FILENO,F_SETFL,input_flags|O_NONBLOCK)<0||fcntl(STDOUT_FILENO,F_SETFL,output_flags|O_NONBLOCK)<0){result=1;goto cleanup;}
 fprintf(stderr,"[Telnet 连接中] %s:%s\r\n",argv[1],argv[2]);
 double deadline=now()+number(argv[3],600);
 if(pipe(notify)<0){result=1;goto cleanup;}fcntl(notify[0],F_SETFD,FD_CLOEXEC);fcntl(notify[1],F_SETFD,FD_CLOEXEC);resolver.notify=notify[1];
 if(pthread_create(&resolver_thread,NULL,resolve,&resolver)!=0){result=1;goto cleanup;}
 // The UI thread is a different process. The main relay can stop and restore
 // its terminal even when the system resolver is waiting; process exit ends
 // the resolver thread. Join it only after its completion notification.
 while(!stopping&&now()<deadline){struct pollfd descriptor={notify[0],POLLIN,0};int count=poll(&descriptor,1,100);if(count<0&&errno==EINTR)continue;if(count<0)break;if(descriptor.revents&POLLIN){pthread_join(resolver_thread,NULL);resolved=1;break;}}
 if(stopping)goto cleanup;
 if(!resolved){fprintf(stderr,"[Telnet 连接失败] 名称解析超时\r\n");result=1;goto cleanup;}
 if(resolver.result){fprintf(stderr,"[Telnet 连接失败] %s\r\n",gai_strerror(resolver.result));result=1;goto cleanup;}
 fd=connect_host(&resolver,deadline);if(stopping)goto cleanup;
 if(fd<0){fprintf(stderr,"[Telnet 连接失败] %s\r\n",strerror(errno));result=1;goto cleanup;}
 fprintf(stderr,"[Telnet 已连接] %s:%s · 明文 TCP\r\n",argv[1],argv[2]);
 struct tn_state state;struct winsize size={24,80,0,0};if(isatty(STDIN_FILENO)){struct winsize actual;if(ioctl(STDIN_FILENO,TIOCGWINSZ,&actual)==0&&actual.ws_col&&actual.ws_row)size=actual;}
 tn_init(&state,argv[4],!strcmp(argv[5],"on") ? 1 : !strcmp(argv[5],"off") ? 2 : 0,size.ws_col,size.ws_row);
 struct channels channels={0};struct raw_buffer incoming={0},input={0};int input_ended=0,peer_ended=0,peer_hangup=0,write_ended=0;
 while(!stopping){
  channels.discard_network=peer_hangup||peer_ended||write_ended;
  if(resized&&sizeof(channels.network.bytes)-channels.network.count>=32){resized=0;struct winsize actual;if(ioctl(STDIN_FILENO,TIOCGWINSZ,&actual)==0&&actual.ws_col&&actual.ws_row)if(tn_resize(&state,actual.ws_col,actual.ws_row,emit,&channels)){result=1;break;}}
  while(incoming.position<incoming.count&&sizeof(channels.network.bytes)-channels.network.count>=512&&sizeof(channels.display.bytes)-channels.display.count>=8){if(tn_peer(&state,incoming.bytes+incoming.position,1,emit,&channels)){result=1;goto cleanup;}incoming.position++;}
  if(incoming.position==incoming.count)incoming.position=incoming.count=0;
  int echo=state.echo_mode==1||(state.echo_mode==0&&!state.remote[1]);
  while(!peer_hangup&&!peer_ended&&input.position<input.count&&sizeof(channels.network.bytes)-channels.network.count>=8&&(!echo||sizeof(channels.display.bytes)-channels.display.count>=8)){if(tn_input(&state,input.bytes+input.position,1,emit,&channels)){result=1;goto cleanup;}input.position++;}
  if(input.position==input.count)input.position=input.count=0;
  if(peer_ended&&!incoming.count&&!channels.display.count)break;
  if(input_ended&&!input.count&&!write_ended&&sizeof(channels.network.bytes)-channels.network.count>=8){if(tn_finish_input(&state,emit,&channels)){result=1;break;}if(!channels.network.count){shutdown(fd,SHUT_WR);write_ended=1;}}
  struct pollfd descriptors[3]={{!input_ended&&!peer_hangup&&!peer_ended&&!input.count ? STDIN_FILENO : -1,POLLIN,0},{-1,0,0},{channels.display.count ? STDOUT_FILENO : -1,POLLOUT,0}};
  if(!peer_ended&&(!incoming.count||(!peer_hangup&&channels.network.count))){descriptors[1].fd=fd;if(!incoming.count)descriptors[1].events|=POLLIN;if(!peer_hangup&&channels.network.count)descriptors[1].events|=POLLOUT;}
  int count=poll(descriptors,3,100);if(count<0){if(errno==EINTR)continue;result=1;break;}
  if(descriptors[2].revents&(POLLERR|POLLHUP|POLLNVAL)){result=1;break;}
  if((descriptors[2].revents&POLLOUT)&&flush(STDOUT_FILENO,&channels.display)<0){result=1;break;}
  if(descriptors[1].revents&(POLLERR|POLLHUP|POLLNVAL)){peer_hangup=1;channels.network.count=0;input.count=input.position=0;}
  if(!incoming.count&&(descriptors[1].revents&(POLLIN|POLLERR|POLLHUP|POLLNVAL))){ssize_t n=read(fd,incoming.bytes,sizeof(incoming.bytes));if(n>0)incoming.count=(size_t)n;else if(n==0){peer_ended=1;channels.network.count=0;}else if(errno!=EINTR&&errno!=EAGAIN&&errno!=EWOULDBLOCK){peer_ended=1;channels.network.count=0;result=1;}}
  if(!peer_hangup&&!peer_ended&&(descriptors[1].revents&POLLOUT)&&channels.network.count&&flush(fd,&channels.network)<0){peer_ended=1;channels.network.count=0;result=1;}
  if(descriptors[0].revents&(POLLIN|POLLHUP|POLLERR|POLLNVAL)){ssize_t n=read(STDIN_FILENO,input.bytes,sizeof(input.bytes));if(n>0)input.count=(size_t)n;else if(n==0)input_ended=1;else if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)input_ended=1;}
 }
cleanup:
 if(fd>=0)close(fd);if(resolved&&resolver.addresses)freeaddrinfo(resolver.addresses);
 if(notify[0]>=0)close(notify[0]);if(notify[1]>=0)close(notify[1]);
 if(local_raw)tcsetattr(STDIN_FILENO,TCSANOW,&original);if(output_flags>=0)fcntl(STDOUT_FILENO,F_SETFL,output_flags);if(input_flags>=0)fcntl(STDIN_FILENO,F_SETFL,input_flags);
 return result;
}
