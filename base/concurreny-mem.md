# 内存模型

## CPU

缓存用于解决不同存储之间处理速度不一致的问题。

- CPU缓存：**解决CPU 处理速度和内存处理速度不对等的问题**。
- 内存缓存：解决硬盘访问速度过慢的问题。比如程序中定义的map，过redis等中间件

### CPU Cache工作方式 

1. 复制一份数据到CPU Cache中，当CPU需要用到的时候就可以直接从CPU Cache中读取数据
2. 当运算完成后，再将运算得到的数据写回 Main Memory 中

### 内存缓存不一致性

比如我执行一个 i++ 操作的话，如果两个线程同时执行的话，假设两个线程从CPU Cache中读取的 i=1，两个线程做了 1++ 运算完之后再写回 Main Memory 之后 i=2，而正确结果应该是 i=3。

### 缓存一致性协议

CPU 为了解决内存缓存不一致性问题可以通过制定缓存一致协议，比如[MESI协议](https://zh.wikipedia.org/wiki/MESI%E5%8D%8F%E8%AE%AE)， 或者其他手段来解决。 这个缓存缓存一致性协议指的是在 CPU 高速缓存与主内存交互的时候需要准守的原则和规范。不同的 CPU 中，使用的缓存一致性协议通常也会有所不同。

我们的程序运行在操作系统之上，操作系统屏蔽了底层硬件的操作细节，将各种硬件资源虚拟化。于是，操作系统也就同样需要解决内存缓存不一致性问题。

操作系统通过 内存模型（Memory Model） 定义一系列规范来解决这个问题。无论是 Windows 系统，还是 Linux 系统，它们都有特定的内存模型。

# 重排序

为了提升执行速度/性能，计算机在执行程序代码的时候，会对指令进行重排序。即，系统在执行代码的时候并不一定是按照你写的代码的顺序依次执行。

## 指令重排序

常见的指令重排序包括：
- **编译器优化重排** ：编译器（包括 JVM、JIT 编译器等）在不改变单线程程序语义的前提下，重新安排语句的执行顺序。
- **指令并行重排** ：现代处理器采用了指令级并行技术(Instruction-Level Parallelism，ILP)来将多条指令重叠执行。如果不存在数据依赖性，处理器可以改变语句对应机器指令的执行顺序。
- **内存系统重排**：每个CPU都有自己的缓存，为了提高共享变量的**写**操作，CPU把整个操作变成异步的了，如果写入操作还没来的及同步/通知到其它CPU，就有可能发生其它CPU读取到的是旧的值，因此看起来这条指令还没执行一样。内存重排序实际上并不是真的相关操作被排序了，而是因为CPU引入缓存还没来得及刷新导致

指令重排序**可以保证串行语义一致，但是没有义务保证多线程间的语义也一致**，所以在多线程下，指令重排序可能会导致一些问题。

编译器和处理器的指令重排序的处理方式不一样。对于编译器，通过禁止特定类型的编译器的当时来禁止重排序。对于处理器，通过插入内存屏障（Memory Barrier，或有时叫做内存栅栏，Memory Fence）的方式来禁止特定类型的处理器重排序。指令并行重排和内存系统重排都属于是处理器级别的指令重排序。

内存屏障（Memory Barrier，或有时叫做内存栅栏，Memory Fence）是一种 CPU 指令，用来禁止处理器指令发生重排序（像屏障一样），从而保障指令执行的有序性。另外，为了达到屏障的效果，它也会使处理器写入、读取值之前，将主内存的值写入高速缓存，清空无效队列，从而保障变量的可见性(比如java中的voliate关键字的使用)。

# 总结

综上，因此线程不安全的因素包括了内存模型与重排序。这里要注意，对于单核CPU来说依然有线程安全问题，因为所有线程工作在同一CPU的不同时间片，所以不存在可见性问题，即内存一致性能够保证。但是不能够保证重排序后造成的问题。比如：
```
2个线程读取同一变量a并进行+1操作，一种可能的情况是：
thread 1 read a
thread 2 read a
thread 1 write a+1
thread 2 write a+1
最终，a的结果是1

```

# Java内存模型

Java语言是跨平台的，因此它没有复用操作系统层面的内存模型，而是**自己提供了一套内存模型以屏蔽系统差异**。原因在于，不同的操作系统内存模型不同，如果直接复用，就可能会导致同样一套代码换了一个操作系统就无法执行了。另一方面，JMM 也是Java定义的并发编程相关的一组规范，除了抽象了线程和主内存之间的关系之外，其还规定了从Java源代码到CPU可执行指令的这个转化过程要遵守哪些和并发相关的原则和规范，其主要目的是为了简化多线程编程，增强程序可移植性的。对于Java开发者说，可以不需要了解底层原理，直接使用并发相关的一些关键字和类（比如 volatile、synchronized、各种 Lock）即可开发出并发安全的程序。

## 线程内存

- **主内存** ：所有线程创建的实例对象都存放在主内存中，不管该实例对象是成员变量还是方法中的本地变量(也称局部变量)
- **本地内存** ：也叫工作内存，每个线程都有一个私有的本地内存来存储共享变量的副本，并且，每个线程只能访问自己的本地内存，无法访问其他线程的本地内存。本地内存是 JMM 抽象出来的一个概念，存储了主内存中的共享变量副本。

Java内存模型定义了8种同步操作，来描述主内存与工作内存之间的具体交互协议，即一个变量如何从主内存拷贝到工作内存，如何从工作内存同步到主内存之间的实现细节（了解即可，无需死记硬背）：
1. 锁定（lock）: 作用于主内存中的变量，将他标记为一个线程独享变量。
2. 解锁（unlock）: 作用于主内存中的变量，解除变量的锁定状态，被解除锁定状态的变量才能被其他线程锁定。
3. read（读取）：作用于主内存的变量，它把一个变量的值从主内存传输到线程的工作内存中，以便随后的 load 动作使用。
4. load(载入)：把 read 操作从主内存中得到的变量值放入工作内存的变量的副本中。
5. use(使用)：把工作内存中的一个变量的值传给执行引擎，每当虚拟机遇到一个使用到变量的指令时都会使用该指令。
6. assign（赋值）：作用于工作内存的变量，它把一个从执行引擎接收到的值赋给工作内存的变量，每当虚拟机遇到一个给变量赋值的字节码指令时执行这个操作。
7. store（存储）：作用于工作内存的变量，它把工作内存中一个变量的值传送到主内存中，以便随后的 write 操作使用。
8. write（写入）：作用于主内存的变量，它把 store 操作从工作内存中得到的变量的值放入主内存的变量中。

## happens-before

happens-before是为了**程序员和编译器、处理器之间的平衡**。

程序员追求的是易于理解和编程的*强内存模型*，遵守既定规则编码即可。

编译器和处理器追求的是较少约束的*弱内存模型*，让它们尽己所能地去优化性能，让性能最大化。

happens-before 原则的设计思想其实非常简单：*为了对编译器和处理器的约束尽可能少，只要不改变程序的执行结果（单线程程序和正确执行的多线程程序），编译器和处理器怎么进行重排序优化都行。对于会改变程序执行结果的重排序，JMM 要求编译器和处理器必须禁止这种重排序。*

jmm中happens-before的规则有8条，重点了解下面列举的5条：

1. 程序顺序规则 ：**一个线程内**，按照代码顺序，书写在前面的操作 happens-before 于书写在后面的操作；
2. 解锁规则 ：解锁 happens-before 于加锁；
3. volatile变量规则 ：对一个 volatile 变量的写操作 happens-before 于后面对这个 volatile 变量的读操作。说白了就是对 volatile 变量的写操作的结果对于发生于其后的任何操作都是可见的。
4. 传递规则 ：如果 A happens-before B，且 B happens-before C，那么 A happens-before C；
5. 线程启动规则 ：Thread 对象的 start（）方法 happens-before 于此线程的每一个动作。

如果两个操作不满足上述任意一个 happens-before 规则，那么这两个操作就没有顺序的保障，JVM 可以对这两个操作进行重排序。


举例，如下代码：

```java
# 定义全局变量total
int total = 0

//计算人数总和
int total = getStudentNum()+ total; 	// 1
int total = getTeacherNum() + total;	 // 2
system.out.println(total);	// 3
```

根据上述规则，在同一线程内，根据程序顺序规则，虽然1 happens-before 2，但对1和2进行重排序不会影响代码的执行结果3，所以JMM是允许编译器和处理器执行这种重排序的。但1和2必须是在3执行之前，也就是说1,2 happens-before 3;如果1和2位于不同线程，JMM没有这种情况的happens-before保证，因此需要通过给total修饰volatile，从而满足volatile变量规则。

# golang内存模型

在Golang中的内存模型，定义的是，对多个协程中共享的变量，一个协程中怎样可以看到其它协程的写入。

当多个协程同时操作一个数据时，可以通过**管道、同步原语 (sync 包中的 Mutex 以及 RWMutex)、原子操作 (sync/atomic 包中)。**除此之外，为了保证语义的正确性，Golang 还对一些常见的场景做了语义上的约束。

由于golang的并发基于协程，协程调度基于golang的调度器与依赖线程，因此屏蔽了线程内存的概念，只需关注协程间的共享变量可见性。

## happens-before

同java的appens-before一样，在golang并发编程中也存在该规则。

### 单协程

- 程序顺序： 单协程中，按照代码顺序，书写在前面的操作happens-before于书写在后面的操作；

### 初始化

- 初始化： 如果一个包p引用了一个包q，那么q包的init方法happens-before p包中任何函数的执行(包括init与main)

### 协程创建与销毁

- 协程创建：对于goroutine的创建一定会happens-before  goroutine的执行，举个例子：
```
//在创建协程foobar()一定是在执行foobar之前，因此在foofar中的变量a一定被赋值为"Hello World"
func foobar() {
        fmt.Print(a)
        wg.Done()}
func hello() {
        a = "Hello World\n"
        go foobar()}
func main() {
        wg.Add(1)
        hello()
        wg.Wait()
}
```

- 协程销毁：一个goroutine的销毁操作**并不能确保** happen before程序中的任何事件，必须使用一定的同步机制（如锁、通道），比如下面例子：
```
var a string
//a的赋值并不能确保对外层函数hello可见
func hello() {
    go func() { a = "hello" }()
    print(a)
}
```

### 管道

- 对于有缓冲chan，发送 happens-before 接收，`A send on a channel happens before the corresponding receive from that channel completes`：
```
var (
        c = make(chan int, 10)
        a string
)

func f() {
		//
        a = "Hello World\n"
        c <- 0
}

func main() {
        go f()
        //从c中写入值一定happens-before读取，因此变量a会被赋值
        <-c
        print(a)
}
```
- 关闭 happens-before 接收，且接收返回值为0值：`The closing of a channel happens before a receive that returns a zero value because the channel is closed.`
```
var (
        c = make(chan int, 10)
        a string
)

func f() {
		//
        a = "Hello World\n"
        close(c)
}

func main() {
        go f()
        //关闭chan一定happens-before读取，因此变量a会被赋值
        <-c
        print(a)
}
```
- 对于无缓冲chan，读取操作happens-before写入：`A receive from an unbuffered channel happens before the send on that channel completes`
```
var (
        c = make(chan int)
        a string
)

func f() {
		//更新 a 变量 Happens-Before 从 c 管道接收
        a = "Hello World\n"
		//而接收 Happens-Before发送
        <-c
}
func main() {
        go f()
		//发送 Happens-Before 打印数据
        c <- 0
        print(a)
}
```
- 对于带缓冲chan，当chan容量为c时，接收第n个元素Happens-Before向该chan写入第n+c个元素：`The Nth receive on a channel with capacity C happens before the n+Cth send from that channel completes.`

```
//简单来说，就是首先写c个元素后chan满，此时取一个才能再写一个
var limit = make(chan int, 3)
func sayHello(index int){
    fmt.Println(index )
}
var work []func(int)
func main() {   
    work := append(work,sayHello,sayHello,sayHello,sayHello,sayHello,sayHello)   
    for i, w := range work {
        go func(w func(int),index int) {
            limit <- 1
            w(index)
            <-limit
        }(w,i)
    }
    time.Sleep(time.Second * 10)
}
```

### 锁

- 对于任何互斥锁sync.Mutex或者读写锁sync.RWMutex来说，加锁后必须先解锁，相应的解锁前必须先加锁(否则会报错)。For any sync.Mutex or sync.RWMutex variable l and n < m, call n of l.Unlock() happens before call m of l.Lock() returns.

- 对于读写锁sync.RWMutex来说，释放写锁Unlock()操作happens-before加读锁RLock()，同样，释放读锁RUlock()happens-before加写锁lock()：简单来说，就是读写锁的写锁lock()只能锁定一次，解锁前不能再进行读锁定RLock()或写锁定Lock()；读锁RLock()可以多次，每次读解锁RUlock()时，次数-1。

### Once

- 多个goroutine调用Once时，真正执行Once中函数的goroutince happens-before 其他被阻塞的goroutince: `A single call of f() from once.Do(f) happens (returns) before any call of once.Do(f) returns.`


#总结

内存模型上，java的jmm与真实cpu内存模型相对应，java线程可映射为操作系统线程(取决于jvm，hotspot是这样)；golang为协程调度，因此屏蔽了线程的概念，无需关注线程内存模型。

java与golang的并发都涉及happens-before规则，java通过volitile/synchronized语义、锁等实现规则，golang通过channel,sync包实现规则。

# 参考

1. https://gohalo.me/post/golang-concept-memory-module-introduce.html
2. https://javaguide.cn/java/concurrent/jmm.html