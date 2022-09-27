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
	//postgres.Open(dataSourceName)封装一个&Dialector{&Config{DSN: dsn}} Dialector对象，即DB的初始化委托给了dialector创建
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
	//dialector尚未赋值Conn以及DriverName
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
	c := GetConnector(config, opts...)
	return sql.OpenDB(c)
}

func GetConnector(config pgx.ConnConfig, opts ...OptionOpenDB) driver.Connector {
	c := connector{
		ConnConfig:    config,
		BeforeConnect: func(context.Context, *pgx.ConnConfig) error { return nil }, // noop before connect by default
		AfterConnect:  func(context.Context, *pgx.Conn) error { return nil },       // noop after connect by default
		ResetSession:  func(context.Context, *pgx.Conn) error { return nil },       // noop reset session by default
		//pgxDriver 来自init()
		//	pgxDriver = &Driver{
		//     configs: make(map[string]*pgx.ConnConfig),
	    //  }
		driver:        pgxDriver,
	}

	for _, opt := range opts {
		opt(&c)
	}
	return c
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
// Open one new connection
func (db *DB) openNewConnection(ctx context.Context) {
	// maybeOpenNewConnections has already executed db.numOpen++ before it sent
	// on db.openerCh. This function must execute db.numOpen-- if the
	// connection fails or is closed before returning.
	//db.connector 即上文中GetConnector函数的返回
	ci, err := db.connector.Connect(ctx)
	db.mu.Lock()
	defer db.mu.Unlock()
	if db.closed {
		if err == nil {
			ci.Close()
		}
		db.numOpen--
		return
	}
	if err != nil {
		db.numOpen--
		db.putConnDBLocked(nil, err)
		db.maybeOpenNewConnections()
		return
	}
	dc := &driverConn{
		db:         db,
		createdAt:  nowFunc(),
		returnedAt: nowFunc(),
		ci:         ci,
	}
	if db.putConnDBLocked(dc, err) {
		db.addDepLocked(dc, dc)
	} else {
		db.numOpen--
		ci.Close()
	}
}

// Assumes db.mu is locked.
// If there are connRequests and the connection limit hasn't been reached,
// then tell the connectionOpener to open new connections.
func (db *DB) maybeOpenNewConnections() {
	numRequests := len(db.connRequests)
	if db.maxOpen > 0 {
		numCanOpen := db.maxOpen - db.numOpen
		if numRequests > numCanOpen {
			numRequests = numCanOpen
		}
	}
	for numRequests > 0 {
		db.numOpen++ // optimistically
		numRequests--
		if db.closed {
			return
		}
		db.openerCh <- struct{}{}
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
	connector driver.Connector	 // 数据库驱动接口
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
	openerCh          chan struct{}		// 通知需要创建新的连接
	resetterCh        chan *driverConn
	closed            bool
	dep               map[finalCloser]depSet
	lastPut           map[*driverConn]string // stacktrace of last conn's put; debug only
	
	//连接池基本参数配置
	maxIdle           int                    // zero means defaultMaxIdleConns; negative means 0	
	maxOpen           int                    // <= 0 means unlimited
	maxLifetime       time.Duration          // maximum amount of time a connection may be reused
	cleanerCh         chan struct{} 		// 用于通知清理过期的连接，maxlife时间改变或者连接被关闭时会通过该channel通知
	waitCount         int64 // Total number of connections waited for.
	maxIdleClosed     int64 // Total number of connections closed due to idle.
	maxLifetimeClosed int64 // Total number of connections closed due to max free limit.

	stop func() // stop cancels the connection opener and the session resetter.
}
```
**需要注意的是，在OpenDB后，并没有真正的创建任何连接**，只是开启了两个协程，通过channel维护池中连接数量。**真正的创建连接操作在具体的query处**

## get connection

以`	tx.callbacks.Query().Execute(tx)`代码为例，gorm的查询最终调用了`processor`中的fns，processor对象维护了CRUD场景中需要的各个执行函数，所以函数以有序数组的形式在初始化时被注册，具体内容和参考后文的**transaction与connection**。以Query的为例：
```go
func (p *processor) Execute(db *DB) {
	...
	//执行业务链
	for _, f := range p.fns {
		f(db)
	}
	...
}

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

### 注册函数链

在分析transaction前，首先捋清gorm执行sql的大致流程，在上文的`Open`函数中，只说明了初始化一个db的抽象对象。但除此之外，**Open中也注册了执行sql时需要的各种业务函数，比如开启事务，执行查询，封装返回等，思路类似一个责任链**，继续看该函数:
```go
// Open initialize db session based on dialector
func Open(dialector Dialector, opts ...Option) (db *DB, err error) {
	config := &Config{}
	...
	//初始化CRUD场景中的各个processor对象，并返回封装的callbacks，内部结构为一个map[string,processor]，每个processor中只有db信息
	db.callbacks = initializeCallbacks(db)
	...
	//初始化db
	if config.Dialector != nil {
		err = config.Dialector.Initialize(db)
	}
	...
	return
}
//算上返回值处理，一共6个场景，6类处理函数
func initializeCallbacks(db *DB) *callbacks {
	return &callbacks{
		processors: map[string]*processor{
			"create": {db: db},
			"query":  {db: db},
			"update": {db: db},
			"delete": {db: db},
			"row":    {db: db},
			"raw":    {db: db},
		},
	}
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
func (dialector Dialector) Initialize(db *gorm.DB) (err error) {
	//注册真正需要执行的，在CRUD场景下的业务链
	// register callbacks
	callbacks.RegisterDefaultCallbacks(db, &callbacks.Config{
		WithReturning: !dialector.WithoutReturning,
	})
	//省略，后续代码在上文已经分析
	...
	return
}
```
继续看函数`func RegisterDefaultCallbacks(db *gorm.DB, config *Config)`，该函数即注册了具体的函数链:
```go
func RegisterDefaultCallbacks(db *gorm.DB, config *Config) {
	//设置不跳过事务，在下列场景中的Match中被调用
	enableTransaction := func(db *gorm.DB) bool {
		return !db.SkipDefaultTransaction
	}
	//create场景，CallBack
	createCallback := db.Callback().Create()
	createCallback.Match(enableTransaction).Register("gorm:begin_transaction", BeginTransaction) //注册事务
	createCallback.Register("gorm:before_create", BeforeCreate)
	createCallback.Register("gorm:save_before_associations", SaveBeforeAssociations(true))
	createCallback.Register("gorm:create", Create(config))
	createCallback.Register("gorm:save_after_associations", SaveAfterAssociations(true))
	createCallback.Register("gorm:after_create", AfterCreate)
	createCallback.Match(enableTransaction).Register("gorm:commit_or_rollback_transaction", CommitOrRollbackTransaction)
	//query场景
	...
	//delete场景
	deleteCallback := db.Callback().Delete()
	...
	//update场景
	...
	//数据返回处理，row场景
	db.Callback().Row().Register("gorm:row", RowQuery)
	//raw场景
	db.Callback().Raw().Register("gorm:raw", RawExec)
}
```
以Create场景为例,其过程为：

1. 获取create场景中具体的processor
```go
createCallback := db.Callback().Create()
func (db *DB) Callback() *callbacks {
	return db.callbacks
}
//processor的key为create
func (cs *callbacks) Create() *processor {
	return cs.processors["create"]
}
```
2. 初始化一个callback对象，用于维护函数链
```go
createCallback.Match(enableTransaction).Register("gorm:begin_transaction", BeginTransaction)
func (p *processor) Match(fc func(*DB) bool) *callback {
	//match字段为true 反向引用processor
	return &callback{match: fc, processor: p}
}
```
3. 将BeginTransaction注册至具体的callback
```go
func (c *callback) Register(name string, fn func(*DB)) error {
	c.name = name
	c.handler = fn
	c.processor.callbacks = append(c.processor.callbacks, c)
	//执行complie的作用是将注册的函数进行排序，并放进processor的fns字段中，供执行类似Query时调用，具体可见上文的“connection获取”段落
	return c.processor.compile()
}
```
这里，将`db/callback/processor`等对象的依赖关系屡一下：
```
//DB 定义
type DB struct {
	*Config	//Config中维护了DB的大多数信息
	Error        error
	RowsAffected int64
	Statement    *Statement
	clone        int
}
// Config GORM config
type Config struct {
	...
	// ConnPool db conn pool
	ConnPool ConnPool
	...
	//callbacks
	callbacks  *callbacks
	
}
// callbacks字段
// callbacks gorm callbacks manager
type callbacks struct {
	//mep[string,processor]形式的map，其中key即queryCallback := db.Callback().Query()中的create/query/delete等
	processors map[string]*processor
}
//processor
type processor struct {
	db        *DB			//反向维护一个db信息
	fns       []func(*DB)	//fns即具体Delete等函数执行时的函数链
	callbacks []*callback	//注册的callback
}
//callback，在createCallback.Match(enableTransaction).Register("gorm:begin_transaction", BeginTransaction)的Register中被Match初始化，并被Register赋值具体的操作函数
type callback struct {
	name      string			//名称，gorm:begin_transaction
	before    string		
	after     string
	remove    bool
	replace   bool
	match     func(*DB) bool	//enableTransaction函数
	handler   func(*DB)			//具体的执行函数，BeginTransaction
	processor *processor		//所属的processor，反向引用
}
```
所以，**注册函数链的整体流程就是，首选根据业务场景，从callbacks的map[string,processor]中获取processor对象，然后向该对象的callbacks中添加具体的执行函数，并通过complie排序，赋值给fns，供后续实际业务函数有序调用**

### transaction场景

transaction与connection的关系分为以下两个场景：

1. 没有显式的声明一个transaction，执行单一的sql，代码类似：
```go
func (m mepMeta) Create(value *mepmd.MepMeta) error {
	return models.PostgresDB.Create(value).Error
}
```
进入`Create`的内部实现：
```go
func (db *DB) Create(value interface{}) (tx *DB) {
	...
	tx = db.getInstance()
	tx.Statement.Dest = value
	//Create()首先从callbacks的mep[string,processor]中获取create的processor，然后执行Exectue
	tx.callbacks.Create().Execute(tx)
	return
}
func (p *processor) Execute(db *DB) {
	//根据上一小节，这里会首先执行注册的BeginTransaction函数
	...
	for _, f := range p.fns {
		f(db)
	}
}
func BeginTransaction(db *gorm.DB) {
	//SkipDefaultTransaction返回false
	if !db.Config.SkipDefaultTransaction {
		//调用db.Begin
		if tx := db.Begin(); tx.Error == nil {
			db.Statement.ConnPool = tx.Statement.ConnPool
			db.InstanceSet("gorm:started_transaction", true)
		} else if tx.Error == gorm.ErrInvalidTransaction {
			tx.Error = nil
		}
	}
}
// Begin begins a transaction
func (db *DB) Begin(opts ...*sql.TxOptions) *DB {
	var (
		创建一个tx对象
		tx  = db.getInstance().Session(&Session{Context: db.Statement.Context})
		...
	)
	...
	//无声明的transaction走这个分支
	if beginner, ok := tx.Statement.ConnPool.(TxBeginner); ok {
		//开启事务，并赋值给ConnPool，之后的查询都使用该conn
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else if beginner, ok := tx.Statement.ConnPool.(ConnPoolBeginner); ok {
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else {
		err = ErrInvalidTransaction
	}
	...
	return tx
}
```


2. 使用了transaction，多个sql在一个tx对象中执行，代码类似：
```go
	return models.PostgresDB.Transaction(func(tx *gorm.DB) error {
		if err := dao.ServiceDao.Create(tx, &svcInfo); ...
		if err := tx.CreateInBatches(&apis, len(apis)).Error; ...
		if err := tx.CreateInBatches(&args, len(args)).Error; ...
		...
		return nil
	})
```
此时的事务已在Transaction函数中被创建：
```go
func (db *DB) Transaction(fc func(tx *DB) error, opts ...*sql.TxOptions) (err error) {
	panicked := true
	//走else分支
	if committer, ok := db.Statement.ConnPool.(TxCommitter); ok && committer != nil {
		// nested transaction
		if !db.DisableNestedTransaction {
			err = db.SavePoint(fmt.Sprintf("sp%p", fc)).Error
			defer func() {
				// Make sure to rollback when panic, Block error or Commit error
				if panicked || err != nil {
					db.RollbackTo(fmt.Sprintf("sp%p", fc))
				}
			}()
		}
		if err == nil {
			err = fc(db.Session(&Session{}))
		}
	} else {
		//创建transaction
		tx := db.Begin(opts...)
		...
		//执行业务函数fc,commit
		...
	}
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
func (db *DB) Begin(opts ...*sql.TxOptions) *DB {
	var (
		// clone statement
		tx  = db.Session(&Session{Context: db.Statement.Context})
		...
	)
	...
	if beginner, ok := tx.Statement.ConnPool.(TxBeginner); ok {
	//走此分支，创建一个trasaction对象
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else if beginner, ok := tx.Statement.ConnPool.(ConnPoolBeginner); ok {
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else {
		err = ErrInvalidTransaction
	}
	if err != nil {
		tx.AddError(err)
	}
	return tx
}
```
相应的，当在事务中的函数执行具体操作，比如示例代码中的:
```
dao.ServiceDao.Create(tx, &svcInfo)`:
func (s service) Create(tx *gorm.DB, svc *apigwmd.Service) error {
	if tx == nil {
		tx = models.PostgresDB
	}
	return s.RewriteDbError(tx.Create(svc).Error)

}
```
此函数**会执行Create的函数链**
```go
func (p *processor) Execute(db *DB) {
	//执行注册的第一个函数，BeginTransaction
	...
	for _, f := range p.fns {
		f(db)
	}
}
```
由于此时已经存在创建好的Transaction,因此，在Begin的具体函数中，会走else分支：
```go
func BeginTransaction(db *gorm.DB) {
	//SkipDefaultTransaction返回false
	if !db.Config.SkipDefaultTransaction {
		//执行Begin抛出error
		if tx := db.Begin(); tx.Error == nil {
			db.Statement.ConnPool = tx.Statement.ConnPool
			db.InstanceSet("gorm:started_transaction", true)
		} else if tx.Error == gorm.ErrInvalidTransaction {
			//因为err为ErrInvalidTransaction，因此至空，这说明BeginTransaction将不再创建新的事务
			tx.Error = nil
		}
	}
}
//
// Begin begins a transaction
func (db *DB) Begin(opts ...*sql.TxOptions) *DB {
	...
	if beginner, ok := tx.Statement.ConnPool.(TxBeginner); ok {
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else if beginner, ok := tx.Statement.ConnPool.(ConnPoolBeginner); ok {
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else {
		//走此分支，抛出ErrInvalidTransaction
		err = ErrInvalidTransaction
	}

	if err != nil {
		tx.AddError(err)
	}

	return tx
}
```
接下来将执行后续函数链。此为**业务函数Create的流程，后续业务函数同理，他们将共用同一个事务对象**：
```go
	//使用同一个对象
	return models.PostgresDB.Transaction(func(tx *gorm.DB) error {
		if err := dao.ServiceDao.Create(tx, &svcInfo); ...
		if err := tx.CreateInBatches(&apis, len(apis)).Error; ...
		if err := tx.CreateInBatches(&args, len(args)).Error; ...
		...
		return nil
	})
```

### 与connection的关系

上文为transaction在不同场景的使用，继续看函数链中的`BeginTrasaction`如何处理事务与连接的关系：
```go
func BeginTransaction(db *gorm.DB) {
	if !db.Config.SkipDefaultTransaction {
		if tx := db.Begin(); tx.Error == nil {
			db.Statement.ConnPool = tx.Statement.ConnPool
			db.InstanceSet("gorm:started_transaction", true)
		} else if tx.Error == gorm.ErrInvalidTransaction {
			tx.Error = nil
		}
	}
}
```
进入创建事务的`Begin`：
```go
// Begin begins a transaction
func (db *DB) Begin(opts ...*sql.TxOptions) *DB {
	...
	if beginner, ok := tx.Statement.ConnPool.(TxBeginner); ok {
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else if beginner, ok := tx.Statement.ConnPool.(ConnPoolBeginner); ok {
		tx.Statement.ConnPool, err = beginner.BeginTx(tx.Statement.Context, opt)
	} else {
		err = ErrInvalidTransaction
	}
	...
	return tx
}
// BeginTx starts a transaction.
//
// The provided context is used until the transaction is committed or rolled back.
// If the context is canceled, the sql package will roll back
// the transaction. Tx.Commit will return an error if the context provided to
// BeginTx is canceled.
//
// The provided TxOptions is optional and may be nil if defaults should be used.
// If a non-default isolation level is used that the driver doesn't support,
// an error will be returned.
func (db *DB) BeginTx(ctx context.Context, opts *TxOptions) (*Tx, error) {
	var tx *Tx
	var err error
	for i := 0; i < maxBadConnRetries; i++ {
		tx, err = db.begin(ctx, opts, cachedOrNewConn)
		if err != driver.ErrBadConn {
			break
		}
	}
	if err == driver.ErrBadConn {
		return db.begin(ctx, opts, alwaysNewConn)
	}
	return tx, err
}
//执行db.begin，将调用conn函数，后者将返回一个可用连接
func (db *DB) begin(ctx context.Context, opts *TxOptions, strategy connReuseStrategy) (tx *Tx, err error) {
	dc, err := db.conn(ctx, strategy)
	if err != nil {
		return nil, err
	}
	//获取连接后，调用beginDC开启事务
	return db.beginDC(ctx, dc, dc.releaseConn, opts)
}
```
**至此，可以看到，创建一个transaction对象，将首先从连接池中获取一个连接，获取的具体策略在上文已经分析，获取连接后，在该连接上开启事务**

## release connection

根据上文中，gorm通过注册函数链执行sql，可推断连接的释放位于函数链的最后一个函数，以`create`场景为例：
```go
	createCallback := db.Callback().Create()
	createCallback.Match(enableTransaction).Register("gorm:begin_transaction", BeginTransaction)
	createCallback.Register("gorm:before_create", BeforeCreate)
	createCallback.Register("gorm:save_before_associations", SaveBeforeAssociations)
	createCallback.Register("gorm:create", Create(config))
	createCallback.Register("gorm:save_after_associations", SaveAfterAssociations)
	createCallback.Register("gorm:after_create", AfterCreate)
	//连接释放的入口
	createCallback.Match(enableTransaction).Register("gorm:commit_or_rollback_transaction", CommitOrRollbackTransaction)
```
进入`CommitOrRollbackTransaction`内部，并一直跟进`Commit函数`，可以看到最终的释放位于`tx.close`中的`tx.releaseConn(err)`：
```go
func (tx *Tx) Commit() error {
	// Check context first to avoid transaction leak.
	// If put it behind tx.done CompareAndSwap statement, we can't ensure
	// the consistency between tx.done and the real COMMIT operation.
	select {
	default:
	case <-tx.ctx.Done():
		if atomic.LoadInt32(&tx.done) == 1 {
			return ErrTxDone
		}
		return tx.ctx.Err()
	}
	if !atomic.CompareAndSwapInt32(&tx.done, 0, 1) {
		return ErrTxDone
	}
	var err error
	withLock(tx.dc, func() {
		err = tx.txi.Commit()
	})
	if err != driver.ErrBadConn {
		tx.closePrepared()
	}
	//
	tx.close(err)
	return err
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// close returns the connection to the pool and
// must only be called by Tx.rollback or Tx.Commit.
func (tx *Tx) close(err error) {
	tx.cancel()

	tx.closemu.Lock()
	defer tx.closemu.Unlock()
	//此函数为将连接放入pool中
	tx.releaseConn(err)
	tx.dc = nil
	tx.txi = nil
}
```
那么该函数在何处被注册？回到函数链的注册逻辑，进入`BeginTransaction`，并一直跟进至`begin`：
```go
func (db *DB) begin(ctx context.Context, opts *TxOptions, strategy connReuseStrategy) (tx *Tx, err error) {
	dc, err := db.conn(ctx, strategy)
	if err != nil {
		return nil, err
	}
	//在此处，获取到transaction的同时，注册了一个dc.releaseConn函数
	return db.beginDC(ctx, dc, dc.releaseConn, opts)
}
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
// beginDC starts a transaction. The provided dc must be valid and ready to use.
func (db *DB) beginDC(ctx context.Context, dc *driverConn, release func(error), opts *TxOptions) (tx *Tx, err error) {
	var txi driver.Tx
	withLock(dc, func() {
		txi, err = ctxDriverBegin(ctx, opts, dc.ci)
	})
	if err != nil {
		//如果开启事务失败，直接释放连接
		release(err)
		return nil, err
	}

	// Schedule the transaction to rollback when the context is cancelled.
	// The cancel function in Tx will be called after done is set to true.
	ctx, cancel := context.WithCancel(ctx)
	tx = &Tx{
		db:          db,
		dc:          dc,
		//填写release域
		releaseConn: release,
		txi:         txi,
		cancel:      cancel,
		ctx:         ctx,
	}
	go tx.awaitDone()
	return tx, nil
}
```
因此，这个`dc.releaseConn`即连接释放的具体实现：
```go
func (dc *driverConn) releaseConn(err error) {
	dc.db.putConn(dc, err, true)
}

// putConn adds a connection to the db's free pool.
// err is optionally the last error that occurred on this connection.
func (db *DB) putConn(dc *driverConn, err error, resetSession bool) {
	db.mu.Lock()
	if !dc.inUse {
		if debugGetPut {
			fmt.Printf("putConn(%v) DUPLICATE was: %s\n\nPREVIOUS was: %s", dc, stack(), db.lastPut[dc])
		}
		panic("sql: connection returned that was never out")
	}
	if debugGetPut {
		db.lastPut[dc] = stack()
	}
	dc.inUse = false
	// 调用连接上注册的一些statement的关闭函数
	for _, fn := range dc.onPut {
		fn()
	}
	dc.onPut = nil
	// 如果当前连接已经不可用，意味着可能会有新的连接请求，调用maybeOpenNewConnections进行检测
	if err == driver.ErrBadConn {
		// Don't reuse bad connections.
		// Since the conn is considered bad and is being discarded, treat it
		// as closed. Don't decrement the open count here, finalClose will
		// take care of that.
		db.maybeOpenNewConnections()
		db.mu.Unlock()
		dc.Close()
		return
	}
	if putConnHook != nil {
		putConnHook(db, dc)
	}
	if db.closed {
		// Connections do not need to be reset if they will be closed.
		// Prevents writing to resetterCh after the DB has closed.
		resetSession = false
	}
	if resetSession {
		if _, resetSession = dc.ci.(driver.SessionResetter); resetSession {
			// Lock the driverConn here so it isn't released until
			// the connection is reset.
			// The lock must be taken before the connection is put into
			// the pool to prevent it from being taken out before it is reset.
			dc.Lock()
		}
	}
	//执行具体的连接释放
	added := db.putConnDBLocked(dc, nil)
	db.mu.Unlock()
	//添加失败则关闭连接
	if !added {
		if resetSession {
			dc.Unlock()
		}
		dc.Close()
		return
	}
	if !resetSession {
		return
	}
	select {
	default:
		// If the resetterCh is blocking then mark the connection
		// as bad and continue on.
		dc.lastErr = driver.ErrBadConn
		dc.Unlock()
	case db.resetterCh <- dc:
	}
}
```
再进入具体的连接释放函数`db.putConnDBLocked(dc, nil)`：
```go
// Satisfy a connRequest or put the driverConn in the idle pool and return true
// or return false.
// putConnDBLocked will satisfy a connRequest if there is one, or it will
// return the *driverConn to the freeConn list if err == nil and the idle
// connection limit will not be exceeded.
// If err != nil, the value of dc is ignored.
// If err == nil, then dc must not equal nil.
// If a connRequest was fulfilled or the *driverConn was placed in the
// freeConn list, then true is returned, otherwise false is returned.
func (db *DB) putConnDBLocked(dc *driverConn, err error) bool {
	if db.closed {
		return false
	}
	// 如果已经超过最大打开数量了，就不需要在回归pool了
	if db.maxOpen > 0 && db.numOpen > db.maxOpen {
		return false
	}
	 // 这边是重点了，基本来说就是从connRequest这个map里面随机抽一个在排队等着的请求。取出来后发给他。就不用归还池子了。
	if c := len(db.connRequests); c > 0 {
		var req chan connRequest
		var reqKey uint64
		for reqKey, req = range db.connRequests {
			break
		}
		delete(db.connRequests, reqKey) // Remove from pending requests.
		if err == nil {
			dc.inUse = true
		}
		// 把连接给这个正在排队的连接
		req <- connRequest{
			conn: dc,
			err:  err,
		}
		return true
	} else if err == nil && !db.closed {
		// 既然没人排队，就看看到了最大连接数目没有。没到就归还给freeConn。
		if db.maxIdleConnsLocked() > len(db.freeConn) {
			db.freeConn = append(db.freeConn, dc)
			db.startCleanerLocked()
			return true
		}
		db.maxIdleClosed++
	}
	return false
}
```

## 参考

[1](https://learnku.com/articles/41137)

[2](https://blog.51cto.com/muhuizz/2577451)