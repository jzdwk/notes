# master worker进程

记录master与worker进程的工作概述

## 进程启动

在[nginx-act-main](./nginx-act-main.md)中,main函数最终通过调用`ngx_master_process_cycle`完成master的启动，其函数实现视os的不同而定，这里以`unix`实现为例，代码位于`/src/os/unix/ngx_process_cycle.c`：
```c
void ngx_master_process_cycle(ngx_cycle_t *cycle){
    //如果接收到了信号集set中的信号则阻塞该信号的执行，
	//当前还处于启动过程中，因而需要阻塞这些信号的执行
    if (sigprocmask(SIG_BLOCK, &set, NULL) == -1) {
        ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_errno,
                      "sigprocmask() failed");
    }
	// 重置信号集
    sigemptyset(&set);
    size = sizeof(master_process);

    for (i = 0; i < ngx_argc; i++) {
        size += ngx_strlen(ngx_argv[i]) + 1;
    }

    title = ngx_pnalloc(cycle->pool, size);
    ...

    p = ngx_cpymem(title, master_process, sizeof(master_process) - 1);
    for (i = 0; i < ngx_argc; i++) {
        *p++ = ' ';
        p = ngx_cpystrn(p, (u_char *) ngx_argv[i], size);
    }
	//修改进程名，即master
    ngx_setproctitle(title);
	// 获取核心模块的配置
    ccf = (ngx_core_conf_t *) ngx_get_conf(cycle->conf_ctx, ngx_core_module);

	//通过nginx.conf中配置的worker_process数量，启动相应的worker进程
    ngx_start_worker_processes(cycle, ccf->worker_processes,
                               NGX_PROCESS_RESPAWN);
	//通过判断cycle确定是否开启cache manage进程
    ngx_start_cache_manager_processes(cycle, 0);

    ...
	
    for ( ;; ) {
		//...进入master进程的主循环
	}
}
```

## master进程

从上节中，可以看到master进程的主要工作位于`for循环`中，master进程将根据收到的信号量来决定具体的行为：
```c
    for ( ;; ) {
        ...

        ngx_log_debug0(NGX_LOG_DEBUG_EVENT, cycle->log, 0, "sigsuspend");

        sigsuspend(&set);

        ngx_time_update();

        ngx_log_debug1(NGX_LOG_DEBUG_EVENT, cycle->log, 0,
                       "wake up, sigio %i", sigio);
					   
		//1. 信号量ngx_reap: 有子进程意外结束
        if (ngx_reap) {
            ngx_reap = 0;
            ngx_log_debug0(NGX_LOG_DEBUG_EVENT, cycle->log, 0, "reap children");
			// 这里的操作主要分为三种情况：
			// 1. 关闭创建的每一个进程；
			// 2. 如果某个进程标记为了respawn，也即重新生成，那么就会重新创建一个进程以替代正在关闭的进程；
			// 3. 如果当前是平滑升级，则将旧的pid文件替换为新的pid文件；
			// 需要注意的是，这里的live表示当前是否还有进程是处于存活状态的 
            live = ngx_reap_children(cycle);
        }
		//2. 信号量ngx_terminate: 强制关闭
		//   信号量ngx_quit：优雅关闭
        if (!live && (ngx_terminate || ngx_quit)) {
            ngx_master_process_exit(cycle);
        }
		//
        if (ngx_terminate) {
            if (delay == 0) {
                delay = 50;
            }

            if (sigio) {
                sigio--;
                continue;
            }

            sigio = ccf->worker_processes + 2 /* cache processes */;

            if (delay > 1000) {
                ngx_signal_worker_processes(cycle, SIGKILL);
            } else {
                ngx_signal_worker_processes(cycle,
                                       ngx_signal_value(NGX_TERMINATE_SIGNAL));
            }

            continue;
        }

        if (ngx_quit) {
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_SHUTDOWN_SIGNAL));
            ngx_close_listening_sockets(cycle);

            continue;
        }

        if (ngx_reconfigure) {
            ngx_reconfigure = 0;

            if (ngx_new_binary) {
                ngx_start_worker_processes(cycle, ccf->worker_processes,
                                           NGX_PROCESS_RESPAWN);
                ngx_start_cache_manager_processes(cycle, 0);
                ngx_noaccepting = 0;

                continue;
            }

            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "reconfiguring");

            cycle = ngx_init_cycle(cycle);
            if (cycle == NULL) {
                cycle = (ngx_cycle_t *) ngx_cycle;
                continue;
            }

            ngx_cycle = cycle;
            ccf = (ngx_core_conf_t *) ngx_get_conf(cycle->conf_ctx,
                                                   ngx_core_module);
            ngx_start_worker_processes(cycle, ccf->worker_processes,
                                       NGX_PROCESS_JUST_RESPAWN);
            ngx_start_cache_manager_processes(cycle, 1);

            /* allow new processes to start */
            ngx_msleep(100);

            live = 1;
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_SHUTDOWN_SIGNAL));
        }

        if (ngx_restart) {
            ngx_restart = 0;
            ngx_start_worker_processes(cycle, ccf->worker_processes,
                                       NGX_PROCESS_RESPAWN);
            ngx_start_cache_manager_processes(cycle, 0);
            live = 1;
        }

        if (ngx_reopen) {
            ngx_reopen = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "reopening logs");
            ngx_reopen_files(cycle, ccf->user);
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_REOPEN_SIGNAL));
        }

        if (ngx_change_binary) {
            ngx_change_binary = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "changing binary");
            ngx_new_binary = ngx_exec_new_binary(cycle, ngx_argv);
        }

        if (ngx_noaccept) {
            ngx_noaccept = 0;
            ngx_noaccepting = 1;
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_SHUTDOWN_SIGNAL));
        }
    }
}

```

## worker进程