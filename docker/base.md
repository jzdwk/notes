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

## 网络管理

### docker 网络类型

- **host**

使用host模式时，容器将不会获得一个独立的Network Namespace，而是**和宿主机共用一个Network Namespace**。因此，容器将不会虚拟出自己的网卡，配置自己的IP等，而是使用宿主机的IP和端口
```shell
$ ## 运行一个nginx
$ docker run --name=nginx_host --net=host -p 80:80 -d nginx
$ ## 提示端口映射将失效
$ WARNING: Published ports are discarded when using host network mode
$ ## 提示端口映射将失效
```
在容器中，执行ifconfig命令查看网络环境时，看到的都是宿主机上的信息。同样的，外界访问容器中的应用，则直接使用**{host-ip}:{port}**即可，不用任何NAT转换，就如直接跑在宿主机中一样。但容器文件系统、进程列表等还是和宿主机隔离的。

- **container**

host模式是和host共享一个Network Namespace, 而container模式指定新创建的容器和**已经存在的一个容器共享一个Network Namespace**。新创建的容器不会创建自己的网卡，配置自己的IP，而是和一个指定的容器共享IP、端口范围等。同样，两个容器除了网络方面，其他的如文件系统、进程列表等还是隔离的。两个容器的进程可以通过lo网卡设备通信。

- **none**

该模式将容器放置在它自己的网络栈中，但是并不进行任何配置。换句话说，该模式关闭了容器的网络功能，主要应用于**容器并不需要网络**的场景，比如磁盘读写任务。

- **bridge**

容器**使用独立network Namespace，并连接到docker0虚拟网卡（默认模式）**。通过docker0网桥以及Iptables nat表配置与宿主机通信。

**bridge模式是Docker默认的网络设置**，此模式会为每一个容器分配Network Namespace、设置IP等，并将一个主机上的Docker容器连接到一个虚拟网桥上。



### Veth

net namespace隔离了网络栈，容器网络的隔离使用了net namespace。但容器间需要通信，同时容器也需要和宿主通信。因此提供了**Veth设备**。 **两个命名空间之间的通信，需要使用一个Veth设备对**。Veth设备总是成对出现的，它们组成了一个数据的通道，数据从一个设备进入，就会从另一个设备出来。因此，veth设备常用来连接两个网络设备。

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

veth的问题在于，当在多个network namespace之间通信时，veth需要类似点对点的架构，形成网状网络，整个管理会非常复杂，任意两个namespace之间都需要创建veth pair。使用linux网桥可以解决这种困扰，充当交换机的功能，将**网状网络转化为星状网络**。


Bridge工作在**链路层**，是一种**虚拟网络设备**，可类比为一个**交换机**，具有交换机所有的功能。因此，Bridge可以接入其他的网络设备，比如物理设备、虚拟设备、VLAN 设备等。Bridge通常充当主设备，其他设备为从设备，这样的效果就等同于物理交换机的端口连接了一根网线。

而它把其他的从设备虚拟为一个port。当把一个网卡设备(或虚拟网卡)加入的网桥后，网卡将**共享网桥的ip，网卡的接受、发送数据包就交给网桥决策**。具体来说

- 在收到一个数据帧时，记录其源mac地址和对应的PORT的映射关系，进行一轮学习
- 在收到一个数据帧时，检查目的mac地址是否在本地缓存，如果在，则将数据帧转发到具体的PORT，如果不在，则进行泛洪，给除了入PORT之外的所有PORT都拷贝这个帧

那么，将veth桥接到网桥当中，这样通过网桥的自学习和泛洪功能，就可以将数据包从一个namespace发送到另外一个namespace当中。

因此，Bridge可以作为容器/虚拟机通信的媒介，**将不同net namespace上的Veth设备加入Bridge**实现通信。

示例：
```shell
[/]$ #创建Veth对，并将一端veth1移入namespace
[/]$ sudo ip netns add ns1
[/]$ sudo ip link add veth0 type veth peer name veth1
[/]$ #将veth1移入ns1
[/]$ sudo ip link set veth1 netns ns1
[/]$ #创建网桥br0
[/]$ sudo brctl addbr br0
[/]$ #挂载网络设备,其中将veth0挂载到网桥
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
[/]$ sudo ip netns exec ns1 route add default dev veth1
[/]$ #在宿主机上将172.18.0.0/24 的网段请求路由到br0的网桥
[/]$ sudo route add -net 172.18.0.0/24 dev br0
[/]$ #从ns1中访问宿主机的地址,假设为10.0.2.15
[/]$ 此时的路径为:首先根据ns1的路由表配置，所有流量从veth1流出，流向对端设备veth0，而后者和eth0均挂载与网桥上，网桥执行泛洪，因此通信成功
[/]$ sudo ip netns exec ns1 ping -c 1 10.0.2.15
[/]$ #从宿主机访问Namespace中的网络地址
[/]$ #此时的路径为：根据宿主的route配置，172流量均流向网桥br0，因此br0接收流量，根据mac地址转发至veth0的对端veth1,
[/]$ ping -c 1 172.18.0.2
```
参考：[https://zhuanlan.zhihu.com/p/185783192]


### iptables

netfilter/iptables(iptables是Linux管理工具，位于/sbin/iptables。实现功能的是netfilter，它是Linux内核中实现包过滤的内部结构，是Linux平台下的包过滤防火墙，它通过配置**规则**，完成封包过滤、封包重定向和网络地址转换（NAT）等功能。实现上，通过**表和链**来完成具体功能。

- **表tables**提供特定的功能，iptables内置了**4个表，即filter表、nat表、mangle表和raw表**，分别用于实现包过滤，网络地址转换、包重构(修改)和数据跟踪处理。具体的划分如下：

1. filter表，**较为常用**，作用：过滤数据包  内核模块：iptables_filter.
2. Nat表，**较为常用**，作用：用于网络地址转换（IP、端口） 内核模块：iptable_nat
3. Mangle表，作用：修改数据包的服务类型、TTL、并且可以配置路由实现QOS  内核模块：iptable_mangle
4. Raw表，作用：决定数据包是否被状态跟踪机制处理  内核模块：iptable_raw

表的优先顺序为：**raw-->mangle-->nat-->filter**

- **链chains**是数据包传播的路径，每一条链其实就是众多规则中的一个检查清单，每一条链中可以有一 条或数条规则。当一个数据包到达一个链时，iptables就会从链中第一条规则开始检查，看该数据包是否满足规则所定义的条件。如果满足，系统就会根据 该条规则所定义的方法处理该数据包；否则iptables将继续检查下一条规则，如果该数据包不符合链中任一条规则，iptables就会根据该链预先定义的默认策略来处理数据包。**链**的种类分为了：

1. INPUT——进来的数据包应用此规则链中的策略
2. OUTPUT——外出的数据包应用此规则链中的策略
3. FORWARD——转发数据包时应用此规则链中的策略
4. PREROUTING——对数据包作路由选择前应用此链中的规则，**所有的数据包进来的时侯都先由这个链处理**
5. POSTROUTING——对数据包作路由选择后应用此链中的规则，**所有的数据包出来的时侯都先由这个链处理**

- **链和表**的关系

表描述了实现功能模块上的划分，链描述了对数据包的处理时机。

这样设计的原因在于：对于一个数据包的处理，有**两个维度**需要考虑，**一个是如何处理，另一个是处理时机。如何处理**的逻辑即为包过滤、重构等，对应于**表的功能**，**处理时机**则分为了路由前/后等，**对应于链的描述.**

因此，当一个数据包进入主机后，其处理流程上可以**先看链，再看表**。当然，有一些链上只有个别的几个表，其完成流程为（重要）：
```
PREROUTING 链	===> 	raw表 	 ->  mangle表 -> nat表
(进行路由判定，看数据包是路由到本机还是转发，如果是流入本机)
INPUT 链 		===> 	mangle表 ->  filter表
OUTPUT 链		===>	raw表 	 ->  mangle表 -> nat表 -> filter表
POSTROUTING 链 	===>	mangle表 ->  nat表

(如果是需要转发)
FORWARD 链		===>	mangle表 ->  filter表
POSTROUTING 链 	===>	mangle表 ->  nat表
```

可见图[!tables&chains](../images/docker/base-table-chain.png)

详细步骤如下： 

1. 数据包到达网络接口，比如 eth0。 
2. 进入 raw 表的 PREROUTING 链，这个链的作用是赶在连接跟踪之前处理数据包。 
3. 如果进行了连接跟踪，在此处理。 
4. 进入 mangle 表的 PREROUTING 链，在此可以修改数据包，比如 TOS 等。 
5. 进入 nat 表的 PREROUTING 链，可以在此做DNAT，但不要做过滤。 
6. 决定路由，看是交给本地主机还是转发给其它主机。 

当数据包要转发给其它主机： 

7. 进入 mangle 表的 FORWARD 链，这里也比较特殊，这是在第一次路由决定之后，在进行最后的路由决定之前，我们仍然可以对数据包进行某些修改。 
8. 进入 filter 表的 FORWARD 链，在这里我们可以对所有转发的数据包进行过滤。需要注意的是：经过这里的数据包是转发的，方向是双向的。 
9. 进入 mangle 表的 POSTROUTING 链，到这里已经做完了所有的路由决定，但数据包仍然在本地主机，我们还可以进行某些修改。 
10. 进入 nat 表的 POSTROUTING 链，在这里一般都是用来做 SNAT ，不要在这里进行过滤。 
11. 进入出去的网络接口。完毕。 

当数据包发给本地主机的，那么它会依次穿过： 

7. 进入 mangle 表的 INPUT 链，这里是在路由之后，交由本地主机之前，我们也可以进行一些相应的修改。 
8. 进入 filter 表的 INPUT 链，在这里我们可以对流入的所有数据包进行过滤，无论它来自哪个网络接口。 
9. 交给本地主机的应用程序进行处理。 
10. 处理完毕后进行路由决定，看该往那里发出。 
11. 进入 raw 表的 OUTPUT 链，这里是在连接跟踪处理本地的数据包之前。 
12. 连接跟踪对本地的数据包进行处理。 
13. 进入 mangle 表的 OUTPUT 链，在这里我们可以修改数据包，但不要做过滤。 
14. 进入 nat 表的 OUTPUT 链，可以对防火墙自己发出的数据做 NAT 。 
15. 进入 filter 表的 OUTPUT 链，可以对本地出去的数据包进行过滤。 
16. 再次进行路由决定。 
17. 进入 mangle 表的 POSTROUTING 链，同上一种情况的第9步。注意，这里不光对经过防火墙的数据包进行处理，还对防火墙自己产生的数据包进行处理。 
18. 进入 nat 表的 POSTROUTING 链，同上一种情况的第10步。 
19. 进入出去的网络接口。完毕

- iptables的命令格式：
```shell
iptables [-t 表名] 命令选项 ［链名］ ［条件匹配］ ［-j 目标动作或跳转］
```
参考[!iptable](../image/docker/base-iptable.jpg)

参考: 
[1](https://blog.51cto.com/wushank/1171768)
[2](https://www.jianshu.com/p/ee4ee15d3658)

- 容器常用的规则：

容器场景下，需要对进入容器的数据包的ip地址进行转换，数据流出时，包中的source address应该为宿主ip，流入时，包中的destination address应该为容器ip。因此，使用iptables增加规则

1. MASQUERADE

在理解这个规则之前，先梳理SNAT（Source Network Address Translation，源地址转换）,SNAT在数据包流出这台机器之前的最后一个链，也就是POSTROUTING链，进行操作。比如：
```shell
# iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -j SNAT --to-source 58.20.51.66
```
这个语句就是告诉系统把即将要流出本机的数据的source ip address修改成为58.20.51.66。这样，数据包在达到目的机器以后，目的机器会将包返回到58.20.51.66也就是本机。但是这有一个问题：**假如当前系统用的是ADSL/3G/4G动态拨号方式，那么每次拨号，出口IP都会改变，同样的，对于容器场景，每次容器启动，其ip为系统随机分配，因此SNAT就会有局限性**，因此，MASQUERADE即解决这个问题:
```shell
#  iptables -t nat -A POSTROUTING -s 192.168.0.0/24 -o eth0 -j MASQUERADE
```
MASQUERADE会**自动读取eth0现在的ip地址然后做SNAT出去**，这样就实现了很好的动态SNAT地址转换。

2. DNAT（Destination Network Address Translation,目的地址转换)

DNAT主要应用在**外部应用访问容器内应用时**，外部应用无法知道容器内应用的ip地址和ns(比如ns1上的172.18.0.2)，因此外部数据包到达后，需要根据某种策略，将访问某端口的请求的Destination Network Address转换为172.18.0.2，比如：
```shell
[/] $ #将到宿主机上80端口的请求转发到Namespace的IP 上
[/] $ sudo iptables -t nat -A PREROUTING -p tcp -m tcp --dport 80 -j DNAT --to-destination 172.18.0.2:80
```

参考：
[1](https://www.jianshu.com/p/beeb6094bcc9)


- 实例分析：

接下来以docker中的一个实例来分析，首先查看主机的iptables信息，分析将以默认的docker0网桥为主，并省略了k8s相关条目：
```
//首先查看主机的路由表，即如果要访问172.17.0.0/16网段的地址，那么流量将指向docker0，不需要经过路由（Gateway 被设为0.0.0.0）
//如果是其他的地址（default，其实就是0.0.0.0），那么网络消息将通过Iface指定的网卡eth0发送
[root@VM-24-5-centos ~]# route
Kernel IP routing table
Destination     Gateway         Genmask         Flags Metric Ref    Use Iface
default         gateway         0.0.0.0         UG    0      0        0 eth0
10.0.24.0       0.0.0.0         255.255.252.0   U     0      0        0 eth0
link-local      0.0.0.0         255.255.0.0     U     1002   0        0 eth0
172.17.0.0      0.0.0.0         255.255.0.0     U     0      0        0 docker0
//查看主机的iptables配置
[root@VM-24-5-centos ~]# iptables-save
# Generated by iptables-save v1.4.21 on Tue Feb 15 11:06:19 2022
*mangle
:PREROUTING ACCEPT [415868989:71250020019]
:INPUT ACCEPT [409196173:69459156488]
:FORWARD ACCEPT [6672816:1790863531]
:OUTPUT ACCEPT [409602524:71303631973]
:POSTROUTING ACCEPT [416275340:73094495504]
...
COMMIT
# Completed on Tue Feb 15 11:06:19 2022
# Generated by iptables-save v1.4.21 on Tue Feb 15 11:06:19 2022
*filter
:INPUT ACCEPT [5317:565483]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [5282:889835]
:DOCKER - [0:0]
:DOCKER-ISOLATION-STAGE-1 - [0:0]
:DOCKER-ISOLATION-STAGE-2 - [0:0]
:DOCKER-USER - [0:0]
...
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-ISOLATION-STAGE-1
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -o docker0 -j DOCKER
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT
-A FORWARD -i docker0 -o docker0 -j ACCEPT
...
-A DOCKER -d 172.17.0.2/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 5432 -j ACCEPT
-A DOCKER -d 172.17.0.4/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 36790 -j ACCEPT
-A DOCKER -d 172.17.0.4/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 36789 -j ACCEPT
-A DOCKER-ISOLATION-STAGE-1 -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2
-A DOCKER-ISOLATION-STAGE-1 -j RETURN
-A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP
-A DOCKER-ISOLATION-STAGE-2 -j RETURN
-A DOCKER-USER -j RETURN
...
COMMIT
# Completed on Tue Feb 15 11:06:19 2022
# Generated by iptables-save v1.4.21 on Tue Feb 15 11:06:19 2022
*nat
:PREROUTING ACCEPT [656:24268]
:INPUT ACCEPT [653:24088]
:OUTPUT ACCEPT [476:29996]
:POSTROUTING ACCEPT [479:30176]
:DOCKER - [0:0]
...
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
...
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
...
-A POSTROUTING -s 172.17.0.2/32 -d 172.17.0.2/32 -p tcp -m tcp --dport 5432 -j MASQUERADE
-A POSTROUTING -s 172.17.0.4/32 -d 172.17.0.4/32 -p tcp -m tcp --dport 36790 -j MASQUERADE
-A POSTROUTING -s 172.17.0.4/32 -d 172.17.0.4/32 -p tcp -m tcp --dport 36789 -j MASQUERADE
-A DOCKER -i docker0 -j RETURN
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 65432 -j DNAT --to-destination 172.17.0.2:5432
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 65300 -j DNAT --to-destination 172.17.0.4:36790
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 65299 -j DNAT --to-destination 172.17.0.4:36789
...
COMMIT
# Completed on Tue Feb 15 11:06:19 2022
```
1. 容器内访问主机： 

对于主机的 iptables而言，是有数据从docker0过来，想进入到主机的传输层和应用层。判断它要发往本地还是外地就看它的目的地址是不是主机上的网卡配置了的其中一个地址。首先看PREROUTING链，它对应的raw和mangle表都没有条目，它在nat表有一个规则：
```
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
```
意思是，如果数据的目标是本地，那么跳转到DOCKER。DOCKER是docker自己建立的一条链（`:DOCKER - [0:0]该行表示此表拥有的链`）。于是我们跳到DOCKER链，即`-j DOCKER`。它在nat表有一个规则：
```
-A DOCKER -i docker0 -j RETURN
```
意思是，如果数据来自于网卡docker0，那么不再往下匹配链条的规则，直接返回到调用它的那条链的下一条规则（即RETURN）。所以我们又回到了PREROUTING链。但是PREROUTING 链已经没有规则了，根据`:PREROUTING ACCEPT`行，如果执行完最后一条规则，那么就执行ACCEPT操作，通过此数据包。之后进入到 INPUT 链。

INPUT链没有规则，而且在两个表mangle和filter默认规则都是ACCEPT，因此整个流程结束，容器内访问主机的包原封不动被传递。

2. 容器内访问外地：

对于主机的iptables而言，是有数据从docker0过来，想出主机。首先进入PREROUTING 链，由于唯一的规则不匹配，因此执行默认的ACCEPT操作。之后进入到INPUT链。INPUT链也同样默认 ACCEPT。假设根据主机的路由表，发往外地的包都要经过eth0。现在进入FORWARD链。规则从上到下依次匹配。
```
//1. 第一条，直接跳到DOCKER-USER，继续看
-A FORWARD -j DOCKER-USER

//3. 跳到链DOCKER-ISOLATION-STAGE-1
-A FORWARD -j DOCKER-ISOLATION-STAGE-1
//7. FORWARD以下两条都是目标为docker0，跳过
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -o docker0 -j DOCKER
//8. 表示来自docker0且目的地不是docker0的包采用动作 ACCEPT。于是进入POSTROUTING链
-A FORWARD -i docker0 ! -o docker0 -j ACCEPT
-A FORWARD -i docker0 -o docker0 -j ACCEPT
...
-A DOCKER -d 172.17.0.2/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 5432 -j ACCEPT
-A DOCKER -d 172.17.0.4/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 36790 -j ACCEPT
-A DOCKER -d 172.17.0.4/32 ! -i docker0 -o docker0 -p tcp -m tcp --dport 36789 -j ACCEPT

//4. 查看DOCKER-ISOLATION-STAGE-1，即来自docker0但不去往docker0的包跳到 DOCKER-ISOLATION-STAGE-2链
-A DOCKER-ISOLATION-STAGE-1 -i docker0 ! -o docker0 -j DOCKER-ISOLATION-STAGE-2

//6. 直接 RETURN，又回到 FORWARD 链。
-A DOCKER-ISOLATION-STAGE-1 -j RETURN

//5. 查看DOCKER-ISOLATION-STAGE-2，如果去往docker0的包则丢弃，否则看下一条，下一条为RETURN，于是回到DOCKER-ISOLATION-STAGE-1链
-A DOCKER-ISOLATION-STAGE-2 -o docker0 -j DROP
-A DOCKER-ISOLATION-STAGE-2 -j RETURN

//2. 第二条，DOCKER-USER 返回了，那么继续看FORWARD的吓一跳
-A DOCKER-USER -j RETURN
...

*nat
:PREROUTING ACCEPT [656:24268]
:INPUT ACCEPT [653:24088]
:OUTPUT ACCEPT [476:29996]
:POSTROUTING ACCEPT [479:30176]
:DOCKER - [0:0]
...
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER
...
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER

//9. POSTROUTING链规则生效，因为我们的包就是来自容器内，即172.17.0.0/16网段，且不发往docker0，于是执行MASQUERATE动作，将包的源 IP 改为将要发送此包的网卡的IP
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
...
```

3. 主机访问容器内：

对于主机的iptables而言，是有数据从内部过来，想出主机。前面的规则与`1. 容器内访问主机`一致，但是接下来，通过主机的路由表发现，这种包应该发送给网卡docker0。因此进入OUTPUT 链，有一条规则：
```
//1. 如果目标不是127.0.0.0/8网段，但目标是本地地址的，跳到DOCKER链。但我们访问的是一个容器的地址，不是docker0的地址，因此并不满足本地地址的要求。OUTPUT 链结束
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER
//2. 进入 POSTROUTING 链, 如果源是172.17.0.0/16网段，但目标不是docker0，那么执行动作MASQUERADE，即将源地址改成即将发送此消息的网卡的地址。
//	然而并不是，整条链结束，数据原封不动被路由到docker0
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

4. 外地访问容器内：

对于主机的iptables而言，是有数据从eth0过来，要去docker0，从外地发往外地。前面的规则与`1. 容器内访问主机`一致，PREROUTING链和INPUT链都会放行，经过路由表判断后，进入 FORWARD 链：
```
//FORWARD一直会匹配到这条规则了，允许目标为docker0，且这些包如果是 RELATED 状态或者 ESTABLISHED 状态连接中的一部分，那么就接受。
-A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

//我们在建立 TCP 连接时，要经历三次握手。客户端发出了 SYN 包到服务器，此时 iptables 检测到了这个包，根据之前的说法，它会放行，并判断有一个新连接要产生，连接便为 NEW 状态；服务器将返回 SYN/ACK 包，通过 iptables 后，它判断这个包是为 NEW 状态的连接的一个响应，该连接状态即为 ESTABLISHED，规则匹配成功，放行。之后服务端于该连接发送给客户端的数据都会放行。RELATED 状态则是由一个已经处于 ESTABLISHED 状态的连接产生的一个额外连接，比如 FTP 协议的 FTP-data 连接的产生就会于 FTP-control 连接后成为 RELATED 状态的连接，而不仅仅是 NEW 状态。一些 ICMP 应答也是如此。这种情况，防火墙也会放行。

如果包不属于这两种状态，比如外界向本机发起了连接，那么继续下一行，下一行表示目的地为docker0跳到 DOCKER 链。DOCKER 链直接返回。继续下面的规则，两条规则都要求来自docker0，不满足，因此不匹配，所有 FORWARD 链的规则都被匹配过了，执行默认动作 DROP（:FORWARD DROP），该包被丢弃。这样外网便无法访问容器内的服务。

```

5. 容器内访问容器内

对于 iptables ，是从外到外，从docker0到docker0。同样，PREROUTING 和 INPUT 链放行，进入 FORWARD 链。它首先进入 DOCKER-USER 链，然后直接 RETURN，然后直接进入 DOCKER-ISOLATION-STAGE-1 链，第一条不满足，第二条直接 RETURN，第三条在上一个情况进行了描述，如果不满足，进入第四条，也不满足，看第五条-A FORWARD -i docker0 -o docker0 -j ACCEPT，满足，执行动作ACCEPT，因此容器内访问容器内畅通无阻

