#include "ProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

struct qb_cancel { int pipefd[2]; atomic_bool signalled; };
static double clock_seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int make_pipe(int fds[2]) {
    if (pipe(fds)) return -1;
    for (int i = 0; i < 2; i++) {
        fcntl(fds[i], F_SETFD, FD_CLOEXEC);
        fcntl(fds[i], F_SETFL, O_NONBLOCK);
    }
    return 0;
}
qb_cancel *qb_cancel_create(void) {
    qb_cancel *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    if (make_pipe(c->pipefd)) { free(c); return NULL; }
    atomic_init(&c->signalled, 0);
    return c;
}
void qb_cancel_signal(qb_cancel *c) {
    if (c && !atomic_exchange(&c->signalled, 1)) {
        const char byte = 1; (void)write(c->pipefd[1], &byte, 1);
    }
}
void qb_cancel_destroy(qb_cancel *c) {
    if (!c) return;
    close(c->pipefd[0]); close(c->pipefd[1]); free(c);
}

int qb_run(const char *path, char *const argv[], char *const envp[], double timeout_seconds,
           qb_cancel *cancel, unsigned char *output, size_t capacity, size_t *output_count, int *exit_status) {
    *output_count = 0; *exit_status = -1;
    if (!cancel || timeout_seconds <= 0) return 1;
    if (atomic_load(&cancel->signalled)) return 3;
    int fds[2]; if (make_pipe(fds)) return 1;
    // Only our reader is nonblocking. A large writer must not see EAGAIN.
    fcntl(fds[1], F_SETFL, 0);
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;
    if (posix_spawn_file_actions_init(&actions)) { close(fds[0]); close(fds[1]); return 1; }
    if (posix_spawnattr_init(&attrs)) {
        posix_spawn_file_actions_destroy(&actions); close(fds[0]); close(fds[1]); return 1;
    }
    int setup = posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT);
    setup |= posix_spawnattr_setpgroup(&attrs, 0);
    setup |= posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    setup |= posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    setup |= posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    pid_t pid = -1;
    int spawned = setup ? setup : posix_spawn(&pid, path, &actions, &attrs, argv, envp);
    posix_spawnattr_destroy(&attrs); posix_spawn_file_actions_destroy(&actions); close(fds[1]);
    if (spawned) { close(fds[0]); return 1; }

    double deadline = clock_seconds() + timeout_seconds;
    int result = 0, status = 0, exited = 0, eof = 0;
    while (!(exited && eof)) {
        if (atomic_load(&cancel->signalled)) { result = 3; break; }
        double left = deadline - clock_seconds();
        if (left <= 0) { result = 2; break; }
        struct pollfd polls[2] = {{eof ? -1 : fds[0], POLLIN, 0}, {cancel->pipefd[0], POLLIN, 0}};
        int millis = (int)(left * 1000);
        if (eof && millis > 100) millis = 100;
        int ready = poll(polls, 2, millis > 0 ? millis : 1);
        if (ready < 0 && errno != EINTR) { result = 1; break; }
        if (polls[0].revents & (POLLIN | POLLHUP)) {
            unsigned char buffer[4096]; ssize_t count;
            while ((count = read(fds[0], buffer, sizeof(buffer))) > 0) {
                if ((size_t)count > capacity - *output_count) { result = 4; break; }
                for (ssize_t i = 0; i < count; i++) output[(*output_count)++] = buffer[i];
                // Continuously writing children must still obey cancellation and deadline.
                if (atomic_load(&cancel->signalled)) { result = 3; break; }
                if (clock_seconds() >= deadline) { result = 2; break; }
            }
            if (result) break;
            if (count == 0) eof = 1;
            else if (errno != EAGAIN && errno != EINTR) { result = 1; break; }
        }
        if (!exited) {
            pid_t waited = waitpid(pid, &status, WNOHANG);
            if (waited == pid) exited = 1;
            else if (waited < 0 && errno != EINTR) { result = 1; break; }
        }
    }
    // A fetch may not leave any helper children running, even after a successful parent exit.
    kill(-pid, SIGKILL);
    if (!exited) { while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {} }
    close(fds[0]);
    if (WIFEXITED(status)) *exit_status = WEXITSTATUS(status);
    return result;
}
