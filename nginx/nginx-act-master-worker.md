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

master进程的主要作用就是管理子进程。从上节中，可以看到master进程的主要工作包括了启动worker与维护worker。其中启动worker的实现在函数`ngx_start_worker_processes`，维护worker位于`for循环`中，master进程将根据收到的信号量来决定具体的行为。

1. **启动worker**

函数`ngx_start_worker_processes`的实现如下：

```c
//n = 要启动的进程数，type = NGX_PROCESS_RESPAWN
static void
ngx_start_worker_processes(ngx_cycle_t *cycle, ngx_int_t n, ngx_int_t type)
{
    ngx_int_t  i;

    ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "start worker processes");

    for (i = 0; i < n; i++) {
		//该函数将执行系统调用fork
		//重点为ngx_worker_process_cycle函数指针，该函数即worker进程的主循环
        ngx_spawn_process(cycle, ngx_worker_process_cycle,
                          (void *) (intptr_t) i, "worker process", type);

        ngx_pass_open_channel(cycle);
    }
}
```
以上重点关注2点，一是`ngx_worker_process_cycle`即worker进程的主循环：
```c
static void ngx_worker_process_cycle(ngx_cycle_t *cycle, void *data);
```
二是`ngx_spawn_process`将fork出子进程：
```c
ngx_pid_t
ngx_spawn_process(ngx_cycle_t *cycle, ngx_spawn_proc_pt proc, void *data,
    char *name, ngx_int_t respawn)
{
    ...
    pid = fork();

    switch (pid) {
    ...
    case 0:
        ngx_parent = ngx_pid;
        ngx_pid = ngx_getpid();
        proc(cycle, data);
        break;

    default:
        break;
    }
    ...
    return pid;
}

```

2. **维护worker**

master维护worker的工作位于for循环中，并通过接收到的信号量来执行具体操作。`ngx_single_handler`将收到的信号量设置到全局变量中，即`ngx_reap,ngx_terminate`等，master的整体工作流程以及与信号量的关系如下：
```c
	//master并非一直在循环，会通过sigsuspend进入休眠，当收到信号后才继续
    for ( ;; ) {
        ...

        ngx_log_debug0(NGX_LOG_DEBUG_EVENT, cycle->log, 0, "sigsuspend");

        sigsuspend(&set);

        ngx_time_update();

        ngx_log_debug1(NGX_LOG_DEBUG_EVENT, cycle->log, 0,
                       "wake up, sigio %i", sigio);
					   
		//【信号CHLD】->ngx_reap: 有子进程意外结束
		// 【1】 为1，监控所有的子进程
        if (ngx_reap) {
            ngx_reap = 0;
            ngx_log_debug0(NGX_LOG_DEBUG_EVENT, cycle->log, 0, "reap children");
			// 如果所有子进程都结束，则为0，否则为1
            live = ngx_reap_children(cycle);
        }
		//【2】当live=0且收到终止信号，退出master
        if (!live && (ngx_terminate || ngx_quit)) {
			//【3】删除存储master pid的文件
			//【4】调用所有模块exit_master方法
			//【5】关闭所有监听端口，销毁内存池
            ngx_master_process_exit(cycle);
        }
		
		//【信号TERM/INT】->ngx_terminate: 强制关闭
		//【6】为1，向所有子进程发送TERM信号
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
		//【信号QUIT】->ngx_quit：优雅关闭
		//【7】为1，向所有子进程发送QUIT信号
        if (ngx_quit) {
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_SHUTDOWN_SIGNAL));
			//【8】关闭所有监听端口
			ngx_close_listening_sockets(cycle);

            continue;
        }
		//【信号HUP】->ngx_reconfigure: 重新读取配置文件nginx.conf并使其生效
		//【9】为1，重新读取配置文件
		// nginx的做法是重新初始化ngx_cycle_t结构体来读取conf。
		// 进而再拉起新的worker，并销毁旧的worker
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
            //【10】根据新的cycle，启动新的worker子进程
			ngx_start_worker_processes(cycle, ccf->worker_processes,
                                       NGX_PROCESS_JUST_RESPAWN);
			//【11】启动cache_manager子进程
            ngx_start_cache_manager_processes(cycle, 1);

            /* allow new processes to start */
            ngx_msleep(100);
			//【12】向所有旧的worker进程发送QUIT
            live = 1;
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_SHUTDOWN_SIGNAL));
        }
		//注意，ngx_restart并不对应信号量，只是一个标志位
		//【13】为1，启动worker子进程
        if (ngx_restart) {
            ngx_restart = 0;
            ngx_start_worker_processes(cycle, ccf->worker_processes,
                                       NGX_PROCESS_RESPAWN);
			【14】启动cache_manager子进程
            ngx_start_cache_manager_processes(cycle, 0);
            live = 1;
        }
		//【信号USR1】->ngx_reopen: 重新打开服务中的所有文件
		//【15】重新打开所有文件
        if (ngx_reopen) {
            ngx_reopen = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "reopening logs");
            ngx_reopen_files(cycle, ccf->user);
			//【16】向所有worker发送USR1信号要求重新打开文件
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_REOPEN_SIGNAL));
        }
		//【信号USR2】->ngx_change_binary：平滑升级到新版本的nginx
		//【17】为1，运行新的nginx二进制
        if (ngx_change_binary) {
            ngx_change_binary = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "changing binary");
            ngx_new_binary = ngx_exec_new_binary(cycle, ngx_argv);
        }
		//【信号WINCH】ngx_noaccept：所有子进程不再接受新的连接，等同于对所有子进程发QUIT信号量
		//【18】为1，向所有子进程发送QUIT信号要求关闭服务
        if (ngx_noaccept) {
            ngx_noaccept = 0;
            ngx_noaccepting = 1;
            ngx_signal_worker_processes(cycle,
                                        ngx_signal_value(NGX_SHUTDOWN_SIGNAL));
        }
    }
}
```


