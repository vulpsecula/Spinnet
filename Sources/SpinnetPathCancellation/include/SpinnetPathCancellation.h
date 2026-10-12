#ifndef SPINNET_PATH_CANCELLATION_H
#define SPINNET_PATH_CANCELLATION_H

/* Process-local Stop state; handler performs no allocation or system call. */
int spinnet_path_install_stop_handlers(void);
int spinnet_path_stop_requested(void);

#endif
