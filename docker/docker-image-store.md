# docker image store

了解docker对于image的存储有助于对docker源码的理解。一般默认安装启动Docker，所有相关的文件都会存储在/var/lib/docker下面，与Image相关的目录主要是image，再下一层是驱动目录名称，Ubuntu 18.04/Docker19.03 为[overlay2](https://docs.docker.com/storage/storagedriver/select-storage-driver/)

定位到/image/overlay2/后，使用`tree`查看目录结构，可以看到：

```
.
├── distribution
│   ├── diffid-by-digest
│   │   └── sha256
│   └── v2metadata-by-diffid
│       └── sha256
├── imagedb
│   ├── content
│   │   └── sha256
│   └── metadata
│       └── sha256
├── layerdb
│   ├── mounts
│   │   ├── 1d61dd1a08616425fea6a39dd8b9f0f5d710555bb0a5a3ae51348501f5a57e2a
...
│   ├── sha256
│   │   ├── 0232ab5d1efed0e8864d830b4179ac3aa3132d83852b41b3e36c92496115320a
...
│   └── tmp
└── repositories.json
```

## repositories.json

repositories.json文件中存储了本地的所有镜像，里面主要涉及了image的name/tag以及image的sha256值，大致内容如下：

```
{"Repositories":{"goharbor/chartmuseum-photon":{"goharbor/chartmuseum-photon:v0.9.0-v1.8.2":"sha256:e72f3e685a37b15a15a0ae1fe1570c4a2e3630df776c48e82e4ef15a3d7c9cba"...
```


## imagedb

imagedb目录中存放了镜像信息。在imagedb下有两个子目录，**metadata**目录保存每个镜像的parent镜像ID，即使用docker build时，就是`FROM XXX`的镜像XXX信息。另一个是**content**目录，该目录下存储了镜像的JSON格式描述信息，文件名以image的sha256形式保存。比如cat一个具体的content下busybox镜像文件，可以看到：

```
{
  "architecture": "amd64",
  "config": {
    "Hostname": "",
    "Domainname": "",
    "User": "",
    "AttachStdin": false,
    "AttachStdout": false,
    "AttachStderr": false,
    "Tty": false,
    "OpenStdin": false,
    "StdinOnce": false,
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ],
    "Cmd": [
      "sh"
    ],
    "ArgsEscaped": true,
    "Image": "sha256:b0acc7ebf5092fcdd0fe097448529147e6619bd051f03ccf25b29bcae87e783f",
    "Volumes": null,
    "WorkingDir": "",
    "Entrypoint": null,
    "OnBuild": null,
    "Labels": null
  },
  "container": "f7e67f16a539f8bbf53aae18cdb5f8c53e6a56930e7660010d9396ae77f7acfa",
  "container_config": {
    "Hostname": "f7e67f16a539",
    "Domainname": "",
    "User": "",
    "AttachStdin": false,
    "AttachStdout": false,
    "AttachStderr": false,
    "Tty": false,
    "OpenStdin": false,
    "StdinOnce": false,
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ],
    "Cmd": [
      "/bin/sh",
      "-c",
      "#(nop) ",
      "CMD [\"sh\"]"
    ],
    "ArgsEscaped": true,
    "Image": "sha256:b0acc7ebf5092fcdd0fe097448529147e6619bd051f03ccf25b29bcae87e783f",
    "Volumes": null,
    "WorkingDir": "",
    "Entrypoint": null,
    "OnBuild": null,
    "Labels": {}
  },
  "created": "2020-04-14T19:19:53.590635493Z",
  "docker_version": "18.09.7",
  "history": [
    {
      "created": "2020-04-14T19:19:53.444488372Z",
      "created_by": "/bin/sh -c #(nop) ADD file:09a89925137e1b768ef1f0e7d1d7325eb2b4f1a0895b3aa8dfc98b0c75f3f507 in / "
    },
    {
      "created": "2020-04-14T19:19:53.590635493Z",
      "created_by": "/bin/sh -c #(nop)  CMD [\"sh\"]",
      "empty_layer": true
    }
  ],
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:5b0d2d635df829f65d0ffb45eab2c3124a470c4f385d6602bda0c21c5248bcab"
    ]
  }
}
```

其中：

- **config**: 未来根据这个image启动container时，config里面的配置就是运行container时的默认参数。

- **container**: 此处为一个容器ID，执行docker build构建镜像时，可以看见是不断地生成新的container，然后提交为新的image，此处的容器ID即生成该镜像时临时容器的ID

- **container_config**：上述临时容器的配置，可以对比containner_config与config的内容，字段完全一致，验证了config的作用。

- **history**：构建该镜像的所有历史命令

- **rootfs**：该镜像包含的layer层的diff id，这里的值主要用于描述layer，但注意*此处的diff_id不一定等于layer下的对应id*,另外，diff_id的个数也不一定等于在Dockerfile中Run的命令数，*事实上，如果我们认为镜像是一个打包的静态OS，那么Layer可以认为是描述该OS的fs变化，即文件系统中文件或者目录发生的改变，有些命令并不会引起fs的变化，只是会写入该镜像的config中，在生成容器时读取即可，就不存在diff id*

## layerdb

layerdb根据命名即可理解该目录主要用来存储Docker的Layer信息，layerdb的大致结构如下：

```
layerdb/
├── mounts
├── sha256
│   ├── 0e88764cdf90e8a5d6597b2d8e65b8f70e7b62982b0aee934195b54600320d47
│   │   ├── cache-id
│   │   ├── diff
│   │   ├── parent
│   │   ├── size
│   │   └── tar-split.json.gz
│   ├── 7bff100f35cb359a368537bb07829b055fe8e0b1cb01085a3a628ae9c187c7b8
│   │   ├── cache-id
│   │   ├── diff
│   │   ├── size
│   │   └── tar-split.json.gz
│   ├── 80fe1abae43103e3be54ac2813114d1dea6fc91454a3369104b8dd6e2b1363f5
│   │   ├── cache-id
│   │   ├── diff
│   │   ├── parent
│   │   ├── size
│   │   └── tar-split.json.gz
│   └── db7c15c2f03f63a658285a55edc0a0012ccd0033f4695d4b428b1b464637e655
│       ├── cache-id
│       ├── diff
│       ├── parent
│       ├── size
│       └── tar-split.json.gz
└── tmp
```

- **mount**: 当由镜像生成容器时，该目录下会生成容器的可读可写两个layer，可读即为由镜像生成，而可写就是未来对容器的修改的存放位置
- **sha256**: 主要存储的就是layer，注意这里存储的sha256值是layer的chainId，而非在imagedb里的json描述的diff_id，diff_id用来描述单个变化，而chainId用来便于一些列的变化，diff id和chain id之间的计算公式为，其中A表示单层layer，A|B表示在A之上添加了layerB，A是B的父layer，同理于A|B|C：

```
ChainID(A) = DiffID(A)
ChainID(A|B) = Digest(ChainID(A) + " " + DiffID(B))
ChainID(A|B|C) = Digest(ChainID(A|B) + " " + DiffID(C))
```

进入某个sha256目录，里面的`diff`就描述了该Layer层的diff_id;`size`描述了该Layer的大小，单位字节；`tar-split.json.gz`表示layer层数据tar压缩包的split文件，该文件生成需要依赖tar-split，通过这个文件可以还原layer的tar包。`cache_id`内容为一个uuid，指向Layer本地的真正存储位置。而这个真正的存储位置便是**/var/lib/docker/overlay2**目录

## distribution

distribution目录包含了Layer层diif_id和manifest digest之间的对应关系，**manifest digest是由镜像仓库生成或维护，本地构建的镜像在没有push到仓库之前，没有manifest digest**，当执行push/pull时，镜像仓库需要通过digest来对应到具体的layer上，即distribution的作用。它的结构大致如下：

```
distribution/
├── diffid-by-digest
│   └── sha256
│       └── cd784148e3483c2c86c50a48e535302ab0288bebd587accf40b714fffd0646b3
└── v2metadata-by-diffid
    └── sha256
        └── 7bff100f35cb359a368537bb07829b055fe8e0b1cb01085a3a628ae9c187c7b8
```

这个结构里有两个目录:

- **v2metadata-by-diffid**: v2metadata-by-diffid目录下，可以通过Layer的diff_id找到对应的digest描述，并且包含了生成该digest的源仓库,比如本地的busybox镜像diff_id的描述：

```
cat 5b0d2d635df829f65d0ffb45eab2c3124a470c4f385d6602bda0c21c5248bcab

[
  {
    "Digest": "sha256:e2334dd9fee4b77e48a8f2d793904118a3acf26f1f2e72a3d79c6cae993e07f0",
    "SourceRepository": "docker.io/library/busybox",
    "HMAC": ""
  },
  {
    "Digest": "sha256:e2334dd9fee4b77e48a8f2d793904118a3acf26f1f2e72a3d79c6cae993e07f0",
    "SourceRepository": "myharbor.com/usr1test0/busybox",
    "HMAC": "f2018b1faf11bbe4a7fcc951bdab9b1f1b356603c059fc8e8a50785ef27bbe0c"
  }
  ...
]
```
busybox的镜像打了不同的tag，所以，对于一份busybox，存在一个唯一的imageId描述，这个iamgeId在imagedb里描述了diff_id，也就是layer id，对应此处的digest。

- **diffid-by-digest**: diffid-by-digest目录则与v2metadata-by-diffid相反，通过digest来得到对应的layer id，如

```
cat e2334dd9fee4b77e48a8f2d793904118a3acf26f1f2e72a3d79c6cae993e07f0

sha256:5b0d2d635df829f65d0ffb45eab2c3124a470c4f385d6602bda0c21c5248bcabroot@myharbor
```

## 总结

docker image目录下的repositories.json是一个总的*索引文件*，记录了本地image的name:sha256 id的基本映射信息（把一个镜像tag为另一个时，两个tag的镜像都指向同一个image sha256 id，所以这个命令相当于只有修改了repositories.json）。根据这个sha256 id，可以在iamgedb里找到这个image的详细config以及parent信息。根据详细的config，则可以对应到这个image的layer上去，即diff_id。这个diff_id有两个用途：
1. 根据diff_id，在layerdb中定位实际的layer存储位置、size、tar包
2. 根据diff_id，在distribution中，得到仓库相关的digest信息，用于pull/push操作。



