# docker image 管理

主要记录docker 的 Image设计以及代码分析

## 概念

### rootfs

全称是root file system，这是一个linux系统中的根文件系统 一个典型的Linux系统要能运行的话，它至少需要两个文件系统：

- boot file system （bootfs）：包含bootloader和 kernel。用户不会修改这个文件系统。在boot过程完成后，整个内核都会被加载进内存，此时bootfs 会被卸载掉从而释放出所占用的内存。对于同样内核版本的不同的Linux发行版的bootfs都是一致的。

- root file system （rootfs）：包含典型的目录结构，包括dev,proc,bin,etc,lib,usr,tmp 等再加上要运行用户应用所需要的所有配置文件，二进制文件和库文件。这个文件系统在不同的Linux 发行版中是不同的。而且用户可以对这个文件进行修改。

Linux操作系统内核启动时，内核首先会挂载一个只读( read-only)的rootfs，
当系统检测其完整性之后，决定是否将其切换为读写( read-write) 模式，或者最后在rootfs
之上另行挂载一种文件系统并忽略rootfs。

Docker架构下依然沿用Linux 中rootfs的思想。
当Docker Daemon为Docker容器挂载rootfs的时候，与传统Linux内核类似，将其设定为只
读模式。不同的是，docker在挂载rootfs之后，**并没有将docker容器的文件系统设为读写模式**，而是利用**Union Mount** 的技术，**在这个只读的rootfs之上再
挂载一个读写的文件系统**，挂载时该读写文件系统内空无一物。

### unionfs

全称是union file system， 代表一种文件系统挂载方式，允许同一时刻多种文件系统叠加挂载在一起，
并以一种文件系统的形式，呈现多种文件系统内容合并后的目录。举个例子：

```
$ tree
.
├── fruits
│   ├── apple
│   └── tomato
└── vegetables
    ├── carrots
    └── tomato
```

上面的目录结构，经过union mount：

```
$ sudo mount -t aufs -o dirs=./fruits:./vegetables none ./mnt
$ tree ./mnt
./mnt
├── apple
├── carrots
└── tomato
```

通常来讲，被合并的文件系统中只有一个会以读写(read-write)模式挂载，其他文件系统的挂载模式均
为只读( read-only)。实现这种Union Mount技术的文件系统一般称为联合文件系统(Union
Filesystem)，较为常见的有UnionFS、aufs 、OverlayFS 等

基于此，docker在所创建的容器中使用文件系统时，从内核角度来看，将出现rootfs以及一个可读写的文件系统，并通过union mount进行合并。所有的配置、install都是在读写层进行的，即使是删除操作，也是在读写层进行，只读层永远不会变。对于用户来说，感知不到这两个层次，只会通过fs的COW (copy-on-write)特性看到操作结果。

### image

最为简单地解释image,它就是Docker容器中只读文件系统rootfs的一部分。Docker容器的rootfs可以由多个image 来构成。多个image构成 rootfs的方式依然沿用Union Mount技术。下例为镜像层次从上至下：

- image_n: /lib /etc
- image_2：/media /opt /home
- image_1：/var /boot /proc

比如上面的例子，rootfs被分成了n层，每一层包含其中的一部分，每一层的image都叠加在另一个image之上。基于以上概念，docker iamge产生两种概念:

- 父镜像：其余镜像都依赖于其底下的一个或多个镜像，Docker将下一层的镜像称为上一层镜像的父镜像。如image_1是image_2的父镜像。

- 基础镜像： rootfs最底层镜像，没有父镜像，如image_1。

将一个整体的image拆分，就能够对子image进行复用，比如一个mysql和一个ubuntu的应用，复用的例子就如下：

- image_0-> image_1-> image_3->image_4（ubuntu）->image_5(mysql)

需要注意，以上描述的多个image分层，都是**只读分层**

### layer

除了只读的image之外，Docker Daemon在创建容器时会在容器的rootfs之上，再挂载
一层读写文件系统，而这一层文件系统也称为容器的一个layer ，常被称为 top layer， Docker还会在rootfs和top layer 之间再挂载一个layer ，这一个 layer中主要包含/etc/hosts,/etc/hostname 以及/etc/resolv.conf，一般这一个layer称为init layer。
Docker容器中每一层只读的image 以及最上层可读写的文件系统，均称为layer。**layer的范畴比image多包含了最上层的读写文件系统。**

另外，根据image层次的复用逻辑，docker在设计时，**提供了commit和基于dockerfile的build来将top layer转变为image**。开发者可以基于某个镜像创
建容器做开发工作，并且无论在开发周期的哪个时间点，都可以对容器进行commit,将所
有top layer中的内容打包为一个image ，构成一个新的镜像。

## pull image

Docker Daemon在执行这条命令时，会将Docker Image从Docker Registry下载至本地，并保存在本地Docker Daemon管理的Graph中。从docker daemon的启动过程可以看到，通过initRouter启动了api的handler。因此，可以将其作为入口点分析。下面深入代码，看下pull的详细实现。

### docker client

首先，在docker.go的main函数里，我们看到，docker daemon启动后，会得到标准输入/输出，然后通过cmd去执行std的命令，并将结果返回stdout:
```
	_, stdout, stderr := term.StdStreams()
	...
	cmd, err := newDaemonCommand()
	cmd.SetOutput(stdout)
	if err := cmd.Execute(); err != nil {
		onError(err)
	}
```
其中cmd.Execute则最终调用了cobra库中，cmd结构体生命的RUNE变量，比如：
```
cmd := &cobra.Command{
		Use:           "dockerd [OPTIONS]",
		Short:         "A self-sufficient runtime for containers.",
		SilenceUsage:  true,
		SilenceErrors: true,
		Args:          cli.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.flags = cmd.Flags()
			return runDaemon(opts)
		},
		DisableFlagsInUseLine: true,
		Version:               fmt.Sprintf("%s, build %s", dockerversion.Version, dockerversion.GitCommit),
	}
```