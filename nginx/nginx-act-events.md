# nginx event 
nginx事件学习与epoll模块解析


## nginx event相关结构体

### nginx event

首先看下nginx对事件的结构体定义：
```c
//参考：https://www.cnblogs.com/codestack/p/12141599.html

struct ngx_event_s {
    /*
    事件相关的对象。通常data都是指向ngx_connection_t连接对象,见ngx_get_connection。开启文件异步I/O时，它可能会指向ngx_event_aio_t(ngx_file_aio_init)结构体
     */
    void            *data;  //赋值见ngx_get_connection

    //标志位，为1时表示事件是可写的。通常情况下，它表示对应的TCP连接目前状态是可写的，也就是连接处于可以发送网络包的状态
    unsigned         write:1; //见ngx_get_connection，可写事件ev默认为1  读ev事件应该默认还是0

    //标志位，为1时表示为此事件可以建立新的连接。通常情况下，在ngx_cycle_t中的listening动态数组中，每一个监听对象ngx_listening_t对
    //应的读事件中的accept标志位才会是l  ngx_event_process_init中置1
    unsigned         accept:1;

    /*
    这个标志位用于区分当前事件是否是过期的，它仅仅是给事件驱动模块使用的，而事件消费模块可不用关心。为什么需要这个标志位呢？
    当开始处理一批事件时，处理前面的事件可能会关闭一些连接，而这些连接有可能影响这批事件中还未处理到的后面的事件。这时，
    可通过instance标志位来避免处理后面的已经过期的事件。将详细描述ngx_epoll_module是如何使用instance标志位区分
    过期事件的，这是一个巧妙的设计方法

        instance标志位为什么可以判断事件是否过期？instance标志位的使用其实很简单，它利用了指针的最后一位一定
    是0这一特性。既然最后一位始终都是0，那么不如用来表示instance。这样，在使用ngx_epoll_add_event方法向epoll中添加事件时，就把epoll_event中
    联合成员data的ptr成员指向ngx_connection_t连接的地址，同时把最后一位置为这个事件的instance标志。而在ngx_epoll_process_events方法中取出指向连接的
    ptr地址时，先把最后一位instance取出来，再把ptr还原成正常的地址赋给ngx_connection_t连接。这样，instance究竟放在何处的问题也就解决了。
    那么，过期事件又是怎么回事呢？举个例子，假设epoll_wait -次返回3个事件，在第
        1个事件的处理过程中，由于业务的需要，所以关闭了一个连接，而这个连接恰好对应第3个事件。这样的话，在处理到第3个事件时，这个事件就
    已经是过期辜件了，一旦处理必然出错。既然如此，把关闭的这个连接的fd套接字置为一1能解决问题吗？答案是不能处理所有情况。
        下面先来看看这种貌似不可能发生的场景到底是怎么发生的：假设第3个事件对应的ngx_connection_t连接中的fd套接字原先是50，处理第1个事件
    时把这个连接的套接字关闭了，同时置为一1，并且调用ngx_free_connection将该连接归还给连接池。在ngx_epoll_process_events方法的循环中开始处
    理第2个事件，恰好第2个事件是建立新连接事件，调用ngx_get_connection从连接池中取出的连接非常可能就是刚刚释放的第3个事件对应的连接。由于套
    接字50刚刚被释放，Linux内核非常有可能把刚刚释放的套接字50又分配给新建立的连接。因此，在循环中处理第3个事件时，这个事件就是过期的了！它对应
    的事件是关闭的连接，而不是新建立的连接。
        如何解决这个问题？依靠instance标志位。当调用ngx_get_connection从连接池中获取一个新连接时，instance标志位就会置反
     */
    /* used to detect the stale events in kqueue and epoll */
    unsigned         instance:1; //ngx_get_connection从连接池中获取一个新连接时，instance标志位就会置反  //见ngx_get_connection

    /*
     * the event was passed or would be passed to a kernel;
     * in aio mode - operation was posted.
     */
    /*
    标志位，为1时表示当前事件是活跃的，为0时表示事件是不活跃的。这个状态对应着事件驱动模块处理方式的不同。例如，在添加事件、
    删除事件和处理事件时，active标志位的不同都会对应着不同的处理方式。在使用事件时，一般不会直接改变active标志位
     */  //ngx_epoll_add_event中也会置1  在调用该函数后，该值一直为1，除非调用ngx_epoll_del_event
    unsigned         active:1; //标记是否已经添加到事件驱动中，避免重复添加  在server端accept成功后，
    //或者在client端connect的时候把active置1，见ngx_epoll_add_connection。第一次添加epoll_ctl为EPOLL_CTL_ADD,如果再次添加发
    //现active为1,则epoll_ctl为EPOLL_CTL_MOD

    /*
    标志位，为1时表示禁用事件，仅在kqueue或者rtsig事件驱动模块中有效，而对于epoll事件驱动模块则无意义，这里不再详述
     */
    unsigned         disabled:1;

    /* the ready event; in aio mode 0 means that no operation can be posted */
    /*
    标志位，为1时表示当前事件已经淮备就绪，也就是说，允许这个事件的消费模块处理这个事件。在
    HTTP框架中，经常会检查事件的ready标志位以确定是否可以接收请求或者发送响应
    ready标志位，如果为1，则表示在与客户端的TCP连接上可以发送数据；如果为0，则表示暂不可发送数据。
     */ //如果来自对端的数据内核缓冲区没有数据(返回NGX_EAGAIN)，或者连接断开置0，见ngx_unix_recv
     //在发送数据的时候，ngx_unix_send中的时候，如果希望发送1000字节，但是实际上send只返回了500字节(说明内核协议栈缓冲区满，需要通过epoll再次促发write的时候才能写)，或者链接异常，则把ready置0
    unsigned         ready:1; //在ngx_epoll_process_events中置1,读事件触发并读取数据后ngx_unix_recv中置0

    /*
    该标志位仅对kqueue，eventport等模块有意义，而对于Linux上的epoll事件驱动模块则是无意叉的，限于篇幅，不再详细说明
     */
    unsigned         oneshot:1;

    /* aio operation is complete */
    //aio on | thread_pool方式下，如果读取数据完成，则在ngx_epoll_eventfd_handler(aio on)或者ngx_thread_pool_handler(aio thread_pool)中置1
    unsigned         complete:1; //表示读取数据完成，通过epoll机制返回获取 ，见ngx_epoll_eventfd_handler

    //标志位，为1时表示当前处理的字符流已经结束  例如内核缓冲区没有数据，你去读，则会返回0
    unsigned         eof:1; //见ngx_unix_recv
    //标志位，为1时表示事件在处理过程中出现错误
    unsigned         error:1;

    //标志位，为1时表示这个事件已经超时，用以提示事件的消费模块做超时处理
    /*读客户端连接的数据，在ngx_http_init_connection(ngx_connection_t *c)中的ngx_add_timer(rev, c->listening->post_accept_timeout)把读事件添加到定时器中，如果超时则置1
      每次ngx_unix_recv把内核数据读取完毕后，在重新启动add epoll，等待新的数据到来，同时会启动定时器ngx_add_timer(rev, c->listening->post_accept_timeout);
      如果在post_accept_timeout这么长事件内没有数据到来则超时，开始处理关闭TCP流程*/

    /*
    读超时是指的读取对端数据的超时时间，写超时指的是当数据包很大的时候，write返回NGX_AGAIN，则会添加write定时器，从而判断是否超时，如果发往
    对端数据长度小，则一般write直接返回成功，则不会添加write超时定时器，也就不会有write超时，写定时器参考函数ngx_http_upstream_send_request
     */
    unsigned         timedout:1; //定时器超时标记，见ngx_event_expire_timers
    //标志位，为1时表示这个事件存在于定时器中
    unsigned         timer_set:1; //ngx_event_add_timer ngx_add_timer 中置1   ngx_event_expire_timers置0

    //标志位，delayed为1时表示需要延迟处理这个事件，它仅用于限速功能 
    unsigned         delayed:1; //限速见ngx_http_write_filter  

    /*
     标志位，为1时表示延迟建立TCP连接，也就是说，经过TCP三次握手后并不建立连接，而是要等到真正收到数据包后才会建立TCP连接
     */
    unsigned         deferred_accept:1; //通过listen的时候添加 deferred 参数来确定

    /* the pending eof reported by kqueue, epoll or in aio chain operation */
    //标志位，为1时表示等待字符流结束，它只与kqueue和aio事件驱动机制有关
    //一般在触发EPOLLRDHUP(当对端已经关闭，本端写数据，会引起该事件)的时候，会置1，见ngx_epoll_process_events
    unsigned         pending_eof:1; 

    /*
    if (c->read->posted) { //删除post队列的时候需要检查
        ngx_delete_posted_event(c->read);
    }
     */
    unsigned         posted:1; //表示延迟处理该事件，见ngx_epoll_process_events -> ngx_post_event  标记是否在延迟队列里面
    //标志位，为1时表示当前事件已经关闭，epoll模块没有使用它
    unsigned         closed:1; //ngx_close_connection中置1

    /* to test on worker exit */
    //这两个该标志位目前无实际意义
    unsigned         channel:1;
    unsigned         resolver:1;

    unsigned         cancelable:1;

#if (NGX_WIN32)
    /* setsockopt(SO_UPDATE_ACCEPT_CONTEXT) was successful */
    unsigned         accept_context_updated:1;
#endif

#if (NGX_HAVE_KQUEUE)
    unsigned         kq_vnode:1;

    /* the pending errno reported by kqueue */
    int              kq_errno;
#endif

    /*
     * kqueue only:
     *   accept:     number of sockets that wait to be accepted
     *   read:       bytes to read when event is ready
     *               or lowat when event is set with NGX_LOWAT_EVENT flag
     *   write:      available space in buffer when event is ready
     *               or lowat when event is set with NGX_LOWAT_EVENT flag
     *
     * iocp: TODO
     *
     * otherwise:
     *   accept:     1 if accept many, 0 otherwise
     */

//标志住，在epoll事件驱动机制下表示一次尽可能多地建立TCP连接，它与multi_accept配置项对应，实现原理基见9.8.1节
#if (NGX_HAVE_KQUEUE) || (NGX_HAVE_IOCP)
    int              available;
#else
    unsigned         available:1; //ngx_event_accept中  ev->available = ecf->multi_accept;  
#endif
    /*
    每一个事件最核心的部分是handler回调方法，它将由每一个事件消费模块实现，以此决定这个事件究竟如何“消费”
     */

    /*
    1.event可以是普通的epoll读写事件(参考ngx_event_connect_peer->ngx_add_conn或者ngx_add_event)，通过读写事件触发
    
    2.也可以是普通定时器事件(参考ngx_cache_manager_process_handler->ngx_add_timer(ngx_event_add_timer))，通过ngx_process_events_and_timers中的
    epoll_wait返回，可以是读写事件触发返回，也可能是因为没获取到共享锁，从而等待0.5s返回重新获取锁来跟新事件并执行超时事件来跟新事件并且判断定
    时器链表中的超时事件，超时则执行从而指向event的handler，然后进一步指向对应r或者u的->write_event_handler  read_event_handler
    
    3.也可以是利用定时器expirt实现的读写事件(参考ngx_http_set_write_handler->ngx_add_timer(ngx_event_add_timer)),触发过程见2，只是在handler中不会执行write_event_handler  read_event_handler
    */
     
    //这个事件发生时的处理方法，每个事件消费模块都会重新实现它
    //ngx_epoll_process_events中执行accept
    /*
     赋值为ngx_http_process_request_line     ngx_event_process_init中初始化为ngx_event_accept  如果是文件异步i/o，赋值为ngx_epoll_eventfd_handler
     //当accept客户端连接后ngx_http_init_connection中赋值为ngx_http_wait_request_handler来读取客户端数据  
     在解析完客户端发送来的请求的请求行和头部行后，设置handler为ngx_http_request_handler
     */ //一般与客户端的数据读写是 ngx_http_request_handler;  与后端服务器读写为ngx_http_upstream_handler(如fastcgi proxy memcache gwgi等)
    
    /* ngx_event_accept，ngx_http_ssl_handshake ngx_ssl_handshake_handler ngx_http_v2_write_handler ngx_http_v2_read_handler 
    ngx_http_wait_request_handler  ngx_http_request_handler,ngx_http_upstream_handler ngx_file_aio_event_handler */
    ngx_event_handler_pt  handler; //由epoll读写事件在ngx_epoll_process_events触发
   

#if (NGX_HAVE_IOCP)
    ngx_event_ovlp_t ovlp;
#endif
    //由于epoll事件驱动方式不使用index，所以这里不再说明
    ngx_uint_t       index;
    //可用于记录error_log日志的ngx_log_t对象
    ngx_log_t       *log;  //可以记录日志的ngx_log_t对象 其实就是ngx_listening_t中获取的log //赋值见ngx_event_accept
    //定时器节点，用于定时器红黑树中
    ngx_rbtree_node_t   timer; //见ngx_event_timer_rbtree

    /* the posted queue */
    /*
    post事件将会构成一个队列再统一处理，这个队列以next和prev作为链表指针，以此构成一个简易的双向链表，其中next指向后一个事件的地址，
    prev指向前一个事件的地址
     */
    ngx_queue_t      queue;

};
```
这里比较重要的是`handler`回调方法，它决定了该事件如何被“消费”。

### 连接与连接池

在每一个nginx连接中，都描述了读事件与写事件，当作为服务端时，其nginx对于连接(即被动连接)的定义如下：
```c
//参考：https://www.cnblogs.com/codestack/p/12141599.html
struct ngx_connection_s {  
	
	//cycle->read_events和cycle->write_events这两个数组存放的是ngx_event_s,他们是对应的，见ngx_event_process_init
    /*
    连接未使用时，data成员用于充当连接池中空闲连接链表中的next指针(ngx_event_process_init)。当连接被使用时，data的意义由使用它的Nginx模块而定，
    如在HTTP框架中，data指向ngx_http_request_t请求

    在服务器端accept客户端连接成功(ngx_event_accept)后，会通过ngx_get_connection从连接池获取一个ngx_connection_t结构，也就是每个客户端连接对于一个ngx_connection_t结构，
    并且为其分配一个ngx_http_connection_t结构，ngx_connection_t->data = ngx_http_connection_t，见ngx_http_init_connection
     */ 
 
	/*
    在子请求处理过程中，上层父请求r的data指向第一个r下层的子请求，例如第二层的r->connection->data指向其第三层的第一个
	创建的子请求r，c->data = sr见ngx_http_subrequest,在subrequest往客户端发送数据的时候，只有data指向的节点可以先发送出去
    listen过程中，指向原始请求ngx_http_connection_t(ngx_http_init_connection ngx_http_ssl_handshake),接收到客户端数据后指向ngx_http_request_t(ngx_http_wait_request_handler)
    http2协议的过程中，在ngx_http_v2_connection_t(ngx_http_v2_init)
	*/
    void               *data; /* 如果是subrequest，则data最终指向最下层子请求r,见ngx_http_subrequest */
    //如果是文件异步i/o中的ngx_event_aio_t，则它来自ngx_event_aio_t->ngx_event_t(只有读),如果是网络事件中的event,则为ngx_connection_s中的event(包括读和写)
    ngx_event_t        *read;//连接对应的读事件   赋值在ngx_event_process_init，空间是从ngx_cycle_t->read_event池子中获取的
    ngx_event_t        *write; //连接对应的写事件  赋值在ngx_event_process_init 一般在ngx_handle_write_event中添加些事件，空间是从ngx_cycle_t->read_event池子中获取的

    ngx_socket_t        fd;//套接字句柄
    /* 如果启用了ssl,则发送和接收数据在ngx_ssl_recv ngx_ssl_write ngx_ssl_recv_chain ngx_ssl_send_chain */
    //服务端通过ngx_http_wait_request_handler读取数据
    ngx_recv_pt         recv; //直接接收网络字符流的方法  见ngx_event_accept或者ngx_http_upstream_connect   赋值为ngx_os_io  在接收到客户端连接或者向上游服务器发起连接后赋值
    ngx_send_pt         send; //直接发送网络字符流的方法  见ngx_event_accept或者ngx_http_upstream_connect   赋值为ngx_os_io  在接收到客户端连接或者向上游服务器发起连接后赋值

    /* 如果启用了ssl,则发送和接收数据在ngx_ssl_recv ngx_ssl_write ngx_ssl_recv_chain ngx_ssl_send_chain */
    //以ngx_chain_t链表为参数来接收网络字符流的方法  ngx_recv_chain
    ngx_recv_chain_pt   recv_chain;  //赋值见ngx_event_accept     ngx_event_pipe_read_upstream中执行
    //以ngx_chain_t链表为参数来发送网络字符流的方法    ngx_send_chain
    //当http2头部帧发送的时候，会在ngx_http_v2_header_filter把ngx_http_v2_send_chain.send_chain=ngx_http_v2_send_chain
    ngx_send_chain_pt   send_chain; //赋值见ngx_event_accept   ngx_http_write_filter和ngx_chain_writer中执行

    //这个连接对应的ngx_listening_t监听对象,通过listen配置项配置，此连接由listening监听端口的事件建立,赋值在ngx_event_process_init
    //接收到客户端连接后会冲连接池分配一个ngx_connection_s结构，其listening成员指向服务器接受该连接的listen信息结构，见ngx_event_accept
    ngx_listening_t    *listening; //实际上是从cycle->listening.elts中的一个ngx_listening_t   

    off_t               sent;//这个连接上已经发送出去的字节数 //ngx_linux_sendfile_chain和ngx_writev_chain没发送多少字节就加多少字节

    ngx_log_t          *log;//可以记录日志的ngx_log_t对象 其实就是ngx_listening_t中获取的log //赋值见ngx_event_accept

    /*
    内存池。一般在accept -个新连接时，会创建一个内存池，而在这个连接结束时会销毁内存池。注意，这里所说的连接是指成功建立的
    TCP连接，所有的ngx_connection_t结构体都是预分配的。这个内存池的大小将由listening监听对象中的pool_size成员决定
     */
    ngx_pool_t         *pool; //在accept返回成功后创建poll,见ngx_event_accept， 连接上游服务区的时候在ngx_http_upstream_connect创建

    struct sockaddr    *sockaddr; //连接客户端的sockaddr结构体  客户端的，本端的为下面的local_sockaddr 赋值见ngx_event_accept
    socklen_t           socklen; //sockaddr结构体的长度  //赋值见ngx_event_accept
    ngx_str_t           addr_text; //连接客户端字符串形式的IP地址  

    ngx_str_t           proxy_protocol_addr;

#if (NGX_SSL)
    ngx_ssl_connection_t  *ssl; //赋值见ngx_ssl_create_connection
#endif

    //本机的监听端口对应的sockaddr结构体，也就是listening监听对象中的sockaddr成员
    struct sockaddr    *local_sockaddr; //赋值见ngx_event_accept
    socklen_t           local_socklen;

    /*
    用于接收、缓存客户端发来的字符流，每个事件消费模块可自由决定从连接池中分配多大的空间给buffer这个接收缓存字段。
    例如，在HTTP模块中，它的大小决定于client_header_buffer_size配置项
     */
    ngx_buf_t          *buffer; //ngx_http_request_t->header_in指向该缓冲去

    /*
    该字段用来将当前连接以双向链表元素的形式添加到ngx_cycle_t核心结构体的reusable_connections_queue双向链表中，表示可以重用的连接
     */
    ngx_queue_t         queue;

    /*
    连接使用次数。ngx_connection t结构体每次建立一条来自客户端的连接，或者用于主动向后端服务器发起连接时（ngx_peer_connection_t也使用它），
    number都会加l
     */
    ngx_atomic_uint_t   number; //这个应该是记录当前连接是整个连接中的第几个连接，见ngx_event_accept  ngx_event_connect_peer

    ngx_uint_t          requests; //处理的请求次数

    /*
    缓存中的业务类型。任何事件消费模块都可以自定义需要的标志位。这个buffered字段有8位，最多可以同时表示8个不同的业务。第三方模
    块在自定义buffered标志位时注意不要与可能使用的模块定义的标志位冲突。目前openssl模块定义了一个标志位：
        #define NGX_SSL_BUFFERED    Ox01
        
        HTTP官方模块定义了以下标志位：
        #define NGX HTTP_LOWLEVEL_BUFFERED   0xf0
        #define NGX_HTTP_WRITE_BUFFERED       0x10
        #define NGX_HTTP_GZIP_BUFFERED        0x20
        #define NGX_HTTP_SSI_BUFFERED         0x01
        #define NGX_HTTP_SUB_BUFFERED         0x02
        #define NGX_HTTP_COPY_BUFFERED        0x04
        #define NGX_HTTP_IMAGE_BUFFERED       Ox08
    同时，对于HTTP模块而言，buffered的低4位要慎用，在实际发送响应的ngx_http_write_filter_module过滤模块中，低4位标志位为1则惫味着
    Nginx会一直认为有HTTP模块还需要处理这个请求，必须等待HTTP模块将低4位全置为0才会正常结束请求。检查低4位的宏如下：
        #define NGX_LOWLEVEL_BUFFERED  OxOf
     */
    unsigned            buffered:8; //不为0，表示有数据没有发送完毕，ngx_http_request_t->out中还有未发送的报文

    /*
     本连接记录日志时的级别，它占用了3位，取值范围是0-7，但实际上目前只定义了5个值，由ngx_connection_log_error_e枚举表示，如下：
    typedef enum{
        NGXi ERROR—AIERT=0，
        NGX' ERROR ERR,
        NGX  ERROR_INFO，
        NGX, ERROR IGNORE ECONNRESET,
        NGX ERROR—IGNORE EIb:fVAL
     }
     ngx_connection_log_error_e ;
     */
    unsigned            log_error:3;     /* ngx_connection_log_error_e */

    //标志位，为1时表示不期待字符流结束，目前无意义
    unsigned            unexpected_eof:1;

    //每次处理完一个客户端请求后，都会ngx_add_timer(rev, c->listening->post_accept_timeout);
    /*读客户端连接的数据，在ngx_http_init_connection(ngx_connection_t *c)中的ngx_add_timer(rev, c->listening->post_accept_timeout)把读事件添加到定时器中，如果超时则置1
      每次ngx_unix_recv把内核数据读取完毕后，在重新启动add epoll，等待新的数据到来，同时会启动定时器ngx_add_timer(rev, c->listening->post_accept_timeout);
      如果在post_accept_timeout这么长事件内没有数据到来则超时，开始处理关闭TCP流程*/
      //当ngx_event_t->timedout置1的时候，该置也同时会置1，参考ngx_http_process_request_line  ngx_http_process_request_headers
      //在ngx_http_free_request中如果超时则会设置SO_LINGER来减少time_wait状态
    unsigned            timedout:1; //标志位，为1时表示连接已经超时,也就是过了post_accept_timeout多少秒还没有收到客户端的请求
    unsigned            error:1; //标志位，为1时表示连接处理过程中出现错误

    /*
     标志位，为1时表示连接已经销毁。这里的连接指是的TCP连接，而不是ngx_connection t结构体。当destroyed为1时，ngx_connection_t结
     构体仍然存在，但其对应的套接字、内存池等已经不可用
     */
    unsigned            destroyed:1; //ngx_http_close_connection中置1

    unsigned            idle:1; //为1时表示连接处于空闲状态，如keepalive请求中丽次请求之间的状态
    unsigned            reusable:1; //为1时表示连接可重用，它与上面的queue字段是对应使用的
    unsigned            close:1; //为1时表示连接关闭
    /*
        和后端的ngx_connection_t在ngx_event_connect_peer这里置为1，但在ngx_http_upstream_connect中c->sendfile &= r->connection->sendfile;，
        和客户端浏览器的ngx_connextion_t的sendfile需要在ngx_http_update_location_config中判断，因此最终是由是否在configure的时候是否有加
        sendfile选项来决定是置1还是置0
     */
    //赋值见ngx_http_update_location_config
    unsigned            sendfile:1; //标志位，为1时表示正在将文件中的数据发往连接的另一端

    /*
    标志位，如果为1，则表示只有在连接套接字对应的发送缓冲区必须满足最低设置的大小阅值时，事件驱动模块才会分发该事件。这与上文
    介绍过的ngx_handle_write_event方法中的lowat参数是对应的
     */
    unsigned            sndlowat:1; //ngx_send_lowat

    /*
    标志位，表示如何使用TCP的nodelay特性。它的取值范围是下面这个枚举类型ngx_connection_tcp_nodelay_e。
    typedef enum{
    NGX_TCP_NODELAY_UNSET=O,
    NGX_TCP_NODELAY_SET,
    NGX_TCP_NODELAY_DISABLED
    )  ngx_connection_tcp_nodelay_e;
     */
    unsigned            tcp_nodelay:2;   /* ngx_connection_tcp_nodelay_e */ //域套接字默认是disable的,

    /*
    标志位，表示如何使用TCP的nopush特性。它的取值范围是下面这个枚举类型ngx_connection_tcp_nopush_e：
    typedef enum{
    NGX_TCP_NOPUSH_UNSET=0,
    NGX_TCP_NOPUSH_SET,
    NGX_TCP_NOPUSH_DISABLED
    )  ngx_connection_tcp_nopush_e
     */ //域套接字默认是disable的,
    unsigned            tcp_nopush:2;    /* ngx_connection_tcp_nopush_e */

    unsigned            need_last_buf:1;

#if (NGX_HAVE_AIO_SENDFILE || NGX_COMPAT)
    unsigned            busy_count:2;
#endif

#if (NGX_THREADS || NGX_COMPAT)
    ngx_thread_task_t  *sendfile_task;
#endif
};
```

当nginx拉起后，会依次拉起核心模块ngx_events_module与第一个事件模块ngx_event_core_module。在初始化的全局ngx_cycle_t中，存储了连接池对象和事件池对象。事件模块ngx_event_core_module通过执行ngx_event_process_init，遍历要listen的端口，从空闲连接池中获取连接对象，拿到对应连接的读写事件，并添加给具体的事件处理module。

## nginx event 启动

### 核心模块 ngx_events_module

与http模块类似，nginx解析事件时，也是通过core类型模块的ngx_events_module与事件类型模块的ngx_event_core_module配合完成。在初始化时，首先初始化核心模块，其流程与http相同：
```c
ngx_module_t  ngx_events_module = {
    NGX_MODULE_V1,
    &ngx_events_module_ctx,                /* module context */
    ngx_events_commands,                   /* module directives */
    NGX_CORE_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};
//commands中为nginx配置中events{}块的解析
static ngx_command_t  ngx_events_commands[] = {

    { ngx_string("events"),
      NGX_MAIN_CONF|NGX_CONF_BLOCK|NGX_CONF_NOARGS,
      ngx_events_block,
      0,
      0,
      NULL },
      ngx_null_command
};
//ngx_events_block会初始化每一个event类型的模块，首先将会是ngx_event_core_module
static char *
ngx_events_block(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ...
    ngx_event_max_module = ngx_count_modules(cf->cycle, NGX_EVENT_MODULE);
    ctx = ngx_pcalloc(cf->pool, sizeof(void *));
    ...
    *ctx = ngx_pcalloc(cf->pool, ngx_event_max_module * sizeof(void *));
    ...
    *(void **) conf = ctx;
	//调用每个events模块的create_conf，初始化每个模块的存储配置项结构体
    for (i = 0; cf->cycle->modules[i]; i++) {
        if (cf->cycle->modules[i]->type != NGX_EVENT_MODULE) {
            continue;
        }
        m = cf->cycle->modules[i]->ctx;
        if (m->create_conf) {
            (*ctx)[cf->cycle->modules[i]->ctx_index] =
                                                     m->create_conf(cf->cycle);
            if ((*ctx)[cf->cycle->modules[i]->ctx_index] == NULL) {
                return NGX_CONF_ERROR;
            }
        }
    }

    pcf = *cf;
    cf->ctx = ctx;
    cf->module_type = NGX_EVENT_MODULE;
    cf->cmd_type = NGX_EVENT_CONF;
	//为event模块解析nginx.conf配置
    rv = ngx_conf_parse(cf, NULL);
    *cf = pcf;
    ...
	//调用每个events模块的init_conf，完成参数整合
    for (i = 0; cf->cycle->modules[i]; i++) {
        if (cf->cycle->modules[i]->type != NGX_EVENT_MODULE) {
            continue;
        }

        m = cf->cycle->modules[i]->ctx;
        if (m->init_conf) {
            rv = m->init_conf(cf->cycle,
                              (*ctx)[cf->cycle->modules[i]->ctx_index]);
            if (rv != NGX_CONF_OK) {
                return rv;
            }
        }
    }

    return NGX_CONF_OK;
}
```

### 事件模块 ngx_event_core_module

nginx对事件模块的定义如下：
```c
//位于src/event/modules/ngx_event.c，https://blog.csdn.net/m0_46125280/article/details/103885012
typedef struct {
    // 事件模块的名称
    ngx_str_t *name;

    // 在解析配置项前，这个回调方法用于创建存储配置项参数的结构体
    void *(*create_conf)(ngx_cycle_t *cycle);

    // 在解析配置项完成后，init_conf()方法会被调用，用以综合处理当前事件模块感兴趣的全部配置项
    char *(*init_conf)(ngx_cycle_t *cycle, void *conf);

    // 对于事件驱动机制，每个事件模块需要实现的10个抽象方法
    ngx_event_actions_t actions;
} ngx_event_module_t;

typedef struct {
    // 添加事件方法，它负责把一个感兴趣的事件添加到操作系统提供的事件驱动机制（epoll、kqueue等）中，
    // 这样，在事件发生后，将可以在调用下面的process_events时获取这个事件
    ngx_int_t (*add)(ngx_event_t *ev, ngx_int_t event, ngx_uint_t flags);

    // 删除事件方法，它把一个已经存在于事件驱动机制中的事件移除，这样以后即使这个事件发生，
    // 调用process_events()方法时也无法再获取这个事件
    ngx_int_t (*del)(ngx_event_t *ev, ngx_int_t event, ngx_uint_t flags);

    // 启用一个事件，目前事件框架不会调用这个方法，大部分事件驱动模块对于该方法的实现都是
    // 与上面的add()方法完全一致的
    ngx_int_t (*enable)(ngx_event_t *ev, ngx_int_t event, ngx_uint_t flags);

    // 禁用一个事件，目前事件框架不会调用这个方法，大部分事件驱动模块对于该方法的实现都是
    // 与上面的del()方法完全一致的
    ngx_int_t (*disable)(ngx_event_t *ev, ngx_int_t event, ngx_uint_t flags);

    // 向事件驱动机制中添加一个新的连接，这意味着连接上的读写事件都添加到事件驱动机制中了
    ngx_int_t (*add_conn)(ngx_connection_t *c);

    // 从事件驱动机制中移除一个连接的读写事件
    ngx_int_t (*del_conn)(ngx_connection_t *c, ngx_uint_t flags);

    ngx_int_t (*notify)(ngx_event_handler_pt handler);

    // 在正常的工作循环中，将通过调用process_events()方法来处理事件。
    // 这个方法仅在ngx_process_events_and_timers()方法中调用，它是处理、分发事件的核心
    ngx_int_t (*process_events)(ngx_cycle_t *cycle, ngx_msec_t timer, ngx_uint_t flags);

    // 初始化事件驱动模块的方法
    ngx_int_t (*init)(ngx_cycle_t *cycle, ngx_msec_t timer);

    // 退出事件驱动模块前调用的方法
    void (*done)(ngx_cycle_t *cycle);
} ngx_event_actions_t;

```
ngx_event_core_module将会是第一个被执行的事件模块，看下它的定义：
```c
//module 定义，同样的先关注ctx和command
ngx_module_t  ngx_event_core_module = {
    NGX_MODULE_V1,
    &ngx_event_core_module_ctx,            /* module context */
    ngx_event_core_commands,               /* module directives */
    NGX_EVENT_MODULE,                      /* module type */
    NULL,                                  /* init master */
	//以下两个函数重要
    ngx_event_module_init,                //在nginx启动过程中被调用
    ngx_event_process_init,               //在nginx fork出子进程后，每个子进程调用
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};
//ngx_event_module_t类型的ctx定义
static ngx_event_module_t  ngx_event_core_module_ctx = {
    &event_core_name,
    ngx_event_core_create_conf,           //创建ngx_event_conf_t结构体来存储配置，不再展开
    ngx_event_core_init_conf,              /* init configuration */
    { NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL }
};

//command定义，解析配置项，可以看到熟悉的events块中的worker_connections等
static ngx_command_t  ngx_event_core_commands[] = {

    { ngx_string("worker_connections"),
      NGX_EVENT_CONF|NGX_CONF_TAKE1,
      ngx_event_connections,
      0,
      0,
      NULL },

    { ngx_string("use"),
      NGX_EVENT_CONF|NGX_CONF_TAKE1,
      ngx_event_use,
      0,
      0,
      NULL },
      ...
      ngx_null_command
};
```
上述内容比较重要的是`ngx_event_module_t`类型以及其中的actions，由于`ngx_event_core_module_ctx`的主要工作是启动events，所以actions为`{ NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL }`。但是在后续的事件模块中，会实现这些接口，从而完成事件的处理工作。

另外，在ngx_event_core_module中，定义了两个接口`ngx_event_module_init`和`ngx_event_process_init`，其中前者主要是完成了一些全局变量的初始化工作：
```c
//ngx_event.c
//全局变量声明，这里省略
...

static ngx_int_t
ngx_event_module_init(ngx_cycle_t *cycle)
{
    ...
    cf = ngx_get_conf(cycle->conf_ctx, ngx_events_module);
    ecf = (*cf)[ngx_event_core_module.ctx_index];
	...
    ccf = (ngx_core_conf_t *) ngx_get_conf(cycle->conf_ctx, ngx_core_module);
    ngx_timer_resolution = ccf->timer_resolution;
	...
    shm.size = size;
    ngx_str_set(&shm.name, "nginx_shared_zone");
    shm.log = cycle->log;
    if (ngx_shm_alloc(&shm) != NGX_OK) {
        return NGX_ERROR;
    }
    shared = shm.addr;
    ngx_accept_mutex_ptr = (ngx_atomic_t *) shared;
    ngx_accept_mutex.spin = (ngx_uint_t) -1;
    if (ngx_shmtx_create(&ngx_accept_mutex, (ngx_shmtx_sh_t *) shared,
                         cycle->lock_file.data)
        != NGX_OK)
    {
        return NGX_ERROR;
    }
    ngx_connection_counter = (ngx_atomic_t *) (shared + 1 * cl);
    (void) ngx_atomic_cmp_set(ngx_connection_counter, 0, 1);
	...
    ngx_temp_number = (ngx_atomic_t *) (shared + 2 * cl);
    tp = ngx_timeofday();
    ngx_random_number = (tp->msec << 16) + ngx_pid;
    return NGX_OK;
}
```
主要看下`ngx_event_process_init`的实现，它完成了`ngx_event_core_module`在启动过程中的主要工作：
```
static ngx_int_t
ngx_event_process_init(ngx_cycle_t *cycle)
{
    ngx_uint_t           m, i;
    ngx_event_t         *rev, *wev;
    ngx_listening_t     *ls;
    ngx_connection_t    *c, *next, *old;
    ngx_core_conf_t     *ccf;
    ngx_event_conf_t    *ecf;
    ngx_event_module_t  *module;
	//获取ngx_core_module和ngx_event_core_module的配置项结构体
    ccf = (ngx_core_conf_t *) ngx_get_conf(cycle->conf_ctx, ngx_core_module);
    ecf = ngx_event_get_conf(cycle->conf_ctx, ngx_event_core_module);
	//负载均衡锁的标志位设置，负载均衡锁将在后文说明
    if (ccf->master && ccf->worker_processes > 1 && ecf->accept_mutex) {
        ngx_use_accept_mutex = 1;
        ngx_accept_mutex_held = 0;
        ngx_accept_mutex_delay = ecf->accept_mutex_delay;
    } else {
        ngx_use_accept_mutex = 0;
    }

    ...
	//初始化3个事件队列，具体时候后文分析
    ngx_queue_init(&ngx_posted_accept_events);
    ngx_queue_init(&ngx_posted_next_events);
    ngx_queue_init(&ngx_posted_events);	
	//初始化红黑树实现的timer定时器，这里只是init，调用的是ngx_rbtree_init
	//nginx阻塞于epoll_wait时可能被3类事件唤醒，分别是有读写事件发生、等待时间超时和信号中断。
	//等待超时和信号中断都是与定时器实现相关的
    if (ngx_event_timer_init(cycle->log) == NGX_ERROR) {
        return NGX_ERROR;
    }
	//遍历事件模块，拿到use配置项
    for (m = 0; cycle->modules[m]; m++) {
        if (cycle->modules[m]->type != NGX_EVENT_MODULE) {
            continue;
        }
        if (cycle->modules[m]->ctx_index != ecf->use) {
            continue;
        }
        module = cycle->modules[m]->ctx;
		//调用use配置项对应的事件模块，并调用对应的init方法
		//比如 events {   use   epoll; }，则调用了ngx_epoll_module
        if (module->actions.init(cycle, ngx_timer_resolution) != NGX_OK) {
            /* fatal */
            exit(2);
        }
        break;
    }
#if !(NGX_WIN32)

	//当nginx.conf配置指令timer_resolution，用setitimer系统调用设置系统定时器，每当到达时间点后将发生SIGALRM信号，同时epoll_wait的阻塞将被信号中断从而被唤醒执行定时事件。
	//换句话说，配置文件中使用了timer_resolution指令后，epoll_wait将使用信号中断的机制来驱动定时器，否则将使用定时器红黑树的最小时间作为epoll_wait超时时间来驱动定时器。
    if (ngx_timer_resolution && !(ngx_event_flags & NGX_USE_TIMER_EVENT)) {
        struct sigaction  sa;
        struct itimerval  itv;

        ngx_memzero(&sa, sizeof(struct sigaction));
        sa.sa_handler = ngx_timer_signal_handler;
        sigemptyset(&sa.sa_mask);
        if (sigaction(SIGALRM, &sa, NULL) == -1) {
            ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_errno,
                          "sigaction(SIGALRM) failed");
            return NGX_ERROR;
        }
        itv.it_interval.tv_sec = ngx_timer_resolution / 1000;
        itv.it_interval.tv_usec = (ngx_timer_resolution % 1000) * 1000;
        itv.it_value.tv_sec = ngx_timer_resolution / 1000;
        itv.it_value.tv_usec = (ngx_timer_resolution % 1000 ) * 1000;
        if (setitimer(ITIMER_REAL, &itv, NULL) == -1) {
            ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_errno,
                          "setitimer() failed");
        }
    }
    if (ngx_event_flags & NGX_USE_FD_EVENT) {
        struct rlimit  rlmt;

        if (getrlimit(RLIMIT_NOFILE, &rlmt) == -1) {
            ngx_log_error(NGX_LOG_ALERT, cycle->log, ngx_errno,
                          "getrlimit(RLIMIT_NOFILE) failed");
            return NGX_ERROR;
        }

        cycle->files_n = (ngx_uint_t) rlmt.rlim_cur;

        cycle->files = ngx_calloc(sizeof(ngx_connection_t *) * cycle->files_n,
                                  cycle->log);
        if (cycle->files == NULL) {
            return NGX_ERROR;
        }
    }

#else
    //...WIN32不支持定时器，省略
#endif

	//分配连接池、事件池，
	//这里注意，在cycle的数据结构中，既包括了连接池字段，也包括了读写事件池字段。另一方面，一个连接中又同时包含了读写事件。
	/*
		struct ngx_cycle_s {
			...
			ngx_connection_t         *connections;
			ngx_event_t              *read_events;
			ngx_event_t              *write_events;
			...
		}	
		
		struct ngx_connection_s {
			void               *data;
			ngx_event_t        *read;
			ngx_event_t        *write;
			...
		}
	*/
	//因此，cycle中，将通过数组下标予以对应。比如下标为1的connection中，它的读写事件分别对应到了数组cycle->read_events、cycle->write_events中下标为1的事件
	//1. 分配一个数组作为连接池
    cycle->connections =
        ngx_alloc(sizeof(ngx_connection_t) * cycle->connection_n, cycle->log);
    ...
    c = cycle->connections;
	//2. 分配一个数组作为读事件池
    cycle->read_events = ngx_alloc(sizeof(ngx_event_t) * cycle->connection_n,
                                   cycle->log);
    ...
    rev = cycle->read_events;
    for (i = 0; i < cycle->connection_n; i++) {
        rev[i].closed = 1;
        rev[i].instance = 1;
    }
	//3. 分配一个数组作为写事件池
    cycle->write_events = ngx_alloc(sizeof(ngx_event_t) * cycle->connection_n,
                                    cycle->log);
    ...
    wev = cycle->write_events;
    for (i = 0; i < cycle->connection_n; i++) {
        wev[i].closed = 1;
    }
    i = cycle->connection_n;
    next = NULL;
	//使用connection的data字段，将connection以链表形式串联
    do {
        i--;
        c[i].data = next;
        c[i].read = &cycle->read_events[i];
        c[i].write = &cycle->write_events[i];
        c[i].fd = (ngx_socket_t) -1;
        next = &c[i];
    } while (i);
	
	//空闲连接池指向连接池数组第一个元素
    cycle->free_connections = next;
    cycle->free_connection_n = cycle->connection_n;

    /* for each listening socket */
	//遍历所有的监听对象，为每一个监听对象的connection成员分配连接，设置读事件处理方法为ngx_event_accept
    ls = cycle->listening.elts;
    for (i = 0; i < cycle->listening.nelts; i++) {

#if (NGX_HAVE_REUSEPORT)
        if (ls[i].reuseport && ls[i].worker != ngx_worker) {
            continue;
        }
#endif
		//具体实现上，会从cycle->free_connections中获取一个空闲连接
        c = ngx_get_connection(ls[i].fd, cycle->log);
        ...
        c->type = ls[i].type;
        c->log = &ls[i].log;

        c->listening = &ls[i];
        ls[i].connection = c;
        rev = c->read;
        rev->log = c->log;
        rev->accept = 1;
#if (NGX_HAVE_DEFERRED_ACCEPT)
        rev->deferred_accept = ls[i].deferred_accept;
#endif

        if (!(ngx_event_flags & NGX_USE_IOCP_EVENT)) {
            if (ls[i].previous) {

                /*
                 * delete the old accept events that were bound to
                 * the old cycle read events array
                 */

                old = ls[i].previous->connection;

                if (ngx_del_event(old->read, NGX_READ_EVENT, NGX_CLOSE_EVENT)
                    == NGX_ERROR)
                {
                    return NGX_ERROR;
                }
                old->fd = (ngx_socket_t) -1;
            }
        }

//...WIN32处理，省略
#else
		//重要，定义事件的handler为ngx_event_accept
        rev->handler = (c->type == SOCK_STREAM) ? ngx_event_accept
                                                : ngx_event_recvmsg;
#if (NGX_HAVE_REUSEPORT)

        if (ls[i].reuseport) {
            if (ngx_add_event(rev, NGX_READ_EVENT, 0) == NGX_ERROR) {
                return NGX_ERROR;
            }
            continue;
        }
#endif
        if (ngx_use_accept_mutex) {
            continue;
        }

#if (NGX_HAVE_EPOLLEXCLUSIVE)
        if ((ngx_event_flags & NGX_USE_EPOLL_EVENT)
            && ccf->worker_processes > 1)
        {
            if (ngx_add_event(rev, NGX_READ_EVENT, NGX_EXCLUSIVE_EVENT)
                == NGX_ERROR)
            {
                return NGX_ERROR;
            }

            continue;
        }
#endif
		//#define ngx_add_event        ngx_event_actions.add
		//执行actions中的add操作，将读事件添加到事件驱动模块
        if (ngx_add_event(rev, NGX_READ_EVENT, 0) == NGX_ERROR) {
            return NGX_ERROR;
        }
#endif
    }
    return NGX_OK;
}
```


