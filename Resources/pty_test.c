#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <poll.h>
#include <assert.h>
int terminal_spawn(const char*,char*const[],int*);
void terminal_resize(int,int,int);
int terminal_wait(int);
int main(void){int pid;char *args[]={"/bin/sh","-c","printf 'PTY_READY\\n'; read value; printf 'RESULT:%s\\n' \"$value\"; stty size",NULL};int fd=terminal_spawn(args[0],args,&pid);assert(fd>=0);terminal_resize(fd,100,35);char buffer[8192]={0};int used=0;write(fd,"hello-中文\n",13);while(used<sizeof(buffer)-1){struct pollfd p={fd,POLLIN,0};if(poll(&p,1,3000)<=0)break;int n=read(fd,buffer+used,sizeof(buffer)-1-used);if(n<=0)break;used+=n;}close(fd);assert(terminal_wait(pid)==0);assert(strstr(buffer,"PTY_READY"));assert(strstr(buffer,"RESULT:hello-中文"));assert(strstr(buffer,"35 100"));puts("PTY tests passed: interactive input, UTF-8, resize, exit status");}
