# gorm 连接池

golang的持久层框架，比如gorm，beego的orm，其底层都引用了官方sql包的连接池。

思考一个基本的连接池所基本的功能：

1. 从池中获取一个连接，`getConn`
2. 使用完这个连接后，将连接放回池中，`releaseConn`
3. 关闭连接池，同时关闭池中的所有连接，`poolClose`

## 连接池初始化

gorm的初始化执行类似如下代码：
```go
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
initDB(){
	...
	//dataSourceName define
	dataSourceName := fmt.Sprintf("user=%s password=%s dbname=%s host=%s port=%s timezone=%s sslmode=disable",
		dbUser, dbPwd, dbName, dbHost, dbPort, dbTimeZone)
	//Open db	
	db, err := gorm.Open(postgres.Open(dataSourceName), &gorm.Config{
		NamingStrategy: schema.NamingStrategy{SingularTable: true},
	})
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//gorm.Open 	
func Open(dialector Dialector, config *Config) (db *DB, err error) {
	...
	db = &DB{Config: config, clone: 1}
	db.callbacks = initializeCallbacks(db)
	...
	//dialector即调用postgres.Open(dataSourceName)封装的pg配置信息对象，执行初始化
	if config.Dialector != nil {
		err = config.Dialector.Initialize(db)
	}
	preparedStmt := &PreparedStmtDB{
		ConnPool:    db.ConnPool,
		Stmts:       map[string]Stmt{},
		Mux:         &sync.RWMutex{},
		PreparedSQL: make([]string, 0, 100),
	}
	...
	return
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
func (dialector Dialector) Initialize(db *gorm.DB) (err error) {
	// register callbacks
	...
	if dialector.Conn != nil {
		db.ConnPool = dialector.Conn
	} else if dialector.DriverName != "" {
		db.ConnPool, err = sql.Open(dialector.DriverName, dialector.Config.DSN)
	} else {
		//执行此分支，解析dialector
		var config *pgx.ConnConfig
		config, err = pgx.ParseConfig(dialector.Config.DSN)
		...
		//调sql包的OpenDB
		db.ConnPool = stdlib.OpenDB(*config)
	}
	return
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~	
func OpenDB(config pgx.ConnConfig, opts ...OptionOpenDB) *sql.DB {
	c := connector{
		ConnConfig:   config,
		AfterConnect: func(context.Context, *pgx.Conn) error { return nil }, // noop after connect by default
		driver:       pgxDriver,
	}

	for _, opt := range opts {
		opt(&c)
	}
	return sql.OpenDB(c)
}
```
以上逻辑比较清晰，总的来说就是根据dataSource描述，封装为sql的connect对象，调用sql的OpenDB函数，继续看sql.OpenDB：
```go
// OpenDB opens a database using a Connector, allowing drivers to
// bypass a string based data source name.
//
// Most users will open a database via a driver-specific connection
// helper function that returns a *DB. No database drivers are included
// in the Go standard library. See https://golang.org/s/sqldrivers for
// a list of third-party drivers.
//
// OpenDB may just validate its arguments without creating a connection
// to the database. To verify that the data source name is valid, call
// Ping.
//
// The returned DB is safe for concurrent use by multiple goroutines
// and maintains its own pool of idle connections. Thus, the OpenDB
// function should be called just once. It is rarely necessary to
// close a DB.
func OpenDB(c driver.Connector) *DB {
	ctx, cancel := context.WithCancel(context.Background())
	db := &DB{
		connector:    c,	//连接信息
		openerCh:     make(chan struct{}, connectionRequestQueueSize),	//开启新连接的请求channel
		resetterCh:   make(chan *driverConn, 50),
		lastPut:      make(map[*driverConn]string),		
		connRequests: make(map[uint64]chan connRequest), //当连接数超过连接池的最大值时，连接请求将被放入connRequests
		stop:         cancel,
	}
	//两个永真的协程，维护连接池中的连接数量
	//当openerCh中有新消息，说明可以新建连接，调用db.openNewConnection(ctx)
	go db.connectionOpener(ctx)
	//当resetterCh中有新消息，说明可以释放该连接，调用dc.resetSession(ctx)
	go db.connectionResetter(ctx)

	return db
}

// Runs in a separate goroutine, opens new connections when requested.
func (db *DB) connectionOpener(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-db.openerCh:
			db.openNewConnection(ctx)
		}
	}
}

// connectionResetter runs in a separate goroutine to reset connections async
// to exported API.
func (db *DB) connectionResetter(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			close(db.resetterCh)
			for dc := range db.resetterCh {
				dc.Unlock()
			}
			return
		case dc := <-db.resetterCh:
			dc.resetSession(ctx)
		}
	}
}
```
OpenDB中，创建了一个db对象，该对象是全局唯一的，既包括基本的连接信息，也包括了连接池相关的参数，DB的具体定义如下：
```go
// DB is a database handle representing a pool of zero or more
// underlying connections. It's safe for concurrent use by multiple
// goroutines.
//
// The sql package creates and frees connections automatically; it
// also maintains a free pool of idle connections. If the database has
// a concept of per-connection state, such state can be reliably observed
// within a transaction (Tx) or connection (Conn). Once DB.Begin is called, the
// returned Tx is bound to a single connection. Once Commit or
// Rollback is called on the transaction, that transaction's
// connection is returned to DB's idle connection pool. The pool size
// can be controlled with SetMaxIdleConns.
type DB struct {

	// Atomic access only. At top of struct to prevent mis-alignment
	// on 32-bit platforms. Of type time.Duration.
	waitDuration int64 // Total time waited for new connections.
	
	//连接的基本信息
	connector driver.Connector
	// numClosed is an atomic counter which represents a total number of
	// closed connections. Stmt.openStmt checks it before cleaning closed
	// connections in Stmt.css.
	
	//维护连接池中连接操作的容器集合
	numClosed uint64
	mu           sync.Mutex // protects following fields  //一个全局的互斥锁，保证操作db中属性的线程安全
	freeConn     []*driverConn	//用一个切片，而不是channel来保存空闲连接，why？
	connRequests map[uint64]chan connRequest	//连接请求，当连接数大于最大值时写入
	nextRequest  uint64 // Next key to use in connRequests.
	numOpen      int    // number of opened and pending open connections	//已打开的连接数量
	// Used to signal the need for new connections
	// a goroutine running connectionOpener() reads on this chan and
	// maybeOpenNewConnections sends on the chan (one send per needed connection)
	// It is closed during db.Close(). The close tells the connectionOpener
	// goroutine to exit.
	openerCh          chan struct{}
	resetterCh        chan *driverConn
	closed            bool
	dep               map[finalCloser]depSet
	lastPut           map[*driverConn]string // stacktrace of last conn's put; debug only
	
	//以下为连接池基本参数配置
	maxIdle           int                    // zero means defaultMaxIdleConns; negative means 0	
	maxOpen           int                    // <= 0 means unlimited
	maxLifetime       time.Duration          // maximum amount of time a connection may be reused
	cleanerCh         chan struct{}
	waitCount         int64 // Total number of connections waited for.
	maxIdleClosed     int64 // Total number of connections closed due to idle.
	maxLifetimeClosed int64 // Total number of connections closed due to max free limit.

	stop func() // stop cancels the connection opener and the session resetter.
}
```
**需要注意的是，在OpenDB后，并没有真正的创建任何连接**，只是开启了两个协程，通过channel维护池中连接数量。**真正的创建连接操作在具体的query处**

## 连接的创建

以`	tx.callbacks.Query().Execute(tx)`代码为例，gorm的查询最终调用了`processor`中的fns。以Query的为例：
```go
func Query(db *gorm.DB) {
	if db.Error == nil {
		//创建sql
		BuildQuerySQL(db)

		if !db.DryRun && db.Error == nil {
			//调用具体Query逻辑，执行时又分为了db(普通)查询与tx(事务)查询
			rows, err := db.Statement.ConnPool.QueryContext(db.Statement.Context, db.Statement.SQL.String(), db.Statement.Vars...)
			...
			defer rows.Close()
			gorm.Scan(rows, db, false)
		}
	}
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
//以db查询为例，这个查询内部做了2件事，1：获取连接conn 2：将返回值封装，这里只关注1
func (db *PreparedStmtDB) QueryContext(ctx context.Context, query string, args ...interface{}) (rows *sql.Rows, err error) {
	stmt, err := db.prepare(ctx, db.ConnPool, false, query)
	if err == nil {
		rows, err = stmt.QueryContext(ctx, args...)
		...
	}
	return rows, err
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
/ QueryContext executes a prepared query statement with the given arguments
// and returns the query results as a *Rows.
func (s *Stmt) QueryContext(ctx context.Context, args ...interface{}) (*Rows, error) {
	s.closemu.RLock()
	defer s.closemu.RUnlock()

	var rowsi driver.Rows
	strategy := cachedOrNewConn
	for i := 0; i < maxBadConnRetries+1; i++ {
		...
		//获取连接
		dc, releaseConn, ds, err := s.connStmt(ctx, strategy)
		...
		//执行sql并返回数据
		rowsi, err = rowsiFromStatement(ctx, dc.ci, ds, args...)
		//封装返回值
		...
		//释放连接
		releaseConn(err)
		...
	}
	return nil, driver.ErrBadConn
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// connStmt returns a free driver connection on which to execute the
// statement, a function to call to release the connection, and a
// statement bound to that connection.
func (s *Stmt) connStmt(ctx context.Context, strategy connReuseStrategy) (dc *driverConn, releaseConn func(error), ds *driverStmt, err error) {
	//连接池关闭的处理
	...
	// In a transaction or connection, we always use the connection that the
	// stmt was created on.
	if s.cg != nil {
		s.mu.Unlock()
		dc, releaseConn, err = s.cg.grabConn(ctx) // blocks, waiting for the connection.
		if err != nil {
			return
		}
		return dc, releaseConn, s.cgds, nil
	}
	
	s.removeClosedStmtLocked()
	s.mu.Unlock()
	//调用sql的conn
	dc, err = s.db.conn(ctx, strategy)
	...
	s.mu.Lock()
	for _, v := range s.css {
		if v.dc == dc {
			s.mu.Unlock()
			return dc, dc.releaseConn, v.ds, nil
		}
	}
	s.mu.Unlock()
	// No luck; we need to prepare the statement on this connection
	withLock(dc, func() {
		ds, err = s.prepareOnConnLocked(ctx, dc)
	})
	if err != nil {
		dc.releaseConn(err)
		return nil, nil, nil, err
	}
	return dc, dc.releaseConn, ds, nil
}
```
继续进入`conn`函数内部，这里对连接的处理主要分为了3中情况:

1. 连接池中有可用连接，直接返回
2. 连接池已满，需要进行连接请求的缓存操作
3. 连接池不满，但也没有可用连接，此时需要创建新的连接，并入池

```go
// conn returns a newly-opened or cached *driverConn.
func (db *DB) conn(ctx context.Context, strategy connReuseStrategy) (*driverConn, error) {
	//判断是否关闭时，加锁？这里疑问 为何不使用cas原子变量操作？
	db.mu.Lock()
	if db.closed {
		db.mu.Unlock()
		return nil, errDBClosed
	}
	// Check if the context is expired.
	select {
	default:
	case <-ctx.Done():
		db.mu.Unlock()
		return nil, ctx.Err()
	}
	lifetime := db.maxLifetime

	// Prefer a free connection, if possible.
	numFree := len(db.freeConn)
	//1. 如果存在空闲的连接
	if strategy == cachedOrNewConn && numFree > 0 {
		//取出第一个
		conn := db.freeConn[0]
		//切片元素前移
		copy(db.freeConn, db.freeConn[1:])
		db.freeConn = db.freeConn[:numFree-1]
		//设置conn状态
		conn.inUse = true
		db.mu.Unlock()
		//如果连接超时，关闭
		if conn.expired(lifetime) {
			conn.Close()
			return nil, driver.ErrBadConn
		}
		// Lock around reading lastErr to ensure the session resetter finished.
		conn.Lock()
		err := conn.lastErr
		conn.Unlock()
		if err == driver.ErrBadConn {
			conn.Close()
			return nil, driver.ErrBadConn
		}
		//返回连接
		return conn, nil
	}
	//2. 如果请求连接时，连接池中的连接数量已经大于最大值，此时该连接被加入等待队列（connRequest,其实是一个map）
	// Out of free connections or we were asked not to use one. If we're not
	// allowed to open any more connections, make a request and wait.
	if db.maxOpen > 0 && db.numOpen >= db.maxOpen {
		// Make the connRequest channel. It's buffered so that the
		// connectionOpener doesn't block while waiting for the req to be read.
		//创建一个容量为1的channel，作为请求通知，当channle中有值时，说明可以池中有新的连接了，直接返回
		req := make(chan connRequest, 1)
		//生成请求索引
		reqKey := db.nextRequestKeyLocked()
		//放入连接请求map，key为索引，value为channel
		db.connRequests[reqKey] = req
		db.waitCount++
		db.mu.Unlock()
		
		waitStart := time.Now()

		// Timeout the connection request with the context.
		// select执行阻塞调用，当req的
		select {
		case <-ctx.Done():
			//上下文结束时，清空请求map
			// Remove the connection request and ensure no value has been sent
			// on it after removing.
			db.mu.Lock()
			delete(db.connRequests, reqKey)
			db.mu.Unlock()

			atomic.AddInt64(&db.waitDuration, int64(time.Since(waitStart)))
			// 虽然context已经结束，但由于已经在map中添加了连接请求的kv对，所以可能已经执行了连接，因此需要注意归还
			select {
			default:
			case ret, ok := <-req:
				if ok && ret.conn != nil {
					db.putConn(ret.conn, ret.err, false)
				}
			}
			return nil, ctx.Err()
		// ok，说明连接请求中已经被放入可用的连接
		case ret, ok := <-req:
			//检测一下获得连接的状况，是否过期等等
			atomic.AddInt64(&db.waitDuration, int64(time.Since(waitStart)))
			...
			if ret.err == nil && ret.conn.expired(lifetime) {
				ret.conn.Close()
				return nil, driver.ErrBadConn
			}
			...
			// Lock around reading lastErr to ensure the session resetter finished.
			ret.conn.Lock()
			err := ret.conn.lastErr
			ret.conn.Unlock()
			if err == driver.ErrBadConn {
				ret.conn.Close()
				return nil, driver.ErrBadConn
			}
			return ret.conn, ret.err
		}
	}
	//3. 如果既没有可用连接，连接池中的连接数量又没有满，则新建连接
	db.numOpen++ // optimistically
	db.mu.Unlock()
	//执行真正的连接发起操作，封装并返回
	ci, err := db.connector.Connect(ctx)
	if err != nil {
		db.mu.Lock()
		db.numOpen-- // correct for earlier optimism
		db.maybeOpenNewConnections()
		db.mu.Unlock()
		return nil, err
	}
	db.mu.Lock()
	dc := &driverConn{
		db:        db,
		createdAt: nowFunc(),
		ci:        ci,
		inUse:     true,
	}
	db.addDepLocked(dc, dc)
	db.mu.Unlock()
	return dc, nil
}
```

## transaction 与 connection