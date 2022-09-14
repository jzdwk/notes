# 池化技术

池化技术的思想主要是为了**减少每次获取资源的消耗，提高对资源的利用率**。线程池、数据库连接池、Http 连接池等等都是对这个思想的应用。

## 线程池

线程池提供了一种限制和管理资源（包括执行一个任务）的方式。 每个线程池还维护一些基本统计信息，例如已完成任务的数量。
使用线程池的好处包括了：

- 降低资源消耗。通过重复利用已创建的线程降低线程创建和销毁造成的消耗。
- 提高响应速度。当任务到达时，任务可以不需要等到线程创建就能立即执行。
- 提高线程的可管理性。线程是稀缺资源，如果无限制的创建，不仅会消耗系统资源，还会降低系统的稳定性，使用线程池可以进行统一的分配，调优和监控。

### Java线程池

这里不做java线程池的使用详解，主要是记录线程的开销以及线程池实现的源码分析。

1. **开销对比**
```java
public class PoolTest {
    private static final int CORE_POOL_SIZE = 5; //线程池的核心线程数量
    private static final int MAX_POOL_SIZE = 10; //线程池的最大线程数，当待执行任务大于核心线程，则会临时增加线程来执行任务，总线程数不大于最大线程数
    private static final int QUEUE_CAPACITY = 10000; //当待执行任务大于最大线程数时，通过任务队列来储存等待执行的任务
    private static final Long KEEP_ALIVE_TIME = 1L; //当线程数大于核心线程数时，多余的空闲线程存活的最长时间

	//开启100个任务，保证所有任务执行完成后才计算endTime
    private final static int num = QUEUE_CAPACITY;
    private static CountDownLatch latch = new CountDownLatch(num);

	//1. 通过线程池创建线程
    public static void poolTest() throws Exception {
        long start = System.currentTimeMillis();
        //ThreadPoolExecutor executor = (ThreadPoolExecutor) Executors.newFixedThreadPool(5);
        ThreadPoolExecutor executor = new ThreadPoolExecutor(CORE_POOL_SIZE,
                MAX_POOL_SIZE,
                KEEP_ALIVE_TIME,
                TimeUnit.SECONDS,
                new ArrayBlockingQueue<Runnable>(QUEUE_CAPACITY),
                new ThreadPoolExecutor.CallerRunsPolicy());

        for (int i = 0; i < num; i++) {
            //创建WorkerThread对象（WorkerThread类实现了Runnable 接口）
            Runnable worker = new MyRunnable(latch);
            //执行Runnable
            executor.execute(worker);
        }
        //终止线程池
        latch.await();
        executor.shutdown();
        long end = System.currentTimeMillis();
        System.out.printf("Finished all threads, time used %d milliseconds \r\n", end - start);
    }
	//2. 直接new Thread创建野线程
    public static void threadTest() throws Exception {
        //new Thread创建线程
        long start = System.currentTimeMillis();
        for (int i = 0; i < num; i++) {
            Thread tmpThread = new Thread(new MyRunnable(latch));
            tmpThread.start();
        }
        latch.await();
        long end = System.currentTimeMillis();
        System.out.printf("Finished all threads, time used %d milliseconds \r\n", end - start);
    }
	//3. 做简单的时间对比
    public static void main(String[] args) throws Exception {
        System.out.println("thread test start");
        threadTest();
        System.out.println("pool test start");
        poolTest();
    }

}

//其输出对比如下：
thread test start
Finished all threads, time used 4190 milliseconds 
pool test start
Finished all threads, time used 28 milliseconds 
```

2. **关键参数**

