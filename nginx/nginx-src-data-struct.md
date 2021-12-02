# nginx数据结构

nginx的数据结构分为了高级与基本数据结构

## nginx 基本数据结构

### int

nginx对整形的封装，没啥说的
```c
//有符号
typedef inptr_t		ngx_int_t;
//无符号
typedef uintptr_t	ngx_uint_t;
```

### ngx_str_t

nginx字符串中，data指向字符串起始地址，len表示字符串长度。因此，字符串不必以'\0'结尾：
```c
typedef struct{
	size_t	len;
	u_char	*data;
} ngx_str_t;
```

### ngx_list_t

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

### ngx_table_elt_t

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

### ngx_buf_t

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

### ngx_chain_t

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

## nginx高级数据结构

### ngx_queue_t

ngx_queue_t 是Nginx提供的一个轻量级**双向链表**容器，它不负责分配内存来存放链表元素。 其具备下列特点：
- 可以高效的执行插入、删除、合并等操作
- 具有排序功能
- 支持两个链表间的合并
- 支持将一个链表一分为二的拆分动作
其定义位于`/src/core/ngx_queue.(h/c)`：
```c
typedef struct ngx_queue_s  ngx_queue_t;

struct ngx_queue_s {
    ngx_queue_t  *prev;
    ngx_queue_t  *next;
};
```
它有2个特点：

1. 链表不包含数据域

同于教科书中将链表节点的数据成员声明在链表节点的结构体中，**ngx_queue_t只是声明了前向和后向指针，而没有包含数据内容**，因此在使用时，链表的每一个元素可以是任意类型的struct，但**结构体中必须包含一个ngx_queue_t类型的成员**，在向链表中CRUD元素时，均使用ngx_queue_t成员的指针。因此，可以通过offset操作，从ngx_queue_t成员反向推出链表元素地址：
```c
//q为链表某元素中的ngx_queue_t指针，type为元素结构体，field为ngx_queue_t类型的变量名
//因此，根据内存结构，使用(ngx_queue_t指针指向地址-field相对于type的偏移量)=元素地址
#define ngx_queue_data(q, type, field) (type *) ((u_char *) q - offsetof(type, field))
//offsetof也是一个宏定义，如下：
#define offsetof(p_type,field) ((size_t)&(((p_type *)0)->field))
```

2. 链表存在头节点

Nginx的ngx_queue_t存在**头节点**(或者叫链表容器)与**普通链表元素**之分，虽然两者的类型一致，这里需要注意。当需要操作链表是，入参为头节点，操作链表元素时，入参为元素的中ngx_queue_t字段指针.
头节点需要通过ngx_queue_init初始化，头节点的类型即为ngx_queue_t。当作为头节点操作链表时：
```c
//1. 空链表，只有头节点，prev  next指向自身
#define ngx_queue_init(q)     \
    (q)->prev = q;            \
    (q)->next = q;
//2. 只有一个元素，头节点prev与next指向元素的ngx_queue_t指针，元素的prev与next都指向头节点
//3. 有2个或以上元素，头节点prev指向最后一个元素，next指向下一元素；最后一个元素的prev指向前一个元素，next指向头节点
#define ngx_queue_insert_head(h, x)                                           \
    (x)->next = (h)->next;                                                    \
    (x)->next->prev = x;                                                      \
    (x)->prev = h;                                                            \
    (h)->next = x
#define ngx_queue_insert_tail(h, x)                                           \
    (x)->prev = (h)->prev;                                                    \
    (x)->prev->next = x;                                                      \
    (x)->next = h;                                                            \
    (h)->prev = x
```
链表操作常用函数如下：
```c
ngx_queue_init(q)            //初始化链表
ngx_queue_empty(h)           //推断链表是否为空                                                   
ngx_queue_insert_head(h, x)  //在头部插入一个元素                                       
#define ngx_queue_insert_after   ngx_queue_insert_head      //在h元素前面插入一个元素
ngx_queue_insert_tail(h, x)  //在h尾部插入一个元素 
ngx_queue_head(h)            //返回第一个元素
#define ngx_queue_last(h)    //返回最后一个元素 
ngx_queue_sentinel(h)        //返回链表容器结构体的指针
ngx_queue_next(q)            //返回下一个q的下一个元素  
ngx_queue_prev(q)            //返回q的前一个元素
ngx_queue_remove(x)          //删除x结点                                           
ngx_queue_split(h, q, n)     //把h分为两个链表h和n，而且n的第一元素为q
ngx_queue_add(h, n)          //把链表n添加到h链表的尾部
ngx_queue_data(q, type, link)//取出包括q的type类型的地址。这样我们就能够訪问type内的成员

```


3. 例子

来自https://www.cnblogs.com/zfyouxi/p/5177875.html

```c
//元素中包含ngx_queue_t
typedef struct{
	ngx_int_t num;
	ngx_str_t str;
	ngx_queue_t queue;
}TestNode;
//定义排序
ngx_int_t compare_node(const ngx_queue_t *left, const ngx_queue_t *right){
	//获取ngx_queue_t所在元素的指针
	TestNode* left_node  = ngx_queue_data(left, TestNode, queue);
	TestNode* right_node = ngx_queue_data(right, TestNode, queue);
	
	return left_node->num > right_node->num;
}


int main(){
	//初始化链表的头节点
    ngx_queue_t QueHead;
	ngx_queue_init(&QueHead);
	//初始化10个元素节点
	TestNode Node[10];
	ngx_int_t i;
	for (i=0; i<10; ++i){
		Node[i].num = rand()%100;
	}
	
    ngx_queue_insert_head(&QueHead, &Node[0].queue);
	ngx_queue_insert_tail(&QueHead, &Node[1].queue);
	ngx_queue_insert_after(&QueHead, &Node[2].queue);
    ngx_queue_insert_head(&QueHead, &Node[4].queue);
	ngx_queue_insert_tail(&QueHead, &Node[3].queue);
    ngx_queue_insert_head(&QueHead, &Node[5].queue);
	ngx_queue_insert_tail(&QueHead, &Node[6].queue);
	ngx_queue_insert_after(&QueHead, &Node[7].queue);
    ngx_queue_insert_head(&QueHead, &Node[8].queue);
	ngx_queue_insert_tail(&QueHead, &Node[9].queue);
	ngx_queue_t *q;
	
	for (q = ngx_queue_head(&QueHead); q != ngx_queue_sentinel(&QueHead); q = ngx_queue_next(q)){
		TestNode* Node = ngx_queue_data(q, TestNode, queue);
		printf("Num=%d\n", Node->num);
	}
    ngx_queue_sort(&QueHead, compare_node);
	for (q = ngx_queue_head(&QueHead); q != ngx_queue_sentinel(&QueHead); q = ngx_queue_next(q)){
		TestNode* Node = ngx_queue_data(q, TestNode, queue);
		printf("Num=%d\n", Node->num);
	}
	return 0;
}
```

### ngx_array_t

nginx的动态数组主要用于解决数组动态扩容的问题，类似java中的arrayList等类，没啥说的，就是向数组添加元素时，如果数据满了，就扩：
```c
//数据定义位于src/core/ngx_array_t.(h/c)
typedef struct {
    void        *elts;		//数组起始地址
    ngx_uint_t   nelts;		//已有元素个数
    size_t       size;		//元素所占字节
    ngx_uint_t   nalloc;	//可容纳元素总个数
    ngx_pool_t  *pool;		//内存块，所有内存从其pool申请
} ngx_array_t;

//数组的create与init方法实现
static ngx_inline ngx_int_t ngx_array_init(ngx_array_t *array, ngx_pool_t *pool, ngx_uint_t n, size_t size){
    /*
     * set "array->nelts" before "array->elts", otherwise MSVC thinks
     * that "array->nelts" may be used without having been initialized
     */

    array->nelts = 0;
    array->size = size;
    array->nalloc = n;
    array->pool = pool;
	//从pool中申请n * size大小的内存，将内存首地址返回给array->elts
    array->elts = ngx_palloc(pool, n * size);
    if (array->elts == NULL) {
        return NGX_ERROR;
    }

    return NGX_OK;
}

ngx_array_t * ngx_array_create(ngx_pool_t *p, ngx_uint_t n, size_t size)
{
    ngx_array_t *a;
	//与init的不容仅在于先创建一块存储ngx_array_t的内存
    a = ngx_palloc(p, sizeof(ngx_array_t));
    if (a == NULL) {
        return NULL;
    }
    if (ngx_array_init(a, p, n, size) != NGX_OK) {
        return NULL;
    }
    return a;
}
```
向动态数组Push元素以及扩容逻辑实现如下：
```c
//入参a为需要添加元素的数组
void * ngx_array_push(ngx_array_t *a){
    void        *elt, *new;
    size_t       size;
    ngx_pool_t  *p;

    //a已经使用的元素个数nelts和a的容量nalloc相等，说明数组已满
    if (a->nelts == a->nalloc) {           

        //计算得到数组已经占用的内存大小
        size = a->size * a->nalloc; 

        p = a->pool;

        //p->d.last指向当前已分配的内存位置，p->d.end指向内存池结束位置
		//(u_char *) a->elts + size == p->d.last 验证所有数组元素均填充
		//p->d.last + a->size <= p->d.end  pool中可以再填充一个元素
		//因此if语句为 当pool中可以填充一个元素时
        if ((u_char *) a->elts + size == p->d.last
            && p->d.last + a->size <= p->d.end){
            /*
             * the array allocation is the last in the pool
             * and there is space for new allocation
             */
            
            //内存池尾指针后移一个元素大小，分配内存一个元素，并把nalloc+1
            p->d.last += a->size;
            a->nalloc++;

        //否则，说明内存池没有多余空间了
        } else {
            /* allocate a new array */

            //重新分配一个新的数组，大小为原容量的2倍
            new = ngx_palloc(p, 2 * size);
            if (new == NULL) {
                return NULL;
            }
            
            //将以前的数组拷贝到新数组，并将数组大小设置为以前二倍
            ngx_memcpy(new, a->elts, size);
            a->elts = new;
            a->nalloc *= 2;
        }
    }

    //已分配好待使用的元素起始地址 = 数组起始地址elts + 元素大小size * 已分配个数nelts
    elt = (u_char *) a->elts + a->size * a->nelts;
	//已分配个数+1 ，返回已分配好待使用的元素起始地址
    a->nelts++;
    return elt;
}
```

### ngx_rbtree_t

红黑树是指每个节点都带有颜色属性的二叉查找树，其中颜色为红色或黑色。除了二叉查找树的一般要求以外，对于红黑树还有如下的特性：

1. 节点是红色或黑色。
2. 根节点是黑色。
3. 所有叶子节点都是黑色（叶子是 NIL 节点，也叫 “哨兵”）。
4. 每个红色节点的两个子节点都是黑色，每个叶子节点到根节点的所有路径上不能有两个连续的红色节点。
5. 从任一节点到每个叶子节点的所有简单路径都包含相同数目的黑色节点

这些约束加强了红黑树的关键性质：**从根节点到叶子节点的最长可能路径长度不大于最短可能路径的两倍**，这样这个树大致上就是平衡了。其原因在于，由于特性4，根节点到叶子节点要么是`黑-红-黑`交替，要么是`黑-黑`全黑，所以其最短的可能路径只能是`黑-黑`全黑节点。又根据5，根节点到叶子节点中，黑节点数目相同，所以其最长路径最多为`黑-红-黑`交替且其中夹杂着红节点。

#### 数据结构

其数据结构定义位于`/src/core/ngx_rbtree.(h/c)`：

1. **树与节点**
```c
//节点相关定义
typedef ngx_uint_t  ngx_rbtree_key_t;
typedef ngx_int_t   ngx_rbtree_key_int_t;

typedef struct ngx_rbtree_node_s  ngx_rbtree_node_t;

struct ngx_rbtree_node_s {
    ngx_rbtree_key_t       key;		//重要，整型关键字，决定了树的形状
    ngx_rbtree_node_t     *left;	//左子节点
    ngx_rbtree_node_t     *right;	//右
    ngx_rbtree_node_t     *parent;	//父
    u_char                 color;	//红or黑
    u_char                 data;	//1字节的节点数据，较少使用
};

//树结构相关定义
typedef struct ngx_rbtree_s  ngx_rbtree_t;

//定义函数指针的别名，函数返回值为void，入参为(ngx_rbtree_node_t *root, ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel)，别称定义为*ngx_rbtree_insert_pt
typedef void (*ngx_rbtree_insert_pt) (ngx_rbtree_node_t *root,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);

struct ngx_rbtree_s {
    ngx_rbtree_node_t     *root;		//树根
    ngx_rbtree_node_t     *sentinel;	//指向NIL节点，或叫做哨兵节点
    ngx_rbtree_insert_pt   insert;		//添加元素的函数指针，决定新节点是在添加时的具体行为，是替换还是新增
};
```

2. **相关函数**

- 元素插入函数：

上节中，在ngx_rbtree_s结构中，对于插入元素的函数实现，nginx提供了以下几种
```c
//1. 插入的key都不同
//2. 插入的key为时间戳
//以下定义位于ngx_rbtree.h
void ngx_rbtree_insert_value(ngx_rbtree_node_t *root, ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel);
void ngx_rbtree_insert_timer_value(ngx_rbtree_node_t *root,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);
//3. 插入的key有可能相同，但key为字符串
//以下定义位于ngx_string.h
void ngx_str_rbtree_insert_value(ngx_rbtree_node_t *temp,
    ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel);
```
- 作为容器实现的函数：
```c
/* 初始化红黑树，返回空的红黑树
 * tree 是指向红黑树的指针
 * s 是红黑树的一个NIL节点，即哨兵节点
 * i 表示ngx_rbtree_insert_pt类型的函数指针
 */
#define ngx_rbtree_init(tree, s, i)                                           \
    ngx_rbtree_sentinel_init(s);                                              \
    (tree)->root = s;                                                         \
    (tree)->sentinel = s;                                                     \
    (tree)->insert = i

//向树中添加和删除的函数，tree是红黑树指针，node是要添加/删除的节点
void ngx_rbtree_insert(ngx_rbtree_t *tree, ngx_rbtree_node_t *node);
void ngx_rbtree_delete(ngx_rbtree_t *tree, ngx_rbtree_node_t *node);
```
- 作为节点实现的函数：
```c
//设置节点颜色相关
#define ngx_rbt_red(node)               ((node)->color = 1)
#define ngx_rbt_black(node)             ((node)->color = 0)
#define ngx_rbt_is_red(node)            ((node)->color)
#define ngx_rbt_is_black(node)          (!ngx_rbt_is_red(node))
#define ngx_rbt_copy_color(n1, n2)      (n1->color = n2->color)
//初始化哨兵节点
#define ngx_rbtree_sentinel_init(node)  ngx_rbt_black(node)

//找到当前节点及其子树中的最小节点
static ngx_inline ngx_rbtree_node_t * ngx_rbtree_min(ngx_rbtree_node_t *node, ngx_rbtree_node_t *sentinel){...}
```

3. **例子**

```c
/*
blog:   http://blog.csdn.net/u012819339
email:  1216601195@qq.com
author: arvik
*/

#include <stdio.h>
#include <string.h>
#include "ak_core.h"
#include "pt.h"

//树节点定义
typedef struct _testrbn{
    ngx_rbtree_node_t node;	//注意，将node作为struct第一个元素可以灵活转换指针类型，为默认规则
    ngx_uint_t num;
}TestRBTreeNode;

int main(){
    ngx_rbtree_t rbtree;
    ngx_rbtree_node_t sentinel;
    int i=0;
	//init tree  没啥说的，节点插入函数直接使用ngx_rbtree_insert_value
    ngx_rbtree_init(&rbtree, &sentinel, ngx_rbtree_insert_value);

    TestRBTreeNode rbn[10];
    rbn[0].num = 1;
    rbn[1].num = 6;
    rbn[2].num = 8;
    rbn[3].num = 11;
    rbn[4].num = 13;
    rbn[5].num = 15;
    rbn[6].num = 17;
    rbn[7].num = 22;
    rbn[8].num = 25;
    rbn[9].num = 27;

    for(i=0; i<10; i++){
        rbn[i].node.key = rbn[i].num;
		//insert函数保证了树的平衡
        ngx_rbtree_insert(&rbtree, &rbn[i].node);
    }
  
    //查找红黑树中最小节点
    ngx_rbtree_node_t *tmpnode = ngx_rbtree_min(rbtree.root, &sentinel);
    PT_Info("the min key node num val:%u\n", ((TestRBTreeNode *)(tmpnode))->num );

    //演示怎么查找key为13的节点
    ngx_uint_t lookupkey = 13;
    tmpnode = rbtree.root;
    TestRBTreeNode *lknode;
	//找到叶子节点就停止
    while(tmpnode != &sentinel ){
        if(lookupkey != tmpnode->key){
			//红黑树是二叉树的变形，因此如果当前节点的key值大于要寻找的key，则递归遍历左子树；反之，遍历右子树
            tmpnode = (lookupkey < tmpnode->key)?tmpnode->left:tmpnode->right;
            continue;
        }
		 //这里强制转换类型，需要ngx_rbtree_node_t是TestRBTreeNode的第一个成员，也可以用类似于linux内核中的宏定义container_of获取自定义结构体地址
        lknode = (TestRBTreeNode *)tmpnode;
        break;
    }
    PT_Info("fine key == 13 node, TestRBTreeNode.num:%d\n", lknode->num);
    //删除num为13的节点
    ngx_rbtree_delete(&rbtree, &lknode->node);
    PT_Info("delete the node which num is equal to 13 complete!\n");

    return 0;
}

```

### ngx_radix_tree_t

基数树是一种二叉查找树，它具备二叉查找树的全部长处：检索、插入、删除节点速度快，支持范围查找。ngx_radix_tree_t要求存储的每一个节点都必须以32位整型作为唯一标识。
与红黑树或avl树的不同在于，**它的每一个节点key已经决定了这个节点处于树中的位置**，其位置计算为：*将key转化为二进制后，遇到0时进入左子树，遇到1后进入右子树*。另外，通过给基数树分配**掩码**，确定树的有效高度，比如`0Xe0000000（即11100..000）`表示树的高度为3：
```
比如0X20000000在基数树中，其中掩码为0Xe0000000：
		root
	   /\
	  0  1
	 /\  /\
    0 1  0 1 
   /\ /\ /\ /\
  0 1 0 1 ... 
	    此处为0X20000000，树高只有3层
```

ngx_radix_tree_t基数树会负责分配每一个节点占用的内存，基数树的每一个节点中可存储的值仅仅是一个指针，这个指针指向实际的数据。

节点结构ngx_radix_node_t：
```c
typedef struct ngx_radix_node_s  ngx_radix_node_t;
//基数树的节点
struct ngx_radix_node_s {
    ngx_radix_node_t  *right;//右子指针
    ngx_radix_node_t  *left;//左子指针
    ngx_radix_node_t  *parent;//父节点指针
    uintptr_t          value;//指向存储数据的指针
};
//基数树ngx_radix_tree_t:
typedef struct {
    ngx_radix_node_t  *root;//根节点
    ngx_pool_t        *pool;//内存池，负责 分配内存
    ngx_radix_node_t  *free;//回收释放的节点，在加入新节点时，会首先查看free中是否有空暇可用的节点
    char              *start;//已分配内存中还未使用内存的首地址
    size_t             size;//已分配内存内中还未使用内存的大小
} ngx_radix_tree_t;
```
这里要注意free这个成员。它用来回收删除基数树上的节点，并这些节点连接成一个空暇节点链表。当要插入新节点时。首先查看这个链表是否有空暇节点，假设有就不申请节点空间。就从上面取下一个节点。

1. **相关函数**
```c
//创建基数树。preallocate是预分配节点的个数，如果为-1 会根据当前os的一个页面大小来分配
ngx_radix_tree_t *ngx_radix_tree_create(ngx_pool_t *pool, ngx_int_t preallocate);

//依据key值和掩码mask向基数树中插入value,返回值可能是NGX_OK,NGX_ERROR, NGX_BUSY
ngx_int_t ngx_radix32tree_insert(ngx_radix_tree_t *tree, uint32_t key, uint32_t mask, uintptr_t value);

//依据key值和掩码mask删除节点（value的值）
ngx_int_t ngx_radix32tree_delete(ngx_radix_tree_t *tree, uint32_t key, uint32_t mask);

//依据key值在基数树中查找返回value数据
uintptr_t ngx_radix32tree_find(ngx_radix_tree_t *tree, uint32_t key);
```

2. **示例**
```c
#include <stdio.h>
#include <string.h>
#include "ak_core.h"
#include "pt.h"

int main(){
    ngx_pool_t *p;

    p = ngx_create_pool(NGX_DEFAULT_POOL_SIZE); //16KB
    if(p == NULL)
        return -1;

    ngx_radix_tree_t *radixTree = ngx_radix_tree_create(p, -1); //传入-1是想让ngx_pool_t只使用一个页面来尽可能的分配基数树节点
    ngx_uint_t tv1 = 0x20000000;
    ngx_uint_t tv2 = 0x40000000;
    ngx_uint_t tv3 = 0x60000000;
    ngx_uint_t tv4 = 0x80000000;

    //将上述节点添加至radixTree中，掩码0xe0000000
    int rc = NGX_OK;
    rc |= ngx_radix32tree_insert(radixTree, 0x20000000, 0xe0000000, (uintptr_t)&tv1);
    rc |= ngx_radix32tree_insert(radixTree, 0x40000000, 0xe0000000, (uintptr_t)&tv2);
    rc |= ngx_radix32tree_insert(radixTree, 0x60000000, 0xe0000000, (uintptr_t)&tv3);
    rc |= ngx_radix32tree_insert(radixTree, 0x80000000, 0xe0000000, (uintptr_t)&tv4);

    //查找节点
    ngx_uint_t *ptv = (ngx_uint_t *)ngx_radix32tree_find(radixTree, 0x80000000);
    if(ptv == NGX_RADIX_NO_VALUE){
        PT_Warn("not found!\n");
    }
    else
        PT_Info("the node address:%x    val:%x\n", ptv, *ptv);

    ngx_destroy_pool(p);
    return 0;
}
```

### 散列表

#### 基本散列表

没啥说的，使用开放寻址法实现的散列表，定义位于`ngx_hash.h`：
```c
//槽定义
typedef struct {
    void             *value;	//指向用户自定义元素的数据指针，如果槽为空，则为0
    u_short           len;		//元素关键字的长度
    u_char            name[1];	//元素关键字首地址
} ngx_hash_elt_t;

//散列表定义
typedef struct {
    ngx_hash_elt_t  **buckets;	//指向第一个槽的地址
    ngx_uint_t        size;		//散列表槽总数，即容量
} ngx_hash_t;

```

#### 通配符散列表

nginx通过设计散列表hash_combined_t来支持简单的前置/后置通配符。所谓支持通配符的散列表, 就是把基本散列表中元素的关键字, 用去除通配符以后的字符作为关键字加入. 

例如, 对于关键字` www.ben.*`, 这样带通配符的情况, 直接**建立一个专用的后置通配符散列表**, 存储元素的关键字为`www.ben`. 这样, 如果要检索`www.ben.com`是否匹配`www.ben.`, 可以用Nginx提供的方法`ngx_hash_find_wc_tail`检索, 此函数会把要查询的`www.ben.com`转化为`www.ben`，然后在后置通配符散列表中查找。

同理, 对于关键字为`*.ben.com`的元素, 也直接建立一个**前置通配符的散列表**, 存储元素的关键字为`com.ben.`(这里需要注意，前置散列表的key为把通配符去掉后按.分割的倒序，所以为com.ben) , 如果要检索`smtp.ben.com`是否匹配`.ben.com`, 直接使用Nginx提供的 `ngx_hash_find_wc_head`方法查询. 该方法会把要查询的`smtp.ben.com`转化为`com.ben.`，然后在前置通配符散列表中查找。

1. **数据结构**

其数据结构定义如下，位于`/src/core/ngx_hash.h`：
```c
//对ngx_hash_t的简单封装
typedef struct {
    ngx_hash_t        hash;	
    void             *value;	//当作为容器的元素是，指向用户数据
} ngx_hash_wildcard_t;

//通配符散列表定义
typedef struct {
    ngx_hash_t            hash;		//精确匹配的基本散列表
    ngx_hash_wildcard_t  *wc_head;	//前置通配符散列表
    ngx_hash_wildcard_t  *wc_tail;	//后置通配符散列表
} ngx_hash_combined_t;
//通配符查找方法，它将会按照  精确->前置->后置的匹配顺序查找相应的散列表
void *ngx_hash_find_combined(ngx_hash_combined_t *hash, ngx_uint_t key, u_char *name, size_t len);

//精确查询方法
void *ngx_hash_find(ngx_hash_t *hash, ngx_uint_t key, u_char *name, size_t len);
//前置与后置查询方法，name为关键字指针，len为关键字长度
void *ngx_hash_find_wc_head(ngx_hash_wildcard_t *hwc, u_char *name, size_t len);
void *ngx_hash_find_wc_tail(ngx_hash_wildcard_t *hwc, u_char *name, size_t len);
```
2. **初始化**

nginx定义了一个结构体，用于初始化散列表：
```c
typedef struct {
    /* 指向普通的完全匹配散列表 */
    ngx_hash_t       *hash;
    
    /* 用于初始化添加元素的散列方法 */
    ngx_hash_key_pt   key;

    /* 散列表中槽的最大数目 */
    ngx_uint_t        max_size;
    /* 散列表中一个槽的大小，它限制了每个散列表元素关键字的最大长度 */
    ngx_uint_t        bucket_size;

    /* 散列表的名称 */
    char             *name;
    /* 内存池，用于分配散列表（最多3个，包括1个普通散列表、1个前置通配符散列表、1个后置通配符散列表）
     * 中的所有槽 */
    ngx_pool_t       *pool;
    /* 临时内存池，仅存在于初始化散列表之前。它主要用于分配一些临时的动态数组，
     * 带通配符的元素在初始化时需要用到这些数组 */
    ngx_pool_t       *temp_pool;
} ngx_hash_init_t;
```