以上可以看到，master对于worker的操作主要调用了`ngx_signal_worker_processes(cycle,具体信号)`函数：
```c
static void
ngx_signal_worker_processes(ngx_cycle_t *cycle, int signo)
{
    ...
	//ngx_channel_t用于进程间通信
    ngx_channel_t  ch;
    ngx_memzero(&ch, sizeof(ngx_channel_t));

#if (NGX_BROKEN_SCM_RIGHTS)

    ch.command = 0;

#else

    switch (signo) {

    case ngx_signal_value(NGX_SHUTDOWN_SIGNAL):
        ch.command = NGX_CMD_QUIT;
        break;

    case ngx_signal_value(NGX_TERMINATE_SIGNAL):
        ch.command = NGX_CMD_TERMINATE;
        break;

    case ngx_signal_value(NGX_REOPEN_SIGNAL):
        ch.command = NGX_CMD_REOPEN;
        break;

    default:
        ch.command = 0;
    }

#endif

    ch.fd = -1;

	//遍历一个叫做ngx_processes的数组来更新自身维护的worker信息
    for (i = 0; i < ngx_last_process; i++) {
		...
		//通过channel向worker进程同步信息
        if (ch.command) {
            if (ngx_write_channel(ngx_processes[i].channel[0],
                                  &ch, sizeof(ngx_channel_t), cycle->log)
                == NGX_OK)
            {
                if (signo != ngx_signal_value(NGX_REOPEN_SIGNAL)) {
                    ngx_processes[i].exiting = 1;
                }

                continue;
            }
        }
		...
		//kill进程
        if (kill(ngx_processes[i].pid, signo) == -1) {
            err = ngx_errno;
            ngx_log_error(NGX_LOG_ALERT, cycle->log, err,
                          "kill(%P, %d) failed", ngx_processes[i].pid, signo);

            if (err == NGX_ESRCH) {
                ngx_processes[i].exited = 1;
                ngx_processes[i].exiting = 0;
                ngx_reap = 1;
            }

            continue;
        }

        if (signo != ngx_signal_value(NGX_REOPEN_SIGNAL)) {
            ngx_processes[i].exiting = 1;
        }
    }
}
```
可以看到，master进程通过一个`ngx_processes`数组来维护worker进程的状态以及信息，同时通过channel向worker进程同步信息(关于ngx_channel_t的master于worker进程通信，随后讲解)，nginx对于进程信息维护的数据结构定义如下：
```c
ngx_process_t    ngx_processes[NGX_MAX_PROCESSES];

typedef struct {
   ngx_pid_t           pid;//进程id
   int                 status;//子进程退出后，父进程收到sigchld,父进程由waitpid系统调用去获得进程状态
   ngx_socket_t        channel[2];//socktpair产生的用于进程间通信的句柄

   ngx_spawn_proc_pt   proc;//启动子进程后的执行方法
   /*
    上面的ngx_spawn_proc_pt方法中第2个参数需要要传递1个指针，它是可选的。例如，worker子进程就不需要，而cache manage进程
    就需要ngx_cache_manager_ctx上下文成员。这时，data一般与ngx_spawn_proc_pt方法中第2个参数是等价的
    */
   void               *data;//
   char               *name;//进程的名字

   
   unsigned            respawn:1;//为1表示重新生成子进程
   unsigned            just_spawn:1;//表示正在生成子进程
   unsigned            detached:1;//表示父子进程分离
   unsigned            exiting:1;//表示进程正在退出
   unsigned            exited:1;//表示进程已经退出
} ngx_process_t;

```
另外，在fork之后，父进程的ngx_processes数组，“继承”给了子进程，但是这时子进程拿到的数组是截至创建该进程之前其他进程的信息。由于子进程是父进程fork得到的，那么在之后父进程的操作结果在子进程中就不可见了。假设当前诞生的是进程1，用p1表示，当父进程创建p5时，那么p2-p5的进程信息在p1中是缺失的，那么p1需要这些信息吗？如果需要的话，该通过什么手段给它呢？

答案请结合master-worker进程间通信，参考https://blog.csdn.net/midion9/article/details/49616509

## worker进程

通过上节的分析，master进程通过fork出子进程，并执行`ngx_worker_process_cycle`方法，同样的，worker进程的for循环中处理的master发送的信号量：

```c
static void
ngx_worker_process_cycle(ngx_cycle_t *cycle, void *data)
{
    ngx_int_t worker = (intptr_t) data;

    ngx_process = NGX_PROCESS_WORKER;
    ngx_worker = worker;

    ngx_worker_process_init(cycle, worker);

    ngx_setproctitle("worker process");

    for ( ;; ) {
		//ngx_exiting为标志位，在进程退出时使用
		//【1】为1，进程退出
        if (ngx_exiting) {
			//【2】检查事件，如果有未处理完
			if (ngx_event_no_timers_left() == NGX_OK) {
                ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "exiting");
				//【3】调用所有模块exit_process方法，销毁内存池
                ngx_worker_process_exit(cycle);
            }
        }

        ...
		//【4】还有未处理完事件时，调用ngx_process_events_and_timers处理
        ngx_process_events_and_timers(cycle);
		//【信号TERM/INT】->ngx_terminate: 强制关闭进程
		//【5】为1，强制关闭
        if (ngx_terminate) {
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "exiting");
			//调用所有模块exit_process方法，销毁内存池
            ngx_worker_process_exit(cycle);
        }
		//【信号QUIT】->ngx_quit: 关闭进程
		//【6】为1，优雅关闭
        if (ngx_quit) {
            ngx_quit = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0,
                          "gracefully shutting down");
            ngx_setproctitle("worker process is shutting down");
			//设置ngx_exiting标志位
            if (!ngx_exiting) {
                ngx_exiting = 1;
                ngx_set_shutdown_timer(cycle);
				//关闭监听的句柄，调用所有模块exit_process方法，销毁内存池
                ngx_close_listening_sockets(cycle);
                ngx_close_idle_connections(cycle);
            }
        }
		//【信号USR1】->ngx_reopen: 从新打开所有文件
		//【7】为1，重新打开所有文件
        if (ngx_reopen) {
            ngx_reopen = 0;
            ngx_log_error(NGX_LOG_NOTICE, cycle->log, 0, "reopening logs");
            ngx_reopen_files(cycle, -1);
        }
    }
}
```