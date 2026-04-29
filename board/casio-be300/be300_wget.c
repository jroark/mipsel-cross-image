#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

static void usage(void)
{
    fprintf(stderr, "usage: wget [-T seconds] [-O file] URL\n");
}

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;

    while (len > 0) {
        ssize_t n = write(fd, p, len);

        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (n == 0)
            return -1;
        p += n;
        len -= n;
    }

    return 0;
}

static int header_end_offset(const char *buf, size_t len)
{
    size_t i;

    for (i = 0; i + 1 < len; i++) {
        if (buf[i] == '\n' && buf[i + 1] == '\n')
            return (int)i + 2;
        if (i + 3 < len && buf[i] == '\r' && buf[i + 1] == '\n' &&
            buf[i + 2] == '\r' && buf[i + 3] == '\n')
            return (int)i + 4;
    }

    return -1;
}

static int parse_url(const char *url, char *host, size_t host_len,
                     char *port, size_t port_len, char *path,
                     size_t path_len)
{
    const char *p = url;
    const char *slash;
    const char *colon;
    size_t len;

    if (strncmp(p, "http://", 7) == 0) {
        p += 7;
    } else if (strstr(p, "://") != NULL) {
        fprintf(stderr, "wget: only http:// URLs are supported\n");
        return -1;
    }

    slash = strchr(p, '/');
    len = slash ? (size_t)(slash - p) : strlen(p);
    if (len == 0 || len >= host_len)
        return -1;

    colon = memchr(p, ':', len);
    if (colon != NULL) {
        size_t hlen = (size_t)(colon - p);
        size_t plen = len - hlen - 1;

        if (hlen == 0 || hlen >= host_len || plen == 0 || plen >= port_len)
            return -1;
        memcpy(host, p, hlen);
        host[hlen] = '\0';
        memcpy(port, colon + 1, plen);
        port[plen] = '\0';
    } else {
        memcpy(host, p, len);
        host[len] = '\0';
        snprintf(port, port_len, "80");
    }

    if (slash != NULL) {
        if (strlen(slash) >= path_len)
            return -1;
        strcpy(path, slash);
    } else {
        snprintf(path, path_len, "/");
    }

    return 0;
}

static int connect_http(const char *host, const char *port, int timeout)
{
    struct addrinfo hints;
    struct addrinfo *res = NULL;
    struct addrinfo *ai;
    struct timeval tv;
    int fd = -1;
    int err;

    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    err = getaddrinfo(host, port, &hints, &res);
    if (err != 0) {
        fprintf(stderr, "wget: DNS failed for %s: %s\n", host,
                gai_strerror(err));
        return -1;
    }

    tv.tv_sec = timeout;
    tv.tv_usec = 0;
    for (ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0)
            continue;

        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0)
            break;

        close(fd);
        fd = -1;
    }

    freeaddrinfo(res);
    if (fd < 0)
        fprintf(stderr, "wget: connect to %s:%s failed\n", host, port);

    return fd;
}

int main(int argc, char **argv)
{
    char host[256];
    char port[16];
    char path[1024];
    char request[1536];
    char header[8192];
    const char *outfile = NULL;
    const char *url = NULL;
    int timeout = 30;
    int fd = -1;
    int outfd = -1;
    int status = 0;
    int saw_header = 0;
    size_t header_len = 0;
    size_t body_bytes = 0;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-O") == 0) {
            if (++i >= argc) {
                usage();
                return 2;
            }
            outfile = argv[i];
        } else if (strcmp(argv[i], "-T") == 0) {
            if (++i >= argc) {
                usage();
                return 2;
            }
            timeout = atoi(argv[i]);
            if (timeout <= 0)
                timeout = 30;
        } else if (argv[i][0] == '-') {
            usage();
            return 2;
        } else {
            url = argv[i];
        }
    }

    if (url == NULL) {
        usage();
        return 2;
    }

    if (parse_url(url, host, sizeof(host), port, sizeof(port), path,
                  sizeof(path)) != 0) {
        fprintf(stderr, "wget: bad URL: %s\n", url);
        return 2;
    }

    fd = connect_http(host, port, timeout);
    if (fd < 0)
        return 1;

    if (snprintf(request, sizeof(request),
                 "GET %s HTTP/1.0\r\n"
                 "Host: %s\r\n"
                 "User-Agent: be300-wget/1.0\r\n"
                 "Connection: close\r\n"
                 "\r\n",
                 path, host) >= (int)sizeof(request)) {
        fprintf(stderr, "wget: request too large\n");
        close(fd);
        return 2;
    }

    if (outfile == NULL || strcmp(outfile, "-") == 0) {
        outfd = STDOUT_FILENO;
    } else {
        outfd = open(outfile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (outfd < 0) {
            perror("wget: open output");
            close(fd);
            return 1;
        }
    }

    if (write_all(fd, request, strlen(request)) != 0) {
        perror("wget: write request");
        if (outfd != STDOUT_FILENO)
            close(outfd);
        close(fd);
        return 1;
    }

    for (;;) {
        char buf[1024];
        ssize_t n = read(fd, buf, sizeof(buf));

        if (n < 0) {
            if (errno == EINTR)
                continue;
            perror("wget: read response");
            break;
        }
        if (n == 0)
            break;

        if (!saw_header) {
            int off;

            if (header_len + (size_t)n > sizeof(header)) {
                fprintf(stderr, "wget: response header too large\n");
                break;
            }
            memcpy(header + header_len, buf, (size_t)n);
            header_len += (size_t)n;

            off = header_end_offset(header, header_len);
            if (off < 0)
                continue;

            header[header_len < sizeof(header) ? header_len : sizeof(header) - 1] = '\0';
            if (sscanf(header, "HTTP/%*s %d", &status) != 1)
                status = 0;
            saw_header = 1;

            if (header_len > (size_t)off) {
                size_t body_len = header_len - (size_t)off;

                if (write_all(outfd, header + off, body_len) != 0) {
                    perror("wget: write output");
                    break;
                }
                body_bytes += body_len;
            }
        } else {
            if (write_all(outfd, buf, (size_t)n) != 0) {
                perror("wget: write output");
                break;
            }
            body_bytes += (size_t)n;
        }
    }

    if (outfd != STDOUT_FILENO)
        close(outfd);
    close(fd);

    if (!saw_header) {
        fprintf(stderr, "wget: no HTTP response\n");
        return 1;
    }
    if (status < 200 || status >= 400) {
        fprintf(stderr, "wget: HTTP status %d\n", status);
        return 1;
    }
    if (body_bytes == 0)
        fprintf(stderr, "wget: warning: empty response body\n");

    return 0;
}