Java线程池中比较重要的类是**ThreadPoolExecutor**， 其完整的构造函数入参如下:
```java
/**
     * Creates a new {@code ThreadPoolExecutor} with the given initial
     * parameters.
     *
     * @param corePoolSize the number of threads to keep in the pool, even
     *        if they are idle, unless {@code allowCoreThreadTimeOut} is set
     * @param maximumPoolSize the maximum number of threads to allow in the
     *        pool
     * @param keepAliveTime when the number of threads is greater than
     *        the core, this is the maximum time that excess idle threads
     *        will wait for new tasks before terminating.
     * @param unit the time unit for the {@code keepAliveTime} argument
     * @param workQueue the queue to use for holding tasks before they are
     *        executed.  This queue will hold only the {@code Runnable}
     *        tasks submitted by the {@code execute} method.
     * @param threadFactory the factory to use when the executor
     *        creates a new thread
     * @param handler the handler to use when execution is blocked
     *        because the thread bounds and queue capacities are reached
     * @throws IllegalArgumentException if one of the following holds:<br>
     *         {@code corePoolSize < 0}<br>
     *         {@code keepAliveTime < 0}<br>
     *         {@code maximumPoolSize <= 0}<br>
     *         {@code maximumPoolSize < corePoolSize}
     * @throws NullPointerException if {@code workQueue}
     *         or {@code threadFactory} or {@code handler} is null
     */
    public ThreadPoolExecutor(int corePoolSize, //核心线程数线程数定义了最小可以同时运行的线程数量。
                              int maximumPoolSize, //当池中线程数大于corePoolSize，如果还有任务待执行，则继续创建线程至最大线程数maximumPoolSize
                              long keepAliveTime,  //当线程池中的线程数量大于corePoolSize时，如无新任务提交，核心线程外的线程不会立即销毁，而是等待keepAliveTime后被回收销毁
                              TimeUnit unit,//keepAliveTime 参数的时间单位
                              BlockingQueue<Runnable> workQueue, //当新任务来的时候会先判断当前运行的线程数量是否达到核心线程数，如果达到的话，新任务就会被存放在队列中
                              ThreadFactory threadFactory, //创建新线程的工厂
                              RejectedExecutionHandler handler) //拒绝策略，运行的线程数量达到最大线程数量并且队列也已经被放满了任务时被执行
							  {...}
```
其中具体的拒绝策略包括了:
- `ThreadPoolExecutor.AbortPolicy` ：抛出 RejectedExecutionException来拒绝新任务的处理。
- `ThreadPoolExecutor.CallerRunsPolicy`：调用执行自己的线程运行任务，也就是直接在调用execute方法的线程中运行(run)被拒绝的任务，如果执行程序已关闭，则会丢弃该任务。因此这种策略会降低对于新任务提交速度，影响程序的整体性能。如果您的应用程序可以承受此延迟并且你要求任何一个任务请求都要被执行的话，你可以选择这个策略。
- `ThreadPoolExecutor.DiscardPolicy` ：不处理新任务，直接丢弃掉。
- `ThreadPoolExecutor.DiscardOldestPolicy` ： 此策略将丢弃最早的未处理的任务请求。

3. **代码分析**

ThreadPoolExecutor针对线程池一共维护了五种状态，实现上**用高3位表示ThreadPoolExecutor的执行状态，低29位维持线程池线程个数**，具体为：
```java
public class ThreadPoolExecutor extends AbstractExecutorService {
	//使用原子变量标记状态，注意这里不是volatile，因为后者只能保证可见性，不能保证原子性
    private final AtomicInteger ctl = new AtomicInteger(ctlOf(RUNNING, 0));
    
	// Integer.SIZE=32, Integer.SIZE-3=29, COUNT_BITS=29， 用来表示线程池数量的位数是29
    private static final int COUNT_BITS = Integer.SIZE - 3;
    
	// 线程池最大线程数=536870911（2^29-1）,CAPACITY二进制中低29为1，高3位为0，即00011111111111111111111111111111
    private static final int CAPACITY   = (1 << COUNT_BITS) - 1;

    // 线程池有5种runState状态，所以需要3位来表示，即高3位表示ThreadPoolExecutor的执行状态
    // RUNNING=111
    private static final int RUNNING    = -1 << COUNT_BITS;
    // SHUTDOWN=000
    private static final int SHUTDOWN   =  0 << COUNT_BITS;
    // STOP=001
    private static final int STOP       =  1 << COUNT_BITS;
    // TIDYING=010
    private static final int TIDYING    =  2 << COUNT_BITS;
    // TERMINATED=110
    private static final int TERMINATED =  3 << COUNT_BITS;

   
    // 获取高3位的值，即线程池状态
    private static int runStateOf(int c)     { return c & ~CAPACITY; }
    // 获取低29位的值，即线程数量
    private static int workerCountOf(int c)  { return c & CAPACITY; }
	...
```

**这里注意，只有RUNNING状态对应的int值为负数，即RUNNING<SHUTDOWN<STOP<TIDYING<TERMINATED**

核心方法`public void execute(Runnable command){...}`的分析如下，首先整体流程上：
![java thread pool](./java-thread-pool.png)

具体看实现：
```java
public void execute(Runnable command) {
		...
        //执行的流程实际上分为三步：
		
        //1. 获取当前【线程状态-线程数量】信息，即c，workerCountOf取低29位，即线程数量，如果运行的线程小于corePoolSize，以用户给定的Runable对象新开一个线程去执行
        int c = ctl.get();
        if (workerCountOf(c) < corePoolSize) {
            if (addWorker(command, true))
                return;
            c = ctl.get();
        }				
		//2. 如果当前线程数量>=coolPoolSize，则判断线程池状态是否为running，如果为running，则进入阻塞队列workQueue
        if (isRunning(c) && workQueue.offer(command)) {
			//当入队成功后，再次获取ctl，在并发环境下，可能之前获取的ctl状态已经发生改变
			//当然，此处获取也未必是线程池的最新状态(比如在后面的if(xxx)之前状态又发生变化了)，只是尽最大努力判断
            int recheck = ctl.get();
			//如果线程池非running，则回滚
            if (! isRunning(recheck) && remove(command))
				//回滚后执行reject策略
                reject(command);
			//否则，即线程池还在running或者回滚失败，判断当前线程池中线程数，如果==0，则添加一个null的command
            else if (workerCountOf(recheck) == 0)
                addWorker(null, false);
        }
		//3. 如果线程池不为running，或队满无法入队，则调用addWorker
		// 后者会判断当前线程数是否<=maximumPoolSize，如果是，则创建线程
        else if (!addWorker(command, false))
			//否则，执行拒绝策略
            reject(command);
    }

```
其中的addWorker方法实现如下:
```java

    private boolean addWorker(Runnable firstTask, boolean core) {
        retry:
        for (;;) {
			//获取当前的线程池状态
            int c = ctl.get();
            int rs = runStateOf(c);

            // Check if queue empty only if necessary.
			// 约束检查，以下情况返回addWorker添加任务失败：
			// 1. rs >= SHUTDOWN ,即线程池不是RUNNING状态，如果为RUNNING状态，则直接返回失败
			// 2. 子句!(rs == SHUTDOWN &&firstTask == null &&!workQueue.isEmpty())，即3个子条件有一个不满足，则整个语句为true，即添加失败，具体为：
			// 	  2.1 如果rs不等于SHUTDOWN，则不能再添加任务，返回失败
			// 	  2.2 如果rs等于SHUTDOWN，但传入的task不为空，代表线程池已经关闭了还在传任务进来，返回失败
			//    2.3 如果rs等于SHUTDOWN，传入的task为空，且队列是为空，此时就不需要往线程池添加任务了，返回失败
            if (rs >= SHUTDOWN &&
                ! (rs == SHUTDOWN &&
                   firstTask == null &&
                   ! workQueue.isEmpty()))
                return false;
            for (;;) {
				//获取线程池的workerCount数量
                int wc = workerCountOf(c);
				//如果workerCount超出最大值或者大于corePoolSize/maximumPoolSize，返回false
                if (wc >= CAPACITY ||
                    wc >= (core ? corePoolSize : maximumPoolSize))
                    return false;
				//通过CAS操作，使workerCount数量+1，如果成功，跳出循环，回到retry标记
                if (compareAndIncrementWorkerCount(c))
                    break retry;
				//如果CAS操作失败，说明在从ctl.get()到刚才的执行过程中，线程池状态发生改变了，则再次获取线程池的控制状态
                c = ctl.get();  // Re-read ctl
				//如果当前runState不等于刚开始获取的runState，则跳出内层循环，继续外层循环
                if (runStateOf(c) != rs)
                    continue retry;
                // else CAS failed due to workerCount change; retry inner loop
            }
        }
		//通过以上循环，当执行以下语句时，说明线程池数量成功+1
		
		
        boolean workerStarted = false;
        boolean workerAdded = false;
        Worker w = null;
        try {
			//初始化一个当前Runnable对象的worker对象，后者调用factory的newThread()方法创建一个线程，作为自身的成员变量
            w = new Worker(firstTask);
			//获取刚才factory创建的线程
            final Thread t = w.thread;
            if (t != null) {
				//加锁
                final ReentrantLock mainLock = this.mainLock;
                mainLock.lock();
                try {
                    // Recheck while holding lock.
                    // Back out on ThreadFactory failure or if
                    // shut down before lock acquired.
					//获取锁后再次检查，获取线程池runState
                    int rs = runStateOf(ctl.get());
					//当:
					//1. runState小于SHUTDOWN，即为RUNNING状态
					//2. 或者runState等于SHUTDOWN并且firstTask为null时，将worker对象加入集合，并更新集合大小
                    if (rs < SHUTDOWN ||
                        (rs == SHUTDOWN && firstTask == null)) {
						//此时线程还没有启动，如果alive，就报错
                        if (t.isAlive()) // precheck that t is startable
                            throw new IllegalThreadStateException();
                        workers.add(w);
                        int s = workers.size();
                        if (s > largestPoolSize)
                            largestPoolSize = s;
                        workerAdded = true;
                    }
                } finally {
                    mainLock.unlock();
                }
				//如果worker添加成功，启动线程并标记已经启动
                if (workerAdded) {
                    t.start();
                    workerStarted = true;
                }
            }
        } finally {
			//如果worker没有启动成功，执行workerCount-1的操作
            if (! workerStarted)
                addWorkerFailed(w);
        }
		//返回worker是否启动的标记
        return workerStarted;
    }


```




### golang协程池

## DB连接池

## http连接池