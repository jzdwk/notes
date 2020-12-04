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

Linux默认在启动时，已经为每一个**subSystem**创建了对应的默认的**hierarchy**，mount路径位于`sys/fs/cgroup/xxx`,xxx包括了memory/cpu等,当然，这个目录也是**root cgroup**，毕竟hierarchy是抽象的概念，具体还是由各个cgroup去描述。
```shell
[root@iZ2zebl327dijrrsaeq81zZ ~]# mount -l
...
cgroup on /sys/fs/cgroup/perf_event type cgroup (rw,nosuid,nodev,noexec,relatime,perf_event)
cgroup on /sys/fs/cgroup/devices type cgroup (rw,nosuid,nodev,noexec,relatime,devices)
cgroup on /sys/fs/cgroup/blkio type cgroup (rw,nosuid,nodev,noexec,relatime,blkio)
cgroup on /sys/fs/cgroup/hugetlb type cgroup (rw,nosuid,nodev,noexec,relatime,hugetlb)
cgroup on /sys/fs/cgroup/pids type cgroup (rw,nosuid,nodev,noexec,relatime,pids)
cgroup on /sys/fs/cgroup/rdma type cgroup (rw,nosuid,nodev,noexec,relatime,rdma)
cgroup on /sys/fs/cgroup/cpu,cpuacct type cgroup (rw,nosuid,nodev,noexec,relatime,cpu,cpuacct)
cgroup on /sys/fs/cgroup/net_cls,net_prio type cgroup (rw,nosuid,nodev,noexec,relatime,net_cls,net_prio)
cgroup on /sys/fs/cgroup/freezer type cgroup (rw,nosuid,nodev,noexec,relatime,freezer)
cgroup on /sys/fs/cgroup/cpuset type cgroup (rw,nosuid,nodev,noexec,relatime,cpuset)
cgroup on /sys/fs/cgroup/memory type cgroup (rw,nosuid,nodev,noexec,relatime,memory)
...
```
因此在容器实现资源限额时，将在默认的**hierarchy**创建子cgroup,并写入限额配置，比如docker的实现见下面小节**docker&cgroup**。

### cgroup & task

概念上，一个进程可以作为多个cgroup的成员，但是这些cgroup必须在不同的hierarchy中（原因在于如果位于同一hierarchy的不同cgroup，该hierarchy绑定了memory subSystem，则无法约束这个进程的memory了）。一个进程fork出子进程时，子进程是和父进程在同一个cgroup中，也可以根据需要移动到其他cgroup。

具体的cgroup和进程的关系通过cgroup下的**tasks**描述，所以在默认的`sys/fs/cgroup/xxx`下（即root cgroup），tasks文件描述了系统中所有进程的信息：
```shell
[root@iZ2zebl327dijrrsaeq81zZ cpu]# cat tasks 
1
2
3
4
...
3325
3327
```
而在进行容器限额时，思路就是创建一个**子cgroup**，将容器进程id写入子cgroup的tasks，并在子cgroup上描述具体限额配置。比如docker的实现见下面小节**docker&cgroup**。

### docker & cgroup

使用docker run一个容器后，docker会为每个容器在系统的**hierarchy**中创建子的cgroup:
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
其中的文件`memory.limit_in_bytes`等就是用来描述这个cgroup的限额。另一方面，通过查看这个cgroup的tasks文件，可看到这个限额将作用于哪个容器进程，比如下面例子的1898：
```shell
[root@iZ2zebl327dijrrsaeq81zZ 281b2a76e696cde0d5009ce94d1221d7c103ab491e05dc47123e8be564bb82f]# cat tasks 
1898
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

net namespace隔离了网络栈，容器网络的隔离使用了net namespace。但容器间需要通信，同时容器也需要和宿主通信。因此提供了**Veth设备**。 **两个命名空间之间的通信，需要使用一个Veth设备对**

示例：
```shell
[/]$ #创建两个网络Namespace
[/]$ sudo ip netns add nsl
[/]$ sudo ip netns add ns2
[/]$ #创建一对Veth
[/]$ sudo ip l nk add vethO type veth peer name vethl
[/]$ #分别将两个Veth移到两个Namespace 中
[/]$ sudo ip link set vethO netns nsl
[/]$ sudo ip link set vethl netns ns2
[/]$ #配置每个veth的网络地址，并启动设备
[/]$ sudo ip netns exec nsl ifconfig vethO 172.18.0.2/24 up
[/]$ sudo ip netns exec ns2 ifconfig vethl 172.18.0.3/24 up
[/]$ #配置ns1的路由，default代表0.0.0.0/0，即所有流量经过veth0流出
[/]$ sudo ip netns exec nsl route add default dev vethO
[/]$ #同上
[/]$ sudo ip netns exec ns2 route add default dev vethl
[/]$ #通过veth一端出去的包，在另外一端(另一个ns中，ns2)能够直接接收到
[/]$ sudo ip netns exec nsl ping -c 1 172.18.0.3
```
### Bridge

Bridge工作在**链路层**，是一种**虚拟网络设备**，所以具备虚拟网络设备的所有特性，比如可以配置 IP、MAC 等。除此之外，Bridge还是一个**交换机**，具有交换机所有的功能。因此，Bridge可以接入其他的网络设备，比如物理设备、虚拟设备、VLAN 设备等。Bridge通常充当主设备，其他设备为从设备，这样的效果就等同于物理交换机的端口连接了一根网线。

而它把其他的从设备虚拟为一个port。当把一个网卡设备(或虚拟网卡)加入的网桥后，网卡将**共享网桥的ip，网卡的接受、发送数据包就交给网桥决策**。

因此，Bridge可以作为容器/虚拟机通信的媒介，将不同net namespace上的Veth设备加入Bridge实现通信。

示例：
```shell
[/]$ #创建Veth对，并将一端veth1移入namespace
[/]$ sudo ip netns add ns1
[/]$ sudo ip link add veth0 type veth peer name veth1
[/]$ #将veth1移入ns1
[/]$ sudo ip link set vethl netns nsl
[/]$ #创建网桥br0
[/]$ sudo brctl addbr br0
[/]$ #挂载网络设备,其中将veth0挂载到网桥
[/]$ sudo brctl addif br0 eth0
[/]$ sudo brctl addif br0 veth0
```

### route table

linux的路由表功能和路由器中的route table一致，定义路由表来决定在某个网络Namespace中包的流向，从而定义请求会到哪个网络设备上。

```shell
[/]$ #启动veth0和网桥br0
[/]$ sudo ip link set veth0 up
[/]$ sudo ip link set br0 up
[/]$ 设置veth1在Net Namespace中的IP地址
[/]$ sudo ip netns exec ns1 ifconfig veth1 172.18.0.2/24 up
[/]$ #设置nsl的路由
[/]$ #default代表0.0.0.0/0，即在Net Namespace中所有流量都经过vethl的网络设备流出
[/]$ sudo ip netns exec nsl route add default dev vethl
[/]$ #在宿主机上将172.18.0.0/24 的网段请求路由到br0的网桥
[/]$ sudo route add -net 172.18.0.0/24 dev br0
[/]$ #从ns1中访问宿主机的地址,假设为10.0.2.15
[/]$ 此时的路径为:首先根据ns1的路由表配置，所有流量从veth1流出，流向对端设备veth0，而后者和eth0均挂载与网桥上，因此通信成功
[/]$ sudo ip netns exec nsl ping -c 1 10.0.2.15
[/]$ #从宿主机访问Namespace中的网络地址
[/]$ #此时的路径为：根据宿主的route配置，172流量均流向网桥br0，因此br0接收流量，根据mac地址转发至veth0的对端veth1,
[/]$ ping -c 1 172.18.0.2
```

### iptables










```