# base

容器三板斧：`Namespace` `Cgroup`以及 `mount`

## namespace

linux总共有6种namespace，用于隔离进程、存储、网络等资源。namespace的api主要使用3个系统调用：

1. clone(), 创建新进程。根据系统调用参数来判断哪些类型的namespace的api主要使用3个系统调用 被创建，而且它们的子进程也会被包含到这些Namespace中。

2. unshare(), 将进程移出某个Namespace

3. setns(), 将进程加入到Namespace

### UTS Namespace

UTS Namespace主要用来隔离**hostname 以及 NIS domain name**2个系统标识。在 UTS Namespace里面，每个Namespace中，允许有自己的hostname。

- 调用参数：`CLONE_NEWUTS`

- go代码示例：
```go
func main() {
	cmd := exec.Command("sh")
	//fork出新的进程，进程位于和父进程不同的uts中
	//可通过
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}
```

### IPC	Namespace

IPC Namespace用来隔离**System V IPC 、POSIX message queues**, 每个IPC Namespace都有自己的System V IPC和POSIX message queue。

- 调用参数：`CLONE_NEWIPC`

- go代码示例：
```go
func main() {
	cmd := exec.Command("sh")
	//fork new process,
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS|syscall.CLONE_NEWIPC,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}
```

### PID Namespace

PID Namespace用来**隔离进程ID**，同样的一个进程在不同的PID Namespace中可以拥有不同的PID，对于docker来说，同一个进程，在容器内的pid=1，在容器外有自己的pid，就来源于此。

- 调用参数：`CLONE_NEWPID`

- go代码示例：
```go
func main() {
	cmd := exec.Command("sh")
	//fork new process,
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS|syscall.CLONE_NEWIPC|syscall.CLONE_NEWPID,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}
```

### Mount Namespace

Mount Namespace用来**隔离各个进程看到的挂载点试图**，在mount namespace中调用`mount/umount`仅仅只会影响当前Namespace内文件。其作用类似于`chroot`，但更灵活和安全？

- 调用参数：`CLONE_NEWNS`

- go代码示例：
```go
func main() {
	cmd := exec.Command("sh")
	//fork new process,
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS|syscall.CLONE_NEWIPC|syscall.CLONE_NEWPID|syscall.CLONE_NEWNS,
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
}
```

### User Namespace

Uses Namespace用来**隔离用户的用户组ID**，一个进程的UserID和GroupID在User Namespace内外可以不同。比如，在一个宿主机使用非root创建一个User Namespace，然后再User Namespace内映射为root用户。

- 调用参数：`CLONE_NEWUSER`

- go代码示例：
```go
func main() {
	cmd := exec.Command("sh")
	//fork new process,
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS|syscall.CLONE_NEWIPC|syscall.CLONE_NEWPID|syscall.CLONE_NEWNS|syscall.CLONE_NEWUSER,
	}
	cmd.SysProcAttr.Credential = &syscall.Credential{Uid:uint32(1),Gid:uint32(1)}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
	os.Exit(-1)
}
```

### Network Namespace

Network namespace在逻辑上是网络堆栈的一个副本，用来隔离**网络设备、ip/port等**，它有自己的路由、防火墙规则和网络设备。默认情况下，子进程继承其父进程的network namespace。

- 调用参数：`CLONE_NEWNET`

- go代码示例：
```go
func main() {
	cmd := exec.Command("sh")
	//fork new process,
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags: syscall.CLONE_NEWUTS|syscall.CLONE_NEWIPC|
			syscall.CLONE_NEWPID|syscall.CLONE_NEWNS|
			syscall.CLONE_NEWUSER|syscall.CLONE_NEWNET,
	}
	cmd.SysProcAttr.Credential = &syscall.Credential{Uid:uint32(1),Gid:uint32(1)}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		log.Fatal(err)
	}
	os.Exit(-1)
}
```

## cgroup

全称`Control Groups`，提供了对一组进程以及子进程的资源限制、控制和统计的能力。这些资源包括CPU/内存/存储/网络等。

重要的几个概念：

- **subSystem 子系统**：cgroups为每种可以控制的资源定义了一个子系统(subSystem)，具体包括了：
1. cpu 子系统，主要限制进程的 cpu 使用率。
2. cpuacct 子系统，可以统计 cgroups 中的进程的 cpu 使用报告。
3. cpuset 子系统，可以为 cgroups 中的进程分配单独的 cpu 节点或者内存节点。
4. memory 子系统，可以限制进程的 memory 使用量。
5. blkio 子系统，可以限制进程的块设备 io。
6. devices 子系统，可以控制进程能够访问某些设备。
7. net_cls 子系统，可以标记 cgroups 中进程的网络数据包，然后可以使用 tc 模块（traffic control）对数据包进行控制。
8. freezer 子系统，可以挂起或者恢复 cgroups 中的进程。
9. ns 子系统，可以使不同 cgroups 下面的进程使用不同的 namespace。

