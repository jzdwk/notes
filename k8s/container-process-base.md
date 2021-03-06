# container - process 等概念

## container

核心技术：
1.	chroot 系统调用将子目录变成根目录，达到**视图级别**的隔离
2.	namespace 技术来实现进程在资源的视图上进行隔离。
3.	进程所使用的还是同一个操作系统的资源，一些进程可能会侵蚀掉整个系统的资源。为了减少进程彼此之间的影响，可以通过 cgroup 来限制其资源使用率
4.	cgroup +  chroot + namespace 的帮助下，进程就能够运行在一个独立的环境下

因此： **容器就是一个视图隔离、资源可限制、独立文件系统的进程集合**