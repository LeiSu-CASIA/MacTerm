#include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/file.h>
#include <termios.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static volatile sig_atomic_t stopping=0;
static void stop_signal(int signal_number){(void)signal_number;stopping=1;}
struct buffer {unsigned char bytes[65536];size_t count;};
static int write_buffer(int fd,struct buffer *buffer){ssize_t count=write(fd,buffer->bytes,buffer->count);if(count<0 && (errno==EAGAIN||errno==EWOULDBLOCK||errno==EINTR))return 0;if(count<=0)return -1;buffer->count-=(size_t)count;memmove(buffer->bytes,buffer->bytes+count,buffer->count);return 0;}
static speed_t baud_value(const char *text){
 static const long rates[]={300,600,1200,2400,4800,9600,19200,38400,57600,115200,230400};
 static const speed_t speeds[]={B300,B600,B1200,B2400,B4800,B9600,B19200,B38400,B57600,B115200,B230400};
 char *end;long value=strtol(text,&end,10);if(*end)return 0;for(size_t i=0;i<sizeof(rates)/sizeof(rates[0]);i++)if(value==rates[i])return speeds[i];return 0;
}
static int serial_path(const char *path){if(strncmp(path,"/dev/",5)||strchr(path+5,'/'))return 0;const char *name=path+5;if(!strncmp(name,"cu.",3)||!strncmp(name,"tty.",4))return 1;if(strncmp(name,"ttys",4))return 0;size_t n=strlen(name+4);if(n<3)return 0;for(size_t i=4;name[i];i++)if(name[i]<'0'||name[i]>'9')return 0;return 1;}
int main(int argc,char **argv){
 if(argc!=7||!serial_path(argv[1])){fprintf(stderr,"[串口] 无效参数或设备路径\r\n");return 2;}
 speed_t baud=baud_value(argv[2]);int bits=atoi(argv[3]),stops=atoi(argv[5]);const char *parity=argv[4],*flow=argv[6];
 if(!baud||strlen(argv[3])!=1||bits<5||bits>8||strlen(argv[5])!=1||(stops!=1&&stops!=2)||(strcmp(parity,"none")&&strcmp(parity,"even")&&strcmp(parity,"odd"))||(strcmp(flow,"none")&&strcmp(flow,"hardware")&&strcmp(flow,"software"))){fprintf(stderr,"[串口] 不支持的通信参数\r\n");return 2;}
 struct sigaction action={0};action.sa_handler=stop_signal;sigemptyset(&action.sa_mask);sigaction(SIGHUP,&action,NULL);sigaction(SIGTERM,&action,NULL);sigaction(SIGINT,&action,NULL);signal(SIGPIPE,SIG_IGN);
 int device=-1,result=0,exclusive=0,configured=0,local_raw=0;struct termios original,local_original;
 for(int attempt=0;attempt<11&&!stopping;attempt++){
  device=open(argv[1],O_RDWR|O_NOCTTY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC);
  if(device>=0){
   struct stat info;if(fstat(device,&info)<0||!S_ISCHR(info.st_mode)){fprintf(stderr,"[串口] 目标不是字符设备\r\n");close(device);return 1;}
   if(flock(device,LOCK_EX|LOCK_NB)==0&&ioctl(device,TIOCEXCL)==0){exclusive=1;break;}
   int failure=errno;close(device);device=-1;errno=failure;
  }
  if(errno!=EBUSY&&errno!=EWOULDBLOCK)break;
  if(attempt<10){struct timespec pause={0,100000000};nanosleep(&pause,NULL);}
 }
 if(stopping){if(device>=0){if(exclusive)ioctl(device,TIOCNXCL);close(device);}return 0;}
 if(device<0){fprintf(stderr,"[串口连接失败] %s：%s%s\r\n",argv[1],errno==EBUSY||errno==EWOULDBLOCK ? "设备被占用，" : "",strerror(errno));return 1;}
 if(tcgetattr(device,&original)<0){fprintf(stderr,"[串口] 不能读取设备设置：%s\r\n",strerror(errno));result=1;goto cleanup;}
 struct termios settings=original;cfmakeraw(&settings);settings.c_cflag|=CLOCAL|CREAD;settings.c_cflag&=~(CSIZE|PARENB|PARODD|CSTOPB|CRTSCTS);
 settings.c_cflag|=bits==5?CS5:bits==6?CS6:bits==7?CS7:CS8;
 if(strcmp(parity,"none")){settings.c_cflag|=PARENB;if(!strcmp(parity,"odd"))settings.c_cflag|=PARODD;settings.c_iflag|=INPCK;}
 if(stops==2)settings.c_cflag|=CSTOPB;
 settings.c_iflag&=~(IXON|IXOFF|IXANY);if(!strcmp(flow,"hardware"))settings.c_cflag|=CRTSCTS;else if(!strcmp(flow,"software"))settings.c_iflag|=IXON|IXOFF;
 settings.c_cc[VMIN]=1;settings.c_cc[VTIME]=0;
 configured=1;
 if(cfsetispeed(&settings,baud)<0||cfsetospeed(&settings,baud)<0||tcsetattr(device,TCSANOW,&settings)<0){fprintf(stderr,"[串口] 设备拒绝通信参数：%s\r\n",strerror(errno));result=1;goto cleanup;}tcflow(device,TCOON);
 struct termios applied;tcflag_t mask=CSIZE|PARENB|PARODD|CSTOPB|CRTSCTS;
 if(tcgetattr(device,&applied)<0||cfgetispeed(&applied)!=baud||cfgetospeed(&applied)!=baud||(applied.c_cflag&mask)!=(settings.c_cflag&mask)||(applied.c_iflag&(IXON|IXOFF))!=(settings.c_iflag&(IXON|IXOFF))){fprintf(stderr,"[串口] 设备未接受所请求的通信参数\r\n");result=1;goto cleanup;}
 if(isatty(STDIN_FILENO)&&tcgetattr(STDIN_FILENO,&local_original)==0){struct termios raw=local_original;cfmakeraw(&raw);if(tcsetattr(STDIN_FILENO,TCSANOW,&raw)<0){result=1;goto cleanup;}local_raw=1;}
 int out_flags=fcntl(STDOUT_FILENO,F_GETFL);if(out_flags<0||fcntl(STDOUT_FILENO,F_SETFL,out_flags|O_NONBLOCK)<0){result=1;goto cleanup;}
 fprintf(stderr,"[串口已连接] %s · %s baud · %d%s%d · %s\r\n",argv[1],argv[2],bits,!strcmp(parity,"none")?"N":!strcmp(parity,"even")?"E":"O",stops,flow);
 struct buffer to_device={0},to_output={0};int input_ended=0,device_ended=0,device_hangup=0;
 while(!stopping){
  if(device_ended&&to_output.count==0){result=1;break;}if(input_ended&&to_device.count==0&&to_output.count==0)break;
  struct pollfd descriptors[3]={{!input_ended&&!device_ended&&!device_hangup&&to_device.count<sizeof(to_device.bytes)?STDIN_FILENO:-1,POLLIN,0},{!device_ended&&(to_output.count<sizeof(to_output.bytes)||(!device_hangup&&to_device.count))?device:-1,0,0},{to_output.count?STDOUT_FILENO:-1,POLLOUT,0}};
  if(to_output.count<sizeof(to_output.bytes))descriptors[1].events|=POLLIN;if(to_device.count)descriptors[1].events|=POLLOUT;
  int count=poll(descriptors,3,-1);if(count<0){if(errno==EINTR)continue;result=1;break;}
  if(descriptors[2].revents&(POLLERR|POLLHUP|POLLNVAL)){result=1;break;}
  if((descriptors[2].revents&POLLOUT)&&write_buffer(STDOUT_FILENO,&to_output)<0){result=1;break;}
  if(descriptors[0].revents&(POLLIN|POLLHUP)){ssize_t n=read(STDIN_FILENO,to_device.bytes+to_device.count,sizeof(to_device.bytes)-to_device.count);if(n>0)to_device.count+=(size_t)n;else if(n==0)input_ended=1;else if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR){input_ended=1;}}
  if(descriptors[0].revents&(POLLERR|POLLNVAL))input_ended=1;
  if(descriptors[1].revents&(POLLHUP|POLLERR|POLLNVAL)){device_hangup=1;to_device.count=0;}
  if(to_output.count<sizeof(to_output.bytes)&&(descriptors[1].revents&(POLLIN|POLLHUP|POLLERR|POLLNVAL))){ssize_t n=read(device,to_output.bytes+to_output.count,sizeof(to_output.bytes)-to_output.count);if(n>0)to_output.count+=(size_t)n;else if(n==0||(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)||(device_hangup&&errno!=EINTR)){device_ended=1;to_device.count=0;}}
  if(!device_ended&&!device_hangup&&(descriptors[1].revents&POLLOUT)&&to_device.count&&write_buffer(device,&to_device)<0){device_ended=1;to_device.count=0;}
 }
 if(device_ended)fprintf(stderr,"\r\n[串口已断开] 设备连接中断\r\n");
 if(out_flags>=0)fcntl(STDOUT_FILENO,F_SETFL,out_flags);
cleanup:
 if(local_raw)tcsetattr(STDIN_FILENO,TCSANOW,&local_original);
 if(configured){tcflush(device,TCIOFLUSH);tcflow(device,TCOON);tcsetattr(device,TCSANOW,&original);}
 if(exclusive)ioctl(device,TIOCNXCL);
 close(device);return result;
}
