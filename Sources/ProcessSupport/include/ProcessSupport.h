#ifndef QUOTA_PROCESS_SUPPORT_H
#define QUOTA_PROCESS_SUPPORT_H
#include <stddef.h>
typedef struct qb_cancel qb_cancel;
qb_cancel *qb_cancel_create(void);
void qb_cancel_signal(qb_cancel *cancel);
void qb_cancel_destroy(qb_cancel *cancel);
// 0: success, 1: spawn/IO failure, 2: timeout, 3: cancelled, 4: output too large.
int qb_run(const char *path, char *const argv[], char *const envp[],
           double timeout_seconds, qb_cancel *cancel,
           unsigned char *output, size_t capacity, size_t *output_count, int *exit_status);
#endif
