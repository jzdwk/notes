# docker image push

记录docker image push的实现过程

## docker client

push image和pull image在client端的代码结构相似，定位到`docker/cli/cli/command/image/push.go`中的NewPushCommand函数：
```
func NewPushCommand(dockerCli command.Cli) *cobra.Command {
	var opts pushOptions

	cmd := &cobra.Command{
		Use:   "push [OPTIONS] NAME[:TAG]",
		Short: "Push an image or a repository to a registry",
		Args:  cli.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			opts.remote = args[0]
			return RunPush(dockerCli, opts)
		},
	}

	flags := cmd.Flags()
	flags.BoolVarP(&opts.quiet, "quiet", "q", false, "Suppress verbose output")
	command.AddTrustSigningFlags(flags, &opts.untrusted, dockerCli.ContentTrustEnabled())

	return cmd
}
```
可以看到一个cobra的docker push命令定义，当push一个本地的镜像如myharbor.com/test1/image1:1.0时，这个值作为opts.remote传入RunPush，进入RunPush函数，首先做的就是解析myharbor.com/test1/image1:1.0，将其封装至reference结构体中：
```
func RunPush(dockerCli command.Cli, opts pushOptions) error {
	ref, err := reference.ParseNormalizedNamed(opts.remote)
	...
}
```
其中reference的定义以及继承关系如下，可以看到通过ref的封装，可以得到image的name/tag/repo/registry：
```
type reference struct {
	namedRepository
	tag    string
	digest digest.Digest
}

type namedRepository interface {
	Named
	Domain() string
	Path() string
}

type Named interface {
	Reference
	Name() string
}

type Reference interface {
	// String returns the full reference
	String() string
}
```

之后，和docker pull不同的是，RunPush将根据封装的ref，得到一个repoInfo的信息，调用的函数为`repoInfo, err := registry.ParseRepositoryInfo(ref)`.这段代码的最主要作用是解析ref中描述的registry，并将其信息(是否为官方、https/http)封装到refoInfo。其中repoInfo的定义如下所示：

```
type RepositoryInfo struct {
	Name reference.Named //ref
	
	Index *registrytypes.IndexInfo //registry仓库的信息
	
	Official bool //是否为官方镜像
	// Class represents the class of the repository, such as "plugin"
	// or "image".
	Class string
}

type IndexInfo struct {
	// Name is the name of the registry, such as "docker.io"
	Name string
	// Mirrors is a list of mirrors, expressed as URIs
	Mirrors []string //仓库镜像，在daemon.json中配置
	// Secure is set to false if the registry is part of the list of
	// insecure registries. Insecure registries accept HTTP and/or accept
	// HTTPS with certificates from unknown CAs.
	Secure bool //这个registry是否在doemon.json中的in-security中
	// Official indicates whether this is an official registry
	Official bool 
}
```

下一步，就需要获取认证相关的信息了。docker的config.json中以k-v形式对认证信息进行了保存，其中key就是registry域名。因此，根据repoInfo的Index，解析认证信息，具体实现函数为：
```
func ResolveAuthConfig(ctx context.Context, cli Cli, index *registrytypes.IndexInfo) types.AuthConfig {
	configKey := index.Name
	if index.Official {
		configKey = ElectAuthServer(ctx, cli)
	}

	a, _ := cli.ConfigFile().GetAuthConfig(configKey)
	return types.AuthConfig(a)
}
```
最后，在真正调用push函数前，首先创建一个`RegistryAuthenticationPrivilegedFunc`。 那么这个函数的作用是什么呢？先继续往下看，调用`responseBody, err := imagePushPrivileged(ctx, dockerCli, authConfig, ref, requestPrivilege)`,这是push的主函数，而刚才那个func作为参数requestPrivilege也一并传入。函数内部其实只做了一层封装，继续调用cli.Client().ImagePush：
```
	encodedAuth, err := command.EncodeAuthToBase64(authConfig)
	if err != nil {
		return nil, err
	}
	options := types.ImagePushOptions{
		RegistryAuth:  encodedAuth,
		PrivilegeFunc: requestPrivilege,
	}

	return cli.Client().ImagePush(ctx, reference.FamiliarString(ref), options)
```
ImagePush的实现如下,大致分为两步，第一步为构造请求参数，第二步为发送请求：
```
func (cli *Client) ImagePush(ctx context.Context, image string, options types.ImagePushOptions) (io.ReadCloser, error) {
	ref, err := reference.ParseNormalizedNamed(image)
	if err != nil {
		return nil, err
	}

	if _, isCanonical := ref.(reference.Canonical); isCanonical {
		return nil, errors.New("cannot push a digest reference")
	}

	tag := ""
	name := reference.FamiliarName(ref)

	if nameTaggedRef, isNamedTagged := ref.(reference.NamedTagged); isNamedTagged {
		tag = nameTaggedRef.Tag()
	}

	query := url.Values{}
	query.Set("tag", tag)

	resp, err := cli.tryImagePush(ctx, name, query, options.RegistryAuth)
	//重点在这里，注意PrivilegeFunc的调用时机
	if errdefs.IsUnauthorized(err) && options.PrivilegeFunc != nil {
		newAuthHeader, privilegeErr := options.PrivilegeFunc()
		if privilegeErr != nil {
			return nil, privilegeErr
		}
		resp, err = cli.tryImagePush(ctx, name, query, newAuthHeader)
	}
	if err != nil {
		return nil, err
	}
	return resp.body, nil
}
```
当进行tryImagePush时，出现未授权的err时，则调用之前创建的函数变量PrivilegeFunc。因此猜测这个函数的作用为授权操作，具体的场景为：虽然通过config.json得到了auth信息，但是，这个auth信息所包含的用户并不能够将image push到这个repo上，因此需要用授权的另一个账户登录，从而拿新的auth信息来操作。

因此，回过头看下`RegistryAuthenticationPrivilegedFunc`完成的工作，猜想得到验证：
```
func RegistryAuthenticationPrivilegedFunc(cli Cli, index *registrytypes.IndexInfo, cmdName string) types.RequestPrivilegeFunc {
	return func() (string, error) {
		//提示login
		fmt.Fprintf(cli.Out(), "\nPlease login prior to %s:\n", cmdName)
		indexServer := registry.GetAuthConfigKey(index)
		//判断是否为默认registry
		isDefaultRegistry := indexServer == ElectAuthServer(context.Background(), cli)
		authConfig, err := GetDefaultAuthConfig(cli, true, indexServer, isDefaultRegistry)
		if err != nil {
			fmt.Fprintf(cli.Err(), "Unable to retrieve stored credentials for %s, error: %s.\n", indexServer, err)
		}
		//新的accpunt/pwd信息
		err = ConfigureAuth(cli, "", "", authConfig, isDefaultRegistry)
		if err != nil {
			return "", err
		}
		return EncodeAuthToBase64(*authConfig)
	}
}
```

### docker daemon

## tag image
