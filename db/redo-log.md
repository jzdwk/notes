# redo log

重做日志redo log用来**保证事务的持久性**，由缓冲redo log buffer和redo log file组成，前者是易失的，后者是持久的。redo log是顺序写的，将缓冲写入file需要调用一次**fsync**。另外，用户可以通过`innodb_flush_log_at_trx_commit`来控制redo log落盘策略(0,1,2)。

redo log的详细笔记[参考](redo-log.md)

rego log的其他信息参考： https://zhuanlan.zhihu.com/p/86538338  https://zhuanlan.zhihu.com/p/35355751  https://zhuanlan.zhihu.com/p/161077344