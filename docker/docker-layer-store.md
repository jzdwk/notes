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
lrwxrwxrwx 1 root root 72 Jun 20 07:36 6Y5IM2XC7TSNIJZZFLJCS6I4I4 -> ../3a36935c9df35472229c57f4a27105a136f5e4dbef0f87905b2e506e494e348b/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 B3WWEFKBG3PLLV737KZFIASSW7 -> ../4e9fa83caff3e8f4cc83693fa407a4a9fac9573deaf481506c102d484dd1e6a1/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 JEYMODZYFCZFYSDABYXD5MF6YO -> ../eca1e4e1694283e001f200a667bb3cb40853cf2d1b12c29feda7422fed78afed/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 NFYKDW6APBCCUCTOUSYDH4DXAT -> ../223c2864175491657d238e2664251df13b63adb8d050924fd1bfcdb278b866f7/diff
lrwxrwxrwx 1 root root 72 Jun 20 07:36 UL2MW33MSE3Q5VYIKBRN4ZAGQP -> ../e8876a226237217ec61c4baf238a32992291d059fdac95ed6303bdff3f59cff5/diff
```
可以看到，/l目录下的每一个标识符都指向一个layer的diff目录。对于层`3a36935c9df`
