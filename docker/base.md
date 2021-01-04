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

netfilter/iptables(iptables是Linux管理工具，位于/sbin/iptables。实现功能的是netfilter，它是Linux内核中实现包过滤的内部结构)是Linux平台下的包过滤防火墙，它通过配置**规则**，完成封包过滤、封包重定向和网络地址转换（NAT）等功能。实现上，通过**表和链**来完成具体功能。

- **表（tables）**提供特定的功能，iptables内置了**4个表，即filter表、nat表、mangle表和raw表**，分别用于实现包过滤，网络地址转换、包重构(修改)和数据跟踪处理。具体的划分如下：

1. filter表，**较为常用**，作用：过滤数据包  内核模块：iptables_filter.
2. Nat表，**较为常用**，作用：用于网络地址转换（IP、端口） 内核模块：iptable_nat
3. Mangle表，作用：修改数据包的服务类型、TTL、并且可以配置路由实现QOS  内核模块：iptable_mangle
4. Raw表，作用：决定数据包是否被状态跟踪机制处理  内核模块：iptable_raw

表的优先顺序为：**raw-->mangle-->nat-->filter**

- **链（chains）**是数据包传播的路径，每一条链其实就是众多规则中的一个检查清单，每一条链中可以有一 条或数条规则。当一个数据包到达一个链时，iptables就会从链中第一条规则开始检查，看该数据包是否满足规则所定义的条件。如果满足，系统就会根据 该条规则所定义的方法处理该数据包；否则iptables将继续检查下一条规则，如果该数据包不符合链中任一条规则，iptables就会根据该链预先定义的默认策略来处理数据包。**链**的种类分为了：

1. INPUT——进来的数据包应用此规则链中的策略
2. OUTPUT——外出的数据包应用此规则链中的策略
3. FORWARD——转发数据包时应用此规则链中的策略
4. PREROUTING——对数据包作路由选择前应用此链中的规则，**所有的数据包进来的时侯都先由这个链处理**
5. POSTROUTING——对数据包作路由选择后应用此链中的规则，**所有的数据包出来的时侯都先由这个链处理**

- **链和表**的关系

表描述了实现功能模块上的划分，链描述了对数据包的处理时机。

这样设计的原因在于：**对于一个数据包的处理，有两个维度需要考虑，一个是如何处理，另一个是处理时机。如何处理的逻辑即为包过滤、重构等，处理时机则分为了路由前/后等。**因此，在对一个数据包的整体处理上，遵循**先表后链**的原则，因此会有。

可见图[!tables&chains](../images/docker/base-table-chain.png)

基本步骤如下： 

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

在理解这个规则之前，先梳理SNAT（Source Network Address Translation，源地址转换）,SNAT在数据包流出这台机器之前的最后一个链，也就是POSTROUTING链来，进行操作。比如：
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













```