#include <util.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <stdlib.h>
#include <errno.h>
int terminal_spawn(const char *path, char *const argv[], int *child) {
 int master, slave; struct winsize size = {24, 80, 0, 0};
 if(openpty(&master, &slave, NULL, NULL, &size)) return -1;
 int maxfd=getdtablesize();
 pid_t pid=fork();
 if(pid<0){close(master);close(slave);return -1;}
 if(pid==0){ close(master); setsid(); ioctl(slave,TIOCSCTTY,0); dup2(slave,0);dup2(slave,1);dup2(slave,2);for(int f=3;f<maxfd;f++)close(f);const char *home=getenv("HOME");if(home)chdir(home);setenv("TERM","xterm-256color",1);setenv("LANG","en_US.UTF-8",1);execv(path,argv);_exit(127); }
 close(slave); *child=pid; return master;
}
void terminal_resize(int fd,int cols,int rows){struct winsize s={rows,cols,0,0};ioctl(fd,TIOCSWINSZ,&s);}
void terminal_stop(int pid){if(pid>0){kill(-pid,SIGHUP);kill(pid,SIGHUP);}}
int terminal_wait(int pid){int status;while(waitpid(pid,&status,0)<0){if(errno!=EINTR)return -1;}return WIFEXITED(status)?WEXITSTATUS(status):128+WTERMSIG(status);}
