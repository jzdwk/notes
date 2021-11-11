# nginx 基本数据结构

## int

nginx对整形的封装，没啥说的
```c
//有符号
typedef inptr_t		ngx_int_t;
//无符号
typedef uintptr_t	ngx_uint_t;
```

## ngx_str_t

nginx字符串中，data指向字符串起始地址，len表示字符串长度。因此，字符串不必以'\0'结尾：
```c
typedef struct{
	size_t	len;
	u_char	*data;
} ngx_str_t;
```

## ngx_list_t

nginx中的链表ngx_list_t为一个数组链表，链表结构中的每一个元素ngx_list_part_t为一个数组，代码定义位于`https://github.com/nginx/nginx/blob/affbe0b8e14a3ce17d1a40f0fa4518d1309a917d/src/core/ngx_list.h#L25`：
```c
typedef struct ngx_list_part_s	ngx_list_part_t;

//链表中每个元素的定义
typedef	ngx_list_part_s	{
	//数组的起始地址
	void			*elts;
	//数组已经使用的元素个数
	ngx_uint_t		nelts;
	//下一个元素地址
	ngx_list_part_t	*next;
};

//链表主结构，链表中每个元素part为一个数组
typedef	struct	{
	//指向链表最后一个元素的指针
	ngx_list_part_t	*last;
	//链表中每条数据的定义，本质为一个数组
	ngx_list_part_t	part;
	//针对每一条数据，定义其对应数组中每个元素的占用空间大小
	size_t			size;
	//表示每条数据(数组)的容量大小，即数据中元素的数据量，故链表中每一个元素占用大小为size*nalloc
	ngx_uint_t		nalloc;
	//为整个ngx_list_t分配内存的内存池对象，通常为一段连续的内存
	ngx_pool_t		*pool;
}ngx_list_t;
```

## ngx_table_elt_t

ngx_table_elt_t用于存储一个K/V对，用于处理HTTP头部：

```c
typedef struct {
	//用于更快的在ngx_hash_t中找到相同key的ngx_table_elt_t
	ngx_uint_t	hash;
	//键，比如HTTP头的  Content-Length
	ngx_str_t	key;
	//值，比如HTTP头对应的值 1024
	ngx_str_t	value;
	//小写的键
	u_char		*lowcase_key;

} ngx_table_elt_t;
```

## ngx_buf_t

nginx处理大数据的数据结构，定义位于https://github.com/nginx/nginx/blob/affbe0b8e14a3ce17d1a40f0fa4518d1309a917d/src/core/ngx_buf.h#L20:
```c
typedef struct ngx_buf_s  ngx_buf_t;
typedef void *            ngx_buf_tag_t;

struct ngx_buf_s {
    u_char          *pos;	//当buf所指向的数据在内存里的时候，pos指向的是这段数据开始的位置。
    u_char          *last;	//当buf所指向的数据在内存里的时候，last指向的是这段数据结束的位置。
	
    off_t            file_pos;	//当buf所指向的数据是在文件里的时候，file_pos指向的是这段数据的开始位置在文件中的偏移量。
    off_t            file_last;	//当buf所指向的数据是在文件里的时候，file_last指向的是这段数据的结束位置在文件中的偏移量。
	
	//当buf所指向的数据在内存里的时候，这一整块内存包含的内容可能被包含在多个buf中
	//(比如在某段数据中间插入了其他的数据，这一块数据就需要被拆分开)。
	//那么这些buf中的start和end都指向这一块内存的开始地址和结束地址。
	//而pos和last指向本buf所实际包含的数据的开始和结尾。
	//换句话说，start与end描述了buf所处的一整块内存的起始，多个buf的start和end可能相同，多对一关系。
    u_char          *start;         /* start of buffer */
    u_char          *end;           /* end of buffer */
	
    ngx_buf_tag_t    tag;		//实际上是一个void*类型的指针，使用者可以关联任意的对象上去，只要对使用者有意义。
    ngx_file_t      *file;		//当buf所包含的内容在文件中时，file字段指向对应的文件对象。
    
	//当这个buf完整copy了另外一个buf的所有字段的时候，那么这两个buf指向的实际上是同一块内存，或者是同一个文件的同一部分，此时这两个buf的shadow字段都是指向对方的。
	//PS：对于这样的两个buf，在释放的时候，就需要使用者特别小心，具体是由哪里释放，要提前考虑好，如果造成资源的多次释放，可能会造成程序崩溃！
	ngx_buf_t       *shadow;	

	
    /* the buf's content could be changed */
    unsigned         temporary:1;	//为1时表示该buf所包含的内容是在一个用户创建的内存块中，并且可以被在filter处理的过程中进行变更，而不会造成问题。

    /*
     * the buf's content is in a memory cache or in a read only memory
     * and must not be changed
     */
    unsigned         memory:1;	//为1时表示该buf所包含的内容是在内存中，但是这些内容确不能被进行处理的filter进行变更。

    /* the buf's content is mmap()ed and must not be changed */
    unsigned         mmap:1;	//为1时表示该buf所包含的内容是在内存中, 是通过mmap使用内存映射从文件中映射到内存中的，这些内容确不能被进行处理的filter进行变更。

	//可以回收的。也就是这个buf是可以被释放的。这个字段通常是配合shadow字段一起使用的
	//对于使用ngx_create_temp_buf 函数创建的buf，并且是另外一个buf的shadow，那么可以使用这个字段来标示这个buf是可以被释放的。
    unsigned         recycled:1;
    unsigned         in_file:1;		//为1时表示该buf所包含的内容是在文件中
	unsigned         flush:1;		//为1时需要执行flush操作
    unsigned         sync:1;		//标志位，为1表示在操作此buf时使用同步方式。具体视使用它的nginx模块而定，谨慎考虑
    unsigned         last_buf:1;	//是否为最后一块buf，ngx_buf_t可以由ngx_chain_t链表串联，故为1表示为链表的最后一个元素
	
	//在当前的chain里面，此buf是最后一个。
	//last_in_chain的buf不一定是last_buf，但是last_buf的buf一定是last_in_chain的。
	//这是因为某buf会被包含在多个chain中传递给某个filter模块。
	unsigned         last_in_chain:1;

    unsigned         last_shadow:1;	//在创建一个buf的shadow的时候，通常将新创建的一个buf的last_shadow置为1，不推荐使用。
    unsigned         temp_file:1;	//有时候一些buf的内容需要被写到磁盘上的临时文件中去，那么这时，就设置此标志 。

    /* STUB */ int   num;
};
```

## ngx_chain_t

描述一个由ngx_buf_t组成的链表：
```c
//定义位于ngx_core.h
typedef struct ngx_chain_s           ngx_chain_t;

//https://github.com/nginx/nginx/blob/affbe0b8e14a3ce17d1a40f0fa4518d1309a917d/src/core/ngx_buf.h#L59
struct ngx_chain_s {
    ngx_buf_t    *buf;
    ngx_chain_t  *next; //指向下一个chain表的指针，如果本chain已是最后一个，则置NULL
};
```
