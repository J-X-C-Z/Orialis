/* Test-only Linux LD_PRELOAD probe. Never used by the Agent or production.
 * Enables/disables TCP_NODELAY only when a received plaintext request identifies
 * the local Orialis Agent WebSocket upgrade. Logs only fd and socket options.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
static void inspect_ws(int fd, const void *buffer, ssize_t n) {
    if (n<=0 || !memmem(buffer,(size_t)n,"GET /api/v1/agent/ws ",21)) return;
    const char *setting=getenv("ORIALIS_TEST_WS_NODELAY");
    if (!setting) return;
    int saved=errno, before=-1, after=-1, value=atoi(setting);socklen_t size=sizeof(int);
    if (!getsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&before,&size)) {
        int status=setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&value,sizeof(value));
        getsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&after,&size);
        dprintf(STDERR_FILENO,"TEST_WS_NODELAY fd=%d before=%d requested=%d after=%d status=%d\n",fd,before,value,after,status);
    }
    errno=saved;
}
ssize_t read(int fd,void *buffer,size_t n) {
    ssize_t (*next)(int,void*,size_t)=dlsym(RTLD_NEXT,"read");
    ssize_t result=next(fd,buffer,n);inspect_ws(fd,buffer,result);return result;
}
ssize_t recv(int fd,void *buffer,size_t n,int flags) {
    ssize_t (*next)(int,void*,size_t,int)=dlsym(RTLD_NEXT,"recv");
    ssize_t result=next(fd,buffer,n,flags);inspect_ws(fd,buffer,result);return result;
}
ssize_t recvfrom(int fd,void *buffer,size_t n,int flags,struct sockaddr *address,socklen_t *length) {
    ssize_t (*next)(int,void*,size_t,int,struct sockaddr*,socklen_t*)=dlsym(RTLD_NEXT,"recvfrom");
    ssize_t result=next(fd,buffer,n,flags,address,length);inspect_ws(fd,buffer,result);return result;
}
ssize_t recvmsg(int fd,struct msghdr *message,int flags) {
    ssize_t (*next)(int,struct msghdr*,int)=dlsym(RTLD_NEXT,"recvmsg");
    ssize_t result=next(fd,message,flags);ssize_t remaining=result;
    for (size_t i=0;remaining>0 && i<message->msg_iovlen;i++) {
        size_t count=message->msg_iov[i].iov_len;
        if (count>(size_t)remaining) count=(size_t)remaining;
        inspect_ws(fd,message->msg_iov[i].iov_base,(ssize_t)count);remaining-=(ssize_t)count;
    }
    return result;
}
