#include <signal.h>
#include <stdio.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static volatile sig_atomic_t child_exited;
static void exited(int signal_number) { (void)signal_number; child_exited=1; }
int main(int argc,char**argv) {
    if(argc!=2)return 10;
    sigset_t mask; if(sigprocmask(SIG_SETMASK,NULL,&mask)||sigismember(&mask,SIGCHLD))return 11;
    struct sigaction action={0};action.sa_handler=exited;sigemptyset(&action.sa_mask);
    if(sigaction(SIGCHLD,&action,NULL))return 12;
    pid_t child=fork();if(child<0)return 13;
    if(child==0){execl("/usr/bin/plutil","plutil","-extract","CFBundleShortVersionString","raw","-o","-",argv[1],NULL);_exit(14);}
    const struct timespec delay={0,10000000};
    for(int i=0;i<200&&!child_exited;++i)nanosleep(&delay,NULL);
    if(!child_exited){kill(child,SIGKILL);waitpid(child,NULL,0);return 15;}
    int status=0;if(waitpid(child,&status,0)!=child||status!=0)return 16;
    puts("SIGCHLD=unblocked child=done");return 0;
}
