# docker image push

��¼docker image push��ʵ�ֹ���

## docker client

push image��pull image��client�˵Ĵ���ṹ���ƣ���λ��`docker/cli/cli/command/image/push.go`�е�NewPushCommand������
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
���Կ���һ��cobra��docker push����壬��pushһ�����صľ�����myharbor.com/test1/image1:1.0ʱ�����ֵ��Ϊopts.remote����RunPush������RunPush�������������ľ��ǽ���myharbor.com/test1/image1:1.0�������װ��reference�ṹ���У�
```
func RunPush(dockerCli command.Cli, opts pushOptions) error {
	ref, err := reference.ParseNormalizedNamed(opts.remote)
	...
}
```
����reference�Ķ����Լ��̳й�ϵ���£����Կ���ͨ��ref�ķ�װ�����Եõ�image��name/tag/repo/registry��
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

֮�󣬺�docker pull��ͬ���ǣ�RunPush�����ݷ�װ��ref���õ�һ��repoInfo����Ϣ�����õĺ���Ϊ`repoInfo, err := registry.ParseRepositoryInfo(ref)`.��δ��������Ҫ�����ǽ���ref��������registry����������Ϣ(�Ƿ�Ϊ�ٷ���https/http)��װ��refoInfo������repoInfo�Ķ���������ʾ��

```
type RepositoryInfo struct {
	Name reference.Named //ref
	
	Index *registrytypes.IndexInfo //registry�ֿ����Ϣ
	
	Official bool //�Ƿ�Ϊ�ٷ�����
	// Class represents the class of the repository, such as "plugin"
	// or "image".
	Class string
}

type IndexInfo struct {
	// Name is the name of the registry, such as "docker.io"
	Name string
	// Mirrors is a list of mirrors, expressed as URIs
	Mirrors []string //�ֿ⾵����daemon.json������
	// Secure is set to false if the registry is part of the list of
	// insecure registries. Insecure registries accept HTTP and/or accept
	// HTTPS with certificates from unknown CAs.
	Secure bool //���registry�Ƿ���doemon.json�е�in-security��
	// Official indicates whether this is an official registry
	Official bool 
}
```

��һ��������Ҫ��ȡ��֤��ص���Ϣ�ˡ�docker��config.json����k-v��ʽ����֤��Ϣ�����˱��棬����key����registry��������ˣ�����repoInfo��Index��������֤��Ϣ������ʵ�ֺ���Ϊ��
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
�������������push����ǰ�����ȴ���һ��`RegistryAuthenticationPrivilegedFunc`�� ��ô���������������ʲô�أ��ȼ������¿�������`responseBody, err := imagePushPrivileged(ctx, dockerCli, authConfig, ref, requestPrivilege)`,����push�������������ղ��Ǹ�func��Ϊ����requestPrivilegeҲһ�����롣�����ڲ���ʵֻ����һ���װ����������cli.Client().ImagePush��
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
ImagePush��ʵ������,���·�Ϊ��������һ��Ϊ��������������ڶ���Ϊ��������
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
	//�ص������ע��PrivilegeFunc�ĵ���ʱ��
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
������tryImagePushʱ������δ��Ȩ��errʱ�������֮ǰ�����ĺ�������PrivilegeFunc����˲²��������������Ϊ��Ȩ����������ĳ���Ϊ����Ȼͨ��config.json�õ���auth��Ϣ�����ǣ����auth��Ϣ���������û������ܹ���image push�����repo�ϣ������Ҫ����Ȩ����һ���˻���¼���Ӷ����µ�auth��Ϣ��������

��ˣ��ع�ͷ����`RegistryAuthenticationPrivilegedFunc`��ɵĹ���������õ���֤��
```
func RegistryAuthenticationPrivilegedFunc(cli Cli, index *registrytypes.IndexInfo, cmdName string) types.RequestPrivilegeFunc {
	return func() (string, error) {
		//��ʾlogin
		fmt.Fprintf(cli.Out(), "\nPlease login prior to %s:\n", cmdName)
		indexServer := registry.GetAuthConfigKey(index)
		//�ж��Ƿ�ΪĬ��registry
		isDefaultRegistry := indexServer == ElectAuthServer(context.Background(), cli)
		authConfig, err := GetDefaultAuthConfig(cli, true, indexServer, isDefaultRegistry)
		if err != nil {
			fmt.Fprintf(cli.Err(), "Unable to retrieve stored credentials for %s, error: %s.\n", indexServer, err)
		}
		//�µ�accpunt/pwd��Ϣ
		err = ConfigureAuth(cli, "", "", authConfig, isDefaultRegistry)
		if err != nil {
			return "", err
		}
		return EncodeAuthToBase64(*authConfig)
	}
}
```

## docker daemon

��docker pullһ����docker push��apiλ��/engine/api/server/router/image/image.go�С������·��Ϊ��`router.NewPostRoute("/images/{name:.*}/push", r.postImagesPush),`�� �ع�docker push����:
```
Usage:  docker push [OPTIONS] NAME[:TAG]

Push an image or a repository to a registry

Options:
      --disable-content-trust   Skip image signing (default true)
```
push��ָ��Ҫ�ϴ������repo/image/tag����˲²⣬�������Ϊ��
 
1. ����repo/image:tag����repositories.json�л�ȡimage��digest

2. �������image digest����imagedb��content�еõ������layer������Ϣ

3. ����layer��Ϣ����layerdb�еõ������layer�ļ�����layer�ļ��ϴ�

4. �����ϴ���layer����manifest�ļ�����ǩ�����ϴ�

�������`postImagesPush`������ʵ�����£�
```
func (s *imageRouter) postImagesPush(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	//����auth��Ϣ�Ĵ��������auth��Ϣ����ȡ�����base64
	...
	authConfig := &types.AuthConfig{}
	authEncoded := r.Header.Get("X-Registry-Auth")
	if authEncoded != "" {
		// the new format is to handle the authConfig as a header
		authJSON := base64.NewDecoder(base64.URLEncoding, strings.NewReader(authEncoded))
		...
	} else {
		...
		//�ϰ汾��body�л�ȡ
	}
	//����image��Ϣ
	image := vars["name"]
	tag := r.Form.Get("tag")
	output := ioutils.NewWriteFlusher(w)
	...
	w.Header().Set("Content-Type", "application/json")
	//backend��pushʵ��
	if err := s.backend.PushImage(ctx, image, tag, metaHeaders, authConfig, output); err != nil {
		...
	}
	return nil
}
```

����ĺ���ֻ���˲��������Ĺ�����һ�ǽ�����auth��Ϣ������image��Ϣ��Ȼ���ֱ�ӵ�����backend��PushImage������
```
func (i *ImageService) PushImage(ctx context.Context, image, tag string, metaHeaders map[string][]string, authConfig *types.AuthConfig, outStream io.Writer) error {
	start := time.Now()
	//��image��Ϣ��װΪreference
	ref, err := reference.ParseNormalizedNamed(image)
	...
	if tag != "" {
		ref, err = reference.WithTag(ref, tag)
		...
	}
	//�����������push������Ϣ��chan�Լ���־�������޻���chan
	progressChan := make(chan progress.Progress, 100)
	writesDone := make(chan struct{})
	ctx, cancelFunc := context.WithCancel(ctx)
	//��һ��routine ��progressChan�ж�ȡ��Ϣ��д��stdout
	go func() {
		progressutils.WriteDistributionProgress(cancelFunc, outStream, progressChan)
		close(writesDone)
	}()
	//����image push config
	imagePushConfig := &distribution.ImagePushConfig{
		Config: distribution.Config{ //����image��Ϣ
			MetaHeaders:      metaHeaders,
			AuthConfig:       authConfig,
			ProgressOutput:   progress.ChanOutput(progressChan),
			RegistryService:  i.registryService,
			ImageEventLogger: i.LogImageEvent,
			MetadataStore:    i.distributionMetadataStore,
			ImageStore:       distribution.NewImageConfigStoreFromStore(i.imageStore),
			ReferenceStore:   i.referenceStore,
		},
		ConfigMediaType: schema2.MediaTypeImageConfig,//image�汾����
		LayerStores:     distribution.NewLayerProvidersFromStores(i.layerStores), //����layer�Ĵ洢ʵ��
		TrustKey:        i.trustKey,
 		UploadManager:   i.uploadManager, //�����������ϴ�ʵ����ص�
	}
	//����distribution��push
	err = distribution.Push(ctx, ref, imagePushConfig)
	close(progressChan)
	//�ȴ�done����
	<-writesDone
	imageActions.WithValues("push").UpdateSince(start)
	return err
}
```
�����������Ҳֻ���������£�һ�Ƕ���һ��progressChan���ڽ���push����Ϣ����ӡ�����Ƿ�װ��һ��imagePushConfig�Ľṹ�塣����ṹ���У����˻�����image��Ϣ��Ҳ������mediaType����image�ĸ�ʽ�汾(����pull)������os����layerStore�Ķ��󡣼�������`err = distribution.Push(ctx, ref, imagePushConfig)`,�Ӱ�����distribution�������뵽���������image�洢ʱ��distribution��ء�

