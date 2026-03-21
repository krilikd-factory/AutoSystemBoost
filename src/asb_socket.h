#pragma once

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

#define ASB_SOCK_PATH   "/dev/.asb/ctl.sock"
#define ASB_SOCK_BUFLEN 512

static int asb_sock_create(void) {
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, ASB_SOCK_PATH, sizeof(addr.sun_path)-1);

    unlink(ASB_SOCK_PATH);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    chmod(ASB_SOCK_PATH, 0600);
    return fd;
}

static int asb_sock_recv(int fd, char *buf, int maxlen,
                         struct sockaddr_un *src, socklen_t *srclen)
{
    *srclen = sizeof(struct sockaddr_un);
    int n = recvfrom(fd, buf, maxlen-1, MSG_DONTWAIT,
                     (struct sockaddr *)src, srclen);
    if (n > 0) buf[n] = '\0';
    return n;
}

static void asb_sock_reply(int fd, const struct sockaddr_un *dst,
                           socklen_t dstlen, const char *msg)
{
    sendto(fd, msg, strlen(msg), MSG_DONTWAIT,
           (const struct sockaddr *)dst, dstlen);
}

static int asb_sock_send_cmd(const char *cmd, char *reply, int reply_len) {
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -1;

    struct sockaddr_un my_addr = {0};
    my_addr.sun_family = AF_UNIX;
    snprintf(my_addr.sun_path, sizeof(my_addr.sun_path),
             "/dev/.asb/client_%d.sock", getpid());
    unlink(my_addr.sun_path);
    bind(fd, (struct sockaddr *)&my_addr, sizeof(my_addr));

    struct sockaddr_un srv = {0};
    srv.sun_family = AF_UNIX;
    strncpy(srv.sun_path, ASB_SOCK_PATH, sizeof(srv.sun_path)-1);

    sendto(fd, cmd, strlen(cmd), 0,
           (const struct sockaddr *)&srv, sizeof(srv));

    if (reply && reply_len > 0) {
        struct timeval tv = {1, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        int n = recv(fd, reply, reply_len-1, 0);
        if (n > 0) reply[n] = '\0';
        else if (reply_len > 0) reply[0] = '\0';
    }
    unlink(my_addr.sun_path);
    close(fd);
    return 0;
}
