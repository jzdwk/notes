# docker layer store

`/var/lib/docker/image/...`目录中，存储了docker image的结构、层关系等信息，具体可参考[docker image store](docker-image-store.md)。而每一个image由多个只读层构成，其只读层的存储则位于其他目录。image目录中在image/overlay2/layerdb中与其关联。

docker的层存储位于目录`/var/lib/docker/{driver_name}/...`，主要分析**overlay2**的存储结构。


## overlay2

[docker overlay2](https://docs.docker.com/storage/storagedriver/overlayfs-driver/) 的存储设计可以参考官方文档。

## 目录

所有的和layer相关的数据都存储在`/var/lib/docker/overlay2/...`目录中，假设使用docker pull拉下ubuntu镜像后，其目录结构如下：
```
$ ls -l /var/lib/docker/overlay2

total 24
drwx------ 5 root root 4096 Jun 20 07:36 223c2864175491657d238e2664251df13b63adb8d050924fd1bfcdb278b866f7
drwx------ 3 root root 4096 Jun 20 07:36 3a36935c9df35472229c57f4a27105a136f5e4dbef0f87905b2e506e494e348b
drwx------ 5 root root 4096 Jun 20 07:36 4e9fa83caff3e8f4cc83693fa407a4a9fac9573deaf481506c102d484dd1e6a1
drwx------ 5 root root 4096 Jun 20 07:36 e8876a226237217ec61c4baf238a32992291d059fdac95ed6303bdff3f59cff5
drwx------ 5 root root 4096 Jun 20 07:36 eca1e4e1694283e001f200a667bb3cb40853cf2d1b12c29feda7422fed78afed
drwx------ 2 root root 4096 Jun 20 07:36 l
```
该目录由两部分构成，一是以layer_id，二是/l目录。对于layer_id，和image的关联位于目录`.../docker/image/overlay2/layerdb/sha256/{layer_chain_id}/cache-id`中，整体的关联关系是：

1. image中存储了镜像的sha256,

2. 根据镜像的sha256，在`.../image/overlay2/imagedb/content/sha256/{image_id}`文件中，找到该镜像的配置信息，主要是diff_ids

3. 根据diff_ids的描述顺序，计算layer_chain_id

4. 根据layer_chain_id，在`.../docker/image/overlay2/layerdb/sha256/{chain_id}`目录中，找到对应layer存储，即文件cache-id中的layer_id

5. 最后，根据文件cache-id中的layer_id中的描述，在层存储目录`.../docker/overlay2/{layer_id}/...`中定位layer

另外，在`/l/..`中，保存了和layer(layer_id)一一对应的link，目的在于缩短参数，避免达到mount命令的参数大小限制，建立连接后的目录如下：
```
$ ls -l /var/lib/docker/overlay2/l

total 20
//link_id ---> layer/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 6Y5IM2XC7TSNIJZZFLJCS6I4I4 -> ../3a36935c9df35472229c57f4a27105a136f5e4dbef0f87905b2e506e494e348b/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 B3WWEFKBG3PLLV737KZFIASSW7 -> ../4e9fa83caff3e8f4cc83693fa407a4a9fac9573deaf481506c102d484dd1e6a1/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 JEYMODZYFCZFYSDABYXD5MF6YO -> ../eca1e4e1694283e001f200a667bb3cb40853cf2d1b12c29feda7422fed78afed/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 NFYKDW6APBCCUCTOUSYDH4DXAT -> ../223c2864175491657d238e2664251df13b63adb8d050924fd1bfcdb278b866f7/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 UL2MW33MSE3Q5VYIKBRN4ZAGQP -> ../e8876a226237217ec61c4baf238a32992291d059fdac95ed6303bdff3f59cff5/diff
```
可以看到，/l目录下的每一个标识符都指向一个layer的**diff目录**，这个diff目录中就保存了该层的只读目录。对于最底层（根layer）`3a36935c9df`,其目录下内容为：
```
$ ls /var/lib/docker/overlay2/3a36935c9df35472229c57f4a27105a136f5e4dbef0f87905b2e506e494e348b/
diff  link
$ cat /var/lib/docker/overlay2/3a36935c9df35472229c57f4a27105a136f5e4dbef0f87905b2e506e494e348b/link
6Y5IM2XC7TSNIJZZFLJCS6I4I4

$ ls  /var/lib/docker/overlay2/3a36935c9df35472229c57f4a27105a136f5e4dbef0f87905b2e506e494e348b/diff
bin  boot  dev  etc  home  lib  lib64  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var
```
该目录下的diff保存了该层的所有只读层信息，可以看到常见的/bin,/boot,/dev等等。另一个link文件存储了link_id。

再看上层的layer`223c286417`:
```
$ ls /var/lib/docker/overlay2/223c2864175491657d238e2664251df13b63adb8d050924fd1bfcdb278b866f7
diff  link  lower  merged  work   //多出了lower merged和work

$ cat /var/lib/docker/overlay2/223c2864175491657d238e2664251df13b63adb8d050924fd1bfcdb278b866f7/lower
l/6Y5IM2XC7TSNIJZZFLJCS6I4I4 //lower中内容指向了parent层的link_id

$ ls /var/lib/docker/overlay2/223c2864175491657d238e2664251df13b63adb8d050924fd1bfcdb278b866f7/diff/
etc  sbin  usr  var
```
除了和上一层相同的`/diff  /link`外，多出了`/lower` ,这个lower中的内容指向了父layer的link id，比如例子的`6Y5IM2XC7TSNIJZZFLJCS6I4I4`。而`/merged`目录用于结合本层layer和父层layer，主要目的是为container提供统一的fs视图。

## overlay2上的读写

overlayFS工作在两个层，`lowerdir`和`upperdir`，lowerdir就是当前容器layer的父layer，是只读的image layer，upperdir即容器本层，即可读写的container layer。

### 读场景

- 当文件不存在于container layer时，将读取image layer.

- 当文件只存在于container layer时，将直接读取。

- 当文件在image layer和container layer上，则优先读取container layer.

### 写场景

- 当第一次写文件时，如果文件不存在，则会执行`copy_up`操作，从image layer将目标文件copy到container layer后进行操作

- 删除文件或者目录是，如果删除的是文件，通过在container layer创建一个` whiteout file`使文件不可访问;如果是目录，则创建`opaque directory`来屏蔽目标目录的访问。

- 重命名一个目录时，需要满足**目标和源目录都必须在container layer**

## overlayFS的问题

- open(2):由于`copy_up`机制，当进行两次的读操作，且目标位于image layer时，会有`fd1=open("foo", O_RDONLY) ;fd2=open("foo", O_RDWR);fd1 != fd2;`原因在于，fd1返回只读的file，所以fd1的引用为image layer，而fd2返回的是可读写layer，所以fd2的引用为container layer.

- rename(2):OverlayFS并不完全支持rename(2)的系统调用.