每一个子系统都需要与内核的其他模块配合来完成资源的控制

- **Hierarchy 层级结构**

Hierarchy是由cgroup组成的**树形结构**。一方面，树形结构的Hierarchy保证了**其上的每个cgroup节点都继承自父节点的资源约束关系**；另一方面，一个Hierarchy可以绑定**一个或者多个不同的subSystem**， 而**一个subsystem只能绑定到某个Hierarchy上**。 

举个例子，比如定义了一个`Hierarchy_1`，并将某memory约束`mem_subSystem`绑定此`Hierarchy_1`，则此`Hierarchy_1`的根节点`r_cgroup`将遵循这个`mem_subSystem`描述的mem约束，比如`2G`。接下来，这个根节点`r_cgroup`下的所有子节点将遵循这一约束，并可配置每个节点对memory使用的占比，比如`chd_cgroup`配置了20%,即该`chd_group`下的进程最多使用`2000mb*20%=400mb`memory.

### docker & cgroup

使用docker run一个容器后，docker会为每个容器在系统的**hierarchy**中创建cgroup:
```shell

# docker ps
jzd@myharbor:~$ docker ps
CONTAINER ID        IMAGE                  COMMAND                  CREATED             STATUS              PORTS                NAMES
281b2a76e696        kennethreitz/httpbin   "gunicorn -b 0.0.0.0…"   2 months ago        Up 4 seconds        0.0.0.0:83->80/tcp   determined_shannon

# 查看cgroup的memory
root@myharbor:/sys/fs/cgroup/memory/docker# ls
281b2a76e696cde0d5009ce94d1221d7c103ab491e05dc47123e8be564bb82f7  memory.kmem.tcp.failcnt             memory.pressure_level
cgroup.clone_children                                             memory.kmem.tcp.limit_in_bytes      memory.soft_limit_in_bytes
cgroup.event_control                                              memory.kmem.tcp.max_usage_in_bytes  memory.stat
cgroup.procs                                                      memory.kmem.tcp.usage_in_bytes      memory.swappiness
memory.failcnt                                                    memory.kmem.usage_in_bytes          memory.usage_in_bytes
memory.force_empty                                                memory.limit_in_bytes               memory.use_hierarchy
memory.kmem.failcnt                                               memory.max_usage_in_bytes           notify_on_release
memory.kmem.limit_in_bytes                                        memory.move_charge_at_immigrate     tasks
memory.kmem.max_usage_in_bytes                                    memory.numa_stat
memory.kmem.slabinfo

# 进入以容器id为目录名的目录
root@myharbor:/sys/fs/cgroup/memory/docker/281b2a76e696cde0d5009ce94d1221d7c103ab491e05dc47123e8be564bb82f7# ls
cgroup.clone_children  memory.kmem.limit_in_bytes          memory.kmem.tcp.usage_in_bytes   memory.oom_control          memory.use_hierarchy
cgroup.event_control   memory.kmem.max_usage_in_bytes      memory.kmem.usage_in_bytes       memory.pressure_level       notify_on_release
cgroup.procs           memory.kmem.slabinfo                memory.limit_in_bytes            memory.soft_limit_in_bytes  tasks
memory.failcnt         memory.kmem.tcp.failcnt             memory.max_usage_in_bytes        memory.stat
memory.force_empty     memory.kmem.tcp.limit_in_bytes      memory.move_charge_at_immigrate  memory.swappiness
memory.kmem.failcnt    memory.kmem.tcp.max_usage_in_bytes  memory.numa_stat                 memory.usage_in_bytes

```

## Union File System

可以移步[docker-image-store.md](../docker-image-store.md)

## 进程管理

### proc文件

Linux 下的`/proc`文件系统由内核提供，它其实不是一个真正的文件系统，只包含了系统运行时的信息(如系统内存、mount设备信息、一些硬件配直等)，它**只存在于内存中**，不占用外存空间。它以文件系统的形式，为访问内核数据的操作提供接口。

`/proc`目录下的每一个**数字目录代表了一个进程PID**， 其中：

```
/proc/N PID 		为N的进程信息
/proc/N/cmdline		进程启动命令
/proc/N/cwd			链接到进程当前工作目录
/proc/N/environ		进程环境变量列表
/proc/N/exe			链接到进程的执行命令文件
/proc/N/fd			包含进程相关的所有文件描述符
/proc/N/maps		与进程相关的内存映射信息
/proc/N/mem			指代进程持有的内存，不可读
/proc/N/root		链接到进程的根目录
/proc/N/stat		进程的状态
/proc/N/statm		进程使用的内存状态
/proc/N/status		进程状态信息，比stat/statm 更具可读性
/proc/self/			链接到当前正在运行的进程
```
### pivot_root

### detach

## network

### Veth

### Bridge

### route

### iptables










```