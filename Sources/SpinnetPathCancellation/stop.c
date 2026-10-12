#include "SpinnetPathCancellation.h"
#include <signal.h>
#include <string.h>

static volatile sig_atomic_t stopped = 0;

static void record_stop(int signal_number) {
    (void)signal_number;
    stopped = 1;
}

int spinnet_path_install_stop_handlers(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = record_stop;
    sigemptyset(&action.sa_mask);
    /* Do not restart a blocking syscall; supervisor still owns hard deadline. */
    action.sa_flags = 0;
    return sigaction(SIGINT, &action, NULL) == 0 &&
           sigaction(SIGTERM, &action, NULL) == 0 ? 0 : -1;
}

int spinnet_path_stop_requested(void) { return stopped != 0; }
