# docker image 管理

主要记录docker 的 Image设计以及代码分析

## 概念

### rootfs

全称是root file system，这是一个linux系统中的根文件系统 一个典型的Linux系统要能运行的话，它至少需要两个文件系统：

- boot file system （bootfs）：包含bootloader和 kernel。用户不会修改这个文件系统。在boot过程完成后，整个内核都会被加载进内存，此时bootfs 会被卸载掉从而释放出所占用的内存。对于同样内核版本的不同的Linux发行版的bootfs都是一致的。

- root file system （rootfs）：包含典型的目录结构，包括dev,proc,bin,etc,lib,usr,tmp 等再加上要运行用户应用所需要的所有配置文件，二进制文件和库文件。这个文件系统在不同的Linux 发行版中是不同的。而且用户可以对这个文件进行修改。

Linux操作系统内核启动时，内核首先会挂载一个只读( read-only)的rootfs，
当系统检测其完整性之后，决定是否将其切换为读写( read-write) 模式，或者最后在rootfs
之上另行挂载一种文件系统并忽略rootfs。

Docker架构下依然沿用Linux 中rootfs的思想。
当Docker Daemon为Docker容器挂载rootfs的时候，与传统Linux内核类似，将其设定为只
读模式。不同的是，docker在挂载rootfs之后，**并没有将docker容器的文件系统设为读写模式**，而是利用**Union Mount** 的技术，**在这个只读的rootfs之上再
挂载一个读写的文件系统**，挂载时该读写文件系统内空无一物。

### unionfs

全称是union file system， 代表一种文件系统挂载方式，允许同一时刻多种文件系统叠加挂载在一起，
并以一种文件系统的形式，呈现多种文件系统内容合并后的目录。举个例子：

```
$ tree
.
├── fruits
│   ├── apple
│   └── tomato
└── vegetables
    ├── carrots
    └── tomato
```

上面的目录结构，经过union mount：

```
$ sudo mount -t aufs -o dirs=./fruits:./vegetables none ./mnt
$ tree ./mnt
./mnt
├── apple
├── carrots
└── tomato
```

通常来讲，被合并的文件系统中只有一个会以读写(read-write)模式挂载，其他文件系统的挂载模式均
为只读( read-only)。实现这种Union Mount技术的文件系统一般称为联合文件系统(Union
Filesystem)，较为常见的有UnionFS、aufs 、OverlayFS 等

基于此，docker在所创建的容器中使用文件系统时，从内核角度来看，将出现rootfs以及一个可读写的文件系统，并通过union mount进行合并。所有的配置、install都是在读写层进行的，即使是删除操作，也是在读写层进行，只读层永远不会变。对于用户来说，感知不到这两个层次，只会通过fs的COW (copy-on-write)特性看到操作结果。

### image

最为简单地解释image,它就是Docker容器中只读文件系统rootfs的一部分。Docker容器的rootfs可以由多个image 来构成。多个image构成 rootfs的方式依然沿用Union Mount技术。下例为镜像层次从上至下：

- image_n: /lib /etc
- image_2：/media /opt /home
- image_1：/var /boot /proc

比如上面的例子，rootfs被分成了n层，每一层包含其中的一部分，每一层的image都叠加在另一个image之上。基于以上概念，docker iamge产生两种概念:

- 父镜像：其余镜像都依赖于其底下的一个或多个镜像，Docker将下一层的镜像称为上一层镜像的父镜像。如image_1是image_2的父镜像。

- 基础镜像： rootfs最底层镜像，没有父镜像，如image_1。

将一个整体的image拆分，就能够对子image进行复用，比如一个mysql和一个ubuntu的应用，复用的例子就如下：

- image_0-> image_1-> image_3->image_4（ubuntu）->image_5(mysql)

需要注意，以上描述的多个image分层，都是**只读分层**

### layer

除了只读的image之外，Docker Daemon在创建容器时会在容器的rootfs之上，再挂载
一层读写文件系统，而这一层文件系统也称为容器的一个layer ，常被称为 top layer， Docker还会在rootfs和top layer 之间再挂载一个layer ，这一个 layer中主要包含/etc/hosts,/etc/hostname 以及/etc/resolv.conf，一般这一个layer称为init layer。
Docker容器中每一层只读的image 以及最上层可读写的文件系统，均称为layer。**layer的范畴比image多包含了最上层的读写文件系统。**

另外，根据image层次的复用逻辑，docker在设计时，**提供了commit和基于dockerfile的build来将top layer转变为image**。开发者可以基于某个镜像创
建容器做开发工作，并且无论在开发周期的哪个时间点，都可以对容器进行commit,将所
有top layer中的内容打包为一个image ，构成一个新的镜像。

## pull image

镜像pull首先是要执行docker pull命令。从命令可以看出，是docker client首先发送pull请求至docker daemon. Docker Daemon在执行这条命令时，会将Docker Image从Docker Registry下载至本地，并保存在本地Docker Daemon管理的Graph中。其流程总结为：

1. 用户通过Docker Client发送pull请求，用于让Docker Daemon下载指定名称的镜像
2. Docker Server接收Docker镜像的pull请求，创建下载镜像任务并触发执行
3. Docker Daemon执行镜像下载任务，从Docker Registry中下载指定镜像，并将其存储于本地的Graph中。

### docker client

在docker client的笔记中，讲解了client的整体工作机制，镜像下载使用了docker image pull，就以`docker image pull test/hello-world:1.0`举例说明，其实发送http请求的套路和所有命令都一致，就看下后面的参数（args）怎么解析。

1. 在3级命令NewPullCommand中，首先取到了args\[0\],即`test/hello-world:1.0`这个值，并将其赋值给了remote域，然后进入RunPull函数：

```
	cmd := &cobra.Command{
		Use:   "pull [OPTIONS] NAME[:TAG|@DIGEST]",
		Short: "Pull an image or a repository from a registry",
		Args:  cli.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.remote = args[0]
			return RunPull(dockerCli, opts)
		},
	}
```

2. 进入RunPull，主要关注opts参数，在第一句就对这个remote做了解析,`distributionRef, err := reference.ParseNormalizedNamed(opts.remote)`,进入这个prase函数，可以看到其主要工作是解析remote后将其封装为一个Named接口，这个接口的实现有。代码的大致逻辑为：

```
	//合法性检查
	...
	//根据test/hello-world:1.0 解析中其中的仓库地址domamin，以及repo镜像/tag
	//其中splictDockerDomain对应3中情况:
	//1.address/repo/image:tag  2.repo/image:tag 3.image:tag 4.image
	//对于3,4,domain = defaultDomain(docker.io);对于1,domain为address;对于3,4 将默认使用library作为repo
	domain, remainder := splitDockerDomain(s)
	var remoteName string
	if tagSep := strings.IndexRune(remainder, ':'); tagSep > -1 {
		remoteName = remainder[:tagSep]
	} else {
		remoteName = remainder
	}
	...
	//返回具体的Named实现，包括了digestReference canonicalReference  taggedReference
	ref, err := Parse(domain + "/" + remainder)
    ...
	named, isNamed := ref.(Named)
	if !isNamed {
		return nil, fmt.Errorf("reference %s has no name", ref.String())
	}
	return named, nil
```

3. 解析完成后，将对registry的信息，以及认证信息做进一步的封装，封装的结构体如下：

```
type ImageRefAndAuth struct {
	original   string
	authConfig *types.AuthConfig
	reference  reference.Named
	repoInfo   *registry.RepositoryInfo
	tag        string
	digest     digest.Digest
}
```

其具体实现的函数为`imgRefAndAuth, err := trust.GetImageReferencesAndAuth(ctx, nil, AuthResolver(cli), distributionRef.String())`,其中AuthResolver返回了一个函数func变量`func(ctx context.Context, index *registrytypes.IndexInfo) types.AuthConfig`,如下所示：

```
func AuthResolver(cli command.Cli) func(ctx context.Context, index *registrytypes.IndexInfo) types.AuthConfig {
	return func(ctx context.Context, index *registrytypes.IndexInfo) types.AuthConfig {
		return command.ResolveAuthConfig(ctx, cli, index)
	}
}
```

因此，当AuthResolver被调用时，将根据传入的实际参数，调用command.ResolveAuthConfig(ctx, cli, index)，这个函数的大致逻辑为读取**docker的config.json**里内容，获取认证信息。(*思考？为何在GetImageReferencesAndAuth中使用函数变量，而不是在函数中直接调用呢？答：这样实现了认证信息的解耦，在GetImageReferencesAndAuth的形参中，只需要定义一个函数变量，规定其入参和返回值，而调用者根据实际情况，可选择传入AuthResolver的实现或者Othersolver，对于GetImageReferencesAndAuth内部，则不用关心。否则，其内部的调用逻辑将随着不同认证信息的获取方式改变而难以维护*)

4. 之后，根据cli以及ImageRefAndAuthde的信息，调用`imagePullPrivileged`执行pull操作。在这个函数中，主要是对镜像信息ref和认证信息encodeAuth做了进一步的封装，即options：
```
	options := types.ImagePullOptions{
		RegistryAuth:  encodedAuth,
		PrivilegeFunc: requestPrivilege,
		All:           opts.all,
		Platform:      opts.platform,
	}
```
最后调用client的`ImagePull`函数进行请求的发送，核心的逻辑为首先向daemon的api请求`cli.post(ctx, "/images/create"`，如果需要认证，则调用注册的认证func PrivilegeFunc处理认证信息后重新发送请求：
```
	resp, err := cli.tryImageCreate(ctx, query, options.RegistryAuth)
	if errdefs.IsUnauthorized(err) && options.PrivilegeFunc != nil {
		newAuthHeader, privilegeErr := options.PrivilegeFunc()
		if privilegeErr != nil {
			return nil, privilegeErr
		}
		resp, err = cli.tryImageCreate(ctx, query, newAuthHeader)
	}
```

### docker daemon

docker daemon的api相关代码位于docker-ce/engine/api/server/router/\*，并根据不同的模块分为了container，network，image等包。根据client端的pull请求，定位到以下path定义：
```
func (r *imageRouter) initRoutes() {
	r.routes = []router.Route{
		// GET
		router.NewGetRoute("/images/json", r.getImagesJSON),
		router.NewGetRoute("/images/search", r.getImagesSearch),
		router.NewGetRoute("/images/get", r.getImagesGet),
		router.NewGetRoute("/images/{name:.*}/get", r.getImagesGet),
		router.NewGetRoute("/images/{name:.*}/history", r.getImagesHistory),
		router.NewGetRoute("/images/{name:.*}/json", r.getImagesByName),
		// POST
		router.NewPostRoute("/images/load", r.postImagesLoad),
		router.NewPostRoute("/images/create", r.postImagesCreate),
		router.NewPostRoute("/images/{name:.*}/push", r.postImagesPush),
		router.NewPostRoute("/images/{name:.*}/tag", r.postImagesTag),
		router.NewPostRoute("/images/prune", r.postImagesPrune),
		// DELETE
		router.NewDeleteRoute("/images/{name:.*}", r.deleteImages),
	}
}
```
进入对应的postImageCreate函数，这里主要进行了一些参数的解析，包括请求的image信息和auth信息，解析后直接调用后端的PullImage函数：
```
	//解析请求参数
	var (
		image    = r.Form.Get("fromImage")  //hello-world
		repo     = r.Form.Get("repo") //test
		tag      = r.Form.Get("tag") //1.0
		message  = r.Form.Get("message")
		err      error
		output   = ioutils.NewWriteFlusher(w)
		platform *specs.Platform
	)
	...
	if image != "" { // pull
		metaHeaders := map[string][]string{}
		for k, v := range r.Header {
			if strings.HasPrefix(k, "X-Meta-") {
				metaHeaders[k] = v
			}
		}

		authEncoded := r.Header.Get("X-Registry-Auth")
		authConfig := &types.AuthConfig{}
		//解析auth
		if authEncoded != "" {
			authJSON := base64.NewDecoder(base64.URLEncoding, strings.NewReader(authEncoded))
			if err := json.NewDecoder(authJSON).Decode(authConfig); err != nil {
				authConfig = &types.AuthConfig{}
			}
		}
		//核心函数，image=hello-word tag=1.0 platform= metaHeaders=X-Meta相关 authConfig认证 output为stdout输出
		err = s.backend.PullImage(ctx, image, tag, platform, metaHeaders, authConfig, output)
	} else {
		//import
	}
	if err != nil {
		...
		_, _ = output.Write(streamformatter.FormatError(err))
	}

	return nil
```

PullImage函数在registryBackend接口中定义，由ImageService实现。在函数内部，经过解析image/tag以及auth信息，调用pullImageWithReference来进行,这个函数的主要作用是定义了两个chan,progressChan用于打印pull进度，writesDone是个无缓冲chan，用于标识完成pull。cancelFunc则定义了一组资源清理的逻辑，当使用goroutine读取进度progress过程中出错，则进行资源清理。最后，在进行了进一步的封装后，调用distribution.Pull函数。

```
	progressChan := make(chan progress.Progress, 100)
	writesDone := make(chan struct{})
	ctx, cancelFunc := context.WithCancel(ctx)

	go func() {
		progressutils.WriteDistributionProgress(cancelFunc, outStream, progressChan)
		...
	}()

	imagePullConfig := &distribution.ImagePullConfig{
		Config: distribution.Config{
			MetaHeaders:      metaHeaders,
			AuthConfig:       authConfig,
			ProgressOutput:   progress.ChanOutput(progressChan),
			RegistryService:  i.registryService,
			ImageEventLogger: i.LogImageEvent,
			MetadataStore:    i.distributionMetadataStore,
			ImageStore:       distribution.NewImageConfigStoreFromStore(i.imageStore),
			ReferenceStore:   i.referenceStore,
		},
		DownloadManager: i.downloadManager,
		Schema2Types:    distribution.ImageTypes,
		Platform:        platform,
	}

	err := distribution.Pull(ctx, ref, imagePullConfig)
	<-writesDone
```

进入distribution.Pull函数，其中是一个解析过程，获取repo和endpoints，并根据解析的endpoints信息，得到一个v2Puller对象*（注意这个v2puller是在new中写死的？是否可以解耦）*,这个对象实现了Puller接口，代码如下：

```
	//根据ref信息解析出test/hello-world
	repoInfo, err := imagePullConfig.RegistryService.ResolveRepository(ref)
	....
	//解析出test， 注意此时的endpoints为一个切片，原因为docker pull 后可跟多个镜像参数 so 多endpoint？
	endpoints, err := imagePullConfig.RegistryService.LookupPullEndpoints(reference.Domain(repoInfo.Name))
	...
	for _, endpoint := range endpoints {
		//根据api版本初始不同配置信息
		...
		puller, err := newPuller(endpoint, repoInfo, imagePullConfig)
		...
		if err := puller.Pull(ctx, ref, imagePullConfig.Platform); err != nil {
			...error handler
		}
```

再看v2puller对于pull的实现，首先根据之前的配置和参数，New了一个Repository对象，这个对象里主要是创建http client，并加入认证信息，以及根据endpoint进行了ping操作：

```
	p.repo, p.confirmedV2, err = NewV2Repository(ctx, p.repoInfo, p.endpoint, p.config.MetaHeaders, p.config.AuthConfig, "pull")

	if err = p.pullV2Repository(ctx, ref, platform); err != nil {
		...
	}
	return err
```

进入pullV2Repository,根据在image参数中是否含有tag走了不同的分支，不再赘述，这个函数最终又调用了pullV2Tag。这是pull过程的核心逻辑。在了解核心逻辑前，需要对docker image的各个概念以及存储有一个简单了解，[请移步](https://github.com/jzdwk/notes/blob/master/docker/docker%20image%20store.md)

docker pull从整体上来说，做了以下工作：

1. docker daemon发送image的name:tag/digest给registry服务器，服务器根据收到的image info，找到相应image的manifest，然后将manifest返回给docker daemon

2. docker daemon得到manifest后，读取里面image配置文件的digest(sha256)，即image的ID

3. 根据ID在本地找有没有存在同样ID的image，有的话就不用继续下载了

4. 如果没有，那么会给registry服务器发请求（里面包含配置文件的sha256和media type），拿到image的配置文件（Image Config）

5. 根据配置文件中的diff_ids（每个diffid对应一个layer tar包的sha256，tar包相当于layer的原始格式），在本地找对应的layer是否存在

6. 如果layer不存在，则根据manifest里面layer的sha256和media type去服务器拿相应的layer（相当去拿压缩格式的包）。

7. 拿到后进行解压，并检查解压后tar包的sha256能否和配置文件（Image Config）中的diff_id对的上，对不上说明有问题，下载失败

8. 根据docker所用的后台文件系统类型，解压tar包并放到指定的目录

9. 等所有的layer都下载完成后，整个image下载完成，就可以使用了

```
manSvc, err := p.repo.Manifests(ctx)
	if err != nil {
		return false, err
	}

	var (
		manifest    distribution.Manifest
		tagOrDigest string // Used for logging/progress only
	)
	if digested, isDigested := ref.(reference.Canonical); isDigested {
		manifest, err = manSvc.Get(ctx, digested.Digest())
		if err != nil {
			return false, err
		}
		tagOrDigest = digested.Digest().String()
	} else if tagged, isTagged := ref.(reference.NamedTagged); isTagged {
		manifest, err = manSvc.Get(ctx, "", distribution.WithTag(tagged.Tag()))
		if err != nil {
			return false, allowV1Fallback(err)
		}
		tagOrDigest = tagged.Tag()
	} else {
		return false, fmt.Errorf("internal error: reference has neither a tag nor a digest: %s", reference.FamiliarString(ref))
	}

	if manifest == nil {
		return false, fmt.Errorf("image manifest does not exist for tag or digest %q", tagOrDigest)
	}

	if m, ok := manifest.(*schema2.DeserializedManifest); ok {
		var allowedMediatype bool
		for _, t := range p.config.Schema2Types {
			if m.Manifest.Config.MediaType == t {
				allowedMediatype = true
				break
			}
		}
		if !allowedMediatype {
			configClass := mediaTypeClasses[m.Manifest.Config.MediaType]
			if configClass == "" {
				configClass = "unknown"
			}
			return false, invalidManifestClassError{m.Manifest.Config.MediaType, configClass}
		}
	}

	// If manSvc.Get succeeded, we can be confident that the registry on
	// the other side speaks the v2 protocol.
	p.confirmedV2 = true

	logrus.Debugf("Pulling ref from V2 registry: %s", reference.FamiliarString(ref))
	progress.Message(p.config.ProgressOutput, tagOrDigest, "Pulling from "+reference.FamiliarName(p.repo.Named()))

	var (
		id             digest.Digest
		manifestDigest digest.Digest
	)

	switch v := manifest.(type) {
	case *schema1.SignedManifest:
		if p.config.RequireSchema2 {
			return false, fmt.Errorf("invalid manifest: not schema2")
		}

		// give registries time to upgrade to schema2 and only warn if we know a registry has been upgraded long time ago
		// TODO: condition to be removed
		if reference.Domain(ref) == "docker.io" {
			msg := fmt.Sprintf("Image %s uses outdated schema1 manifest format. Please upgrade to a schema2 image for better future compatibility. More information at https://docs.docker.com/registry/spec/deprecated-schema-v1/", ref)
			logrus.Warn(msg)
			progress.Message(p.config.ProgressOutput, "", msg)
		}

		id, manifestDigest, err = p.pullSchema1(ctx, ref, v, platform)
		if err != nil {
			return false, err
		}
	case *schema2.DeserializedManifest:
		id, manifestDigest, err = p.pullSchema2(ctx, ref, v, platform)
		if err != nil {
			return false, err
		}
	case *ocischema.DeserializedManifest:
		id, manifestDigest, err = p.pullOCI(ctx, ref, v, platform)
		if err != nil {
			return false, err
		}
	case *manifestlist.DeserializedManifestList:
		id, manifestDigest, err = p.pullManifestList(ctx, ref, v, platform)
		if err != nil {
			return false, err
		}
	default:
		return false, invalidManifestFormatError{}
	}

	progress.Message(p.config.ProgressOutput, "", "Digest: "+manifestDigest.String())

	if p.config.ReferenceStore != nil {
		oldTagID, err := p.config.ReferenceStore.Get(ref)
		if err == nil {
			if oldTagID == id {
				return false, addDigestReference(p.config.ReferenceStore, ref, manifestDigest, id)
			}
		} else if err != refstore.ErrDoesNotExist {
			return false, err
		}

		if canonical, ok := ref.(reference.Canonical); ok {
			if err = p.config.ReferenceStore.AddDigest(canonical, id, true); err != nil {
				return false, err
			}
		} else {
			if err = addDigestReference(p.config.ReferenceStore, ref, manifestDigest, id); err != nil {
				return false, err
			}
			if err = p.config.ReferenceStore.AddTag(ref, id, true); err != nil {
				return false, err
			}
		}
	}
	return true, nil
```


