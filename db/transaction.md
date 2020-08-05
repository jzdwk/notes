# transaction 
项目中需要使用分布式事务，借此对事务、锁、分布式事务方案、知名开源项目进行分析和总结。因为不同的DB对于事务/锁的实现方式不同。在此仅总结Mysql InnoDB的实现。
## base


## latch

## lock

DB使用锁，是为了支持对共享资源的并发访问，提供数据的**完整性**和**一致性**。

InnoDB实现了2个标准的**行级锁**：
1. 共享锁 S Lock：可并发读，阻塞其他事务的写
2. 排他锁 X Lock: 只可单条写，阻塞其他事务的读、写

### 意向锁

以上是针对单行数据的，另外由于InnoDB支持**多粒度锁定**，也就是说，对于一张表，表上可以有表锁（比如drop table时添加），也可以有上段中的行锁。所以，为了*优化加锁*操作，提出了**意向锁**， 即，要向某条数据加锁（S/X），先要在其上层资源添加（IS/IX），意向锁为**表级别的锁，和表锁同级**：
1. 意向共享锁IS Lock：事务向获取一张表中的某行共享锁
2. 意向共享锁IX Lock：事务向获取一张表中的某行共享锁

IS/IX/S/X之间的兼容性自行百度。总结来说：
1. IX，IS是表级锁，不会和行级的X，S锁发生冲突。只会和表级的X，S发生冲突。
2. 行级别的X和S按照普通的共享、排他规则即可。

**存在的意义**：

1. 在mysql中有表锁: LOCK TABLE my_tabl_name READ; 用读锁锁表，会阻塞其他事务修改表数据/LOCK TABLE my_table_name WRITe; 用写锁锁表，会阻塞其他事务读和写.
2. Innodb引擎又支持行锁
3. 锁共存时，事务A锁住了表中的一行，让这一行只能读，不能写。之后，事务B申请整个表的写锁。如果事务B申请成功，那么理论上它就能修改表中的任意一行，这与A持有的行锁是冲突的。数据库需要避免这种冲突，就是说要让B的申请被阻塞，直到A释放了行锁。**数据库要怎么判断这个冲突呢？**

步骤一：判断表是否已被其他事务用表锁锁表（表锁检测）
步骤二：判断表中的每一行是否已被行锁锁住。*这样的判断方法效率实在不高，因为需要遍历整个表。于是就有了意向锁，即优化加锁操作*在意向锁存在的情况下，事务A必须先申请表的意向共享锁，成功后再申请一行的行锁。在意向锁存在的情况下，上面的判断可以改成step1：不变step2：发现表上有意向共享锁，说明表中有些行被共享行锁锁住了，因此，事务B申请表的写锁会被阻塞。

### 锁相关命令

1. `SHOW ENGINE INNODB STATUS` 查看存储引擎状态
2. `SELECT * FROM INFORMATION_SCHEMA.INNODB_TRX;` 查看事务状态
3. `SELECT * FROM INFORMATION_SCHEMA.INNODB_LOCKS;` 查看锁状态
4. `SELECT * FROM INFORMATION_SCHEMA.INNODB_LOCK_WAITS;` 查看阻塞的事务和相关锁信息

### 一致性非锁定读

**行为**：如果读取的数据正在执行DELETE/UPDATE这种需要X LOCK 行锁资源的操作，如果使用一致性非锁定读，那么读操作不会等待X LOCK的释放。而是去读该行的一个**快照**。

**目的**：可以极大提高数据库并发性。

**实现**：InnoDB通过**多版本并发控制（MVCC）**实现。快照数据是当前行数据的一个历史版本，并且每行记录可以有不止一个快照。另外，这个快照由**回滚段(undo,回忆db引擎的表/段/区/页/行)**去实现，因此，快照数据本身没有开销。

在RC以及RR（默认）的事务隔离级别下，InnoDB使用非锁定的一致性读。而这两种级别对应的读快照的行为不同：

1. RC下，总是读取最新的一份快照，这样，在另一个事务提交数据后，因为最新的快照是另一个事务更新后的，所以会读到。因此RC叫做读已提交。

2. RR下，总是读取此事务开始时的数据，此时，在另一个事务提交数据后，因为要读的快照是本次事务开始时的，所以不会读到另一个事务提交后的数据。因此RR叫做可重复读。*因此，RR通过MVCC解决了读场景下的幻读问题，但是没有解决写场景的幻读*

**注意**：mysql默认的隔离级别是RR,但是大多数互联网项目设置的隔离级别为RC，[原因](https://zhuanlan.zhihu.com/p/59061106)：

1. 最重要的，mysql主从复制的bug，binlog的statement模式

2. 效率问题

### 一致性锁定读

一致性非锁定读和一致性锁定读都是针对读场景，当用户在读场景下需要通过加锁来保证数据的一致性时(比如防止丢失更新)，使用：

1. SELECT ... FOR UPDATE: 对读取的行增加一个X LOCK

2. SELECT ... LOCK IN SHARE MODE: 对读取的行增加一个S LOCK

### 外键和锁

外键主要用于引用完整性的约束检查。对于外键的插入和更新，*首选要查询父表中的记录*，而InnoDB对于父表的SELECT，不使用*一致性非锁定读*（因为读的是快照，会产生数据不一致），而是使用**SELECT...LOCK IN SHARE MODE**.

另外，生产环境不推荐使用外键，[参考](https://zhuanlan.zhihu.com/p/62020571)

### 锁种类（算法）

1. **Record Lock**: 单条记录上的锁，**本质上锁住的是索引记录，即聚簇索引**，当表没有主键，InnoDB自己创建一个隐藏列。

2. **Gap Lock**: 间隙锁，不包含记录本身

3. **Next-Key Lock**: = Gap Lock+Record Lock, 锁定一个范围，范围的整体值为（小于查询条件的最接近值，查询条件],(查询条件，大于查询条件的最接近值)。**在RR隔离级别，InnoDB对于行的查询都采用该算法**，该算法用于解决**幻读**问题。

**Next-Key Lock**应用于**RR隔离级别**，对于查询加锁的场景（即对于查询语句使用FOR UPDATE加X锁，或LOCK IN SHARE MODE加X锁），假设表设计如下：
|id(主键)|b(索引)|c(常规列)|
|--|--|--|
|1|1|1|
|5|3|4|
|10|5|7|

有以下几种情况：

1. 当查询的索引含有**唯一**属性（**既包括唯一索引，也包括主键聚簇索引**），对于

SessionA:SELECT ...FROM t WHERE id = 4 FOR UPDATE；

SessionB:INSERT INTO t SELECT 3,2,1；

SessionB将阻塞，原因在于SessionA中，id=4将锁id（1,5）这个范围。而SessionB要插入的id=3，因此阻塞。

2. 当查询的索引含有唯一属性，对于

SessionA:SELECT ...FROM t WHERE id = 5 FOR UPDATE；

SessionB:INSERT INTO t SELECT 3,2,1；

SessionB不会阻塞，原因在于InnoDB对**Next-Key Lock**进行优化，降级为**Record Lock**。 正常要锁（1，5）这个范围，但是降级后，只锁id=5的行，因此不会阻塞。

3. 当查询的是辅助索引，比如id = 5的行有b=3的列，b为辅助索引，

此时，针对SessionA : SELECT ... FROM t WHERE b = 3 FOR UPDATE;

**对于聚簇索引，即对id=5将加Record Lock,对于辅助索引，加上的是Nexy-Key Lock,即（1,3],(3,5)**,因此，以下语句都会阻塞：

SessionB:

SELECT ... FROM t WHERE id = 5 LOCK IN SHARE MODE; 此语句因为 id = 5的行被加X LOCK，所以再查询时加S LOCK将阻塞。

INSERT INTO t SELECT 4,2,1;  此语句将阻塞，因为SessionA根据Nexy-Key Lock锁定了（1,3],(3,5)这个范围，因此b=2的插入将阻塞。

INSERT INTO t SELECT 6,5,1;  同上

INSERT INTO t SELECT 7,0,1； 此语句不会阻塞，因为不在Session锁定的范围。

4. 当查询的是没有索引的普通列，由于查询时要遍历整个表，所以**会对整个表进行加锁**，因此，Session任何的insert都对被阻塞：

SessionA:SELECT ...FROM t WHERE c = 4 FOR UPDATE；

SessionB:INSERT INTO t SELECT 6,5,11; 阻塞，因为所有范围都上了X LOCK；


**注意**：**锁范围**都是**RR隔离级别**的行为，在**RC隔离级别**下，只会加行锁，即如果where条件匹配，就对该行加锁（具体加S/X锁看语句中的写法，FOR UPDATE、LOCK IN SHARE MODE）,没有匹配的就不加锁，对于范围查找（id<10）也是如此。

### 关联查询的锁

关联查询的加锁策略同单表相同，只是会在多表上加锁。假设有以下两张表
- test:
|id(主键)|b(索引)|c(常规列)|
|--|--|--|
|1|1|1|
|5|3|2|
|10|5|3|

- test2:
|id(主键)|b2(索引)|c2(常规列)|
|--|--|--|
|1|1|10|
|5|3|30|

**RC隔离级别**

SessionA: SELECT test2.c2 from test2 inner join test on test2.b2 = test.b where test.id = 1;

SessionB: UPDATE test set test.c = 9 where test.id =1 将阻塞，因为SessionA的关联查询条件匹配了test和test2中id=1的行，**RC下只在匹配行上加锁**，故阻塞。同理，UPDATE test2的id=1的行也会阻塞。

SessionA:  SELECT test2.c2 from test2 inner join test on test2.b2 = test.b where test.c = 1;

SessionB: UPDATE test set test.c = 9 where test.id =1 将阻塞，**因为查询条件上没有索引，因此会进行全表扫描，此时，将锁住test和test2的所有行**。

**RR隔离级别**

RR级别的加锁行为和RC类似，根据**查询条件确定加锁的范围**，如果查询条件是:

1. 唯一/聚簇索引

SessionA: SELECT test2.c2 from test2 inner join test on test2.b2 = test.b where test.id = 1;

SessionB: UPDATE test set test.c = 9 where test.id =1 将阻塞，理由同RC的场景，但INSERT INTO test SELECT 2,2,2不阻塞，因为**Next-Key Lock**降级为**Record**

2. 辅助索引

SessionA: SELECT test2.c2 from test2 inner join test on test2.b2 = test.b where test.b = 3;

SessionB: INSERT INTO test SELECT 2,2,2将阻塞，同样阻塞的还有INSERT INTO test2 SELECT 2,2,2，因为**Next-Key Lock**分别对b=3的记录加上了间隙锁。

3. 无索引的查询

SessionA: SELECT test2.c2 from test2 inner join test on test2.b2 = test.b where test.c = 2;

SessionB: 此时的加锁策略为**查询条件如果为test表，则加锁test上所有行和间隙，对test表的所有操作将阻塞，但只对关联匹配的test2的对应行上加锁**

### 其他

**延伸**：考虑为什么查询列要加索引？答：1、减少IO 2、全表查锁表，索引覆盖查只锁一个范围。

**另外**：InnoDB没有锁升级的概念（行锁->页锁->表锁），而是根据事务访问的页，采用位图方式管理锁。

**一些文章**： 加锁详解 https://www.cnblogs.com/crazylqy/p/7611069.html 关联查询讨论 https://www.zhihu.com/question/68258877
