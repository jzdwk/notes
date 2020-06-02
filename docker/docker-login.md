# docker login

docker的login过程可以参照docker官方的[认证文档](https://docs.docker.com/registry/spec/auth/token/)
对于docker login来说，整体的流程为：

1. docker client接收到用户输入的 docker login 命令，通过调用registry服务中的auth方法,registry在loginV2方法中对请求进行认证
2. 此时的请求中并没有包含token信息，认证会失败，返回401错误，同时在header中返回去哪里请求authZ server地址
3. registry client端收到上面的返回结果后，便会去返回的authZ server那里进行认证请求，向认证服务器发送的请求的header 中包含有加密的用户名和密码
4. authZ server从header中获取到加密的用户名和密码，结合实际的认证系统进行认证，比如从数据库中查询用户认证信息或者对接 ldap服务进行认证校验
5. 认证成功后，会返回一个token信息，即`IdentityToken`
6. client端会拿着返回的token再次向registry 服务发送请求，这次需要带上得到的token，请求验证成功，返回状态码就是200了

最终，docker client端接收到返回的200状态码，说明操作成功，在控制台上打印Login Succeeded的信息

## client
docker login在client端的命令行实现位于`docker/cli/cli/commands/commands.go`，其位置和docker的其他命令相同，和registry相关的是3个命令:
```
...
// registry
registry.New(dockerCli),
registry.NewLogoutCommand(dockerCli),
registry.NewSearchCommand(dockerCli),
...
```
继续进入`LoginCommand`，其具体实现位于函数`runLogin`：
```
func runLogin(dockerCli command.Cli, opts loginOptions) error { //nolint: gocyclo
	...
	//默认registry处理，如果带私有registry addr，则serverAddr指定，否则docker.io
	if opts.serverAddress != "" && opts.serverAddress != registry.DefaultNamespace {
		serverAddress = opts.serverAddress
	} else {
		serverAddress = authServer
	}
	//如果直接使用命令docker login，则获取默认serverAddr的对应的认证信息
	isDefaultRegistry := serverAddress == authServer
	authConfig, err = command.GetDefaultAuthConfig(dockerCli, opts.user == "" && opts.password == "", serverAddress, isDefaultRegistry)
	if err == nil && authConfig.Username != "" && authConfig.Password != "" {
		response, err = loginWithCredStoreCreds(ctx, dockerCli, authConfig)
	}
	//如果没有登录的记录，则从stdin获取，并发送认证请求
	if err != nil || authConfig.Username == "" || authConfig.Password == "" {
		err = command.ConfigureAuth(dockerCli, opts.user, opts.password, authConfig, isDefaultRegistry)
		...
		response, err = clnt.RegistryLogin(ctx, *authConfig)
		...
	}
	...
	//返回信息处理
}
```

上述逻辑从docker login的参数中读取registry addr以及登录信息，并封装为authConfig结构，这个结构包含了授权所需的信息：

```
type AuthConfig struct {
	Username string
	Password string 
	Auth     string 
	Email string 
	ServerAddress string 
	IdentityToken string //IdentityToken由authZ server返回，使用IdentityToken向registry请求
	RegistryToken string //authZ Server返回的token，用于向registry发送
}
```

如果docker login没有写参数，则根据默认条件设置，然后调用`RegistryLogin`发送login请求。可以看到这个请求：
```
func (cli *Client) RegistryLogin(ctx context.Context, auth types.AuthConfig) (registry.AuthenticateOKBody, error) {
	resp, err := cli.post(ctx, "/auth", url.Values{}, auth, nil)
	...
	//如果认证失败，返回
}
```

注意，这个请求是**发给了daemon端**，后续的逻辑由daemon实现。此时的authConfig只包含了简单的registryAddr/usr/pwd。

## daemon

daemon的auth api位于`engine/api/server/router/system/system.go`中的postAuth函数`router.NewPostRoute("/auth", r.postAuth)`,该函数的认证逻辑最终由backend的RegistryService的Auth函数完成，进入实现部分,具体关注authConfig：

```
func (s *DefaultService) Auth(ctx context.Context, authConfig *types.AuthConfig, userAgent string) (status, token string, err error) {
	//解析authConfig的registry地址
	...
	endpoints, err := s.LookupPushEndpoints(u.Host)
	...
	for _, endpoint := range endpoints {
		//loginV2是一个函数变量 表示使用v2版认证逻辑
		login := loginV2
		if endpoint.Version == APIVersion1 {
			login = loginV1
		}
		//实际认证
		status, token, err = login(authConfig, endpoint, userAgent)
		....
		return "", "", err
	}
	return "", "", err
}
```

上述代码首先根据authConfig得到registry的地址，然后根据版本信息调用认证逻辑(现版本为v2)，继续进入loginv2的实现：

```
func loginV2(authConfig *types.AuthConfig, endpoint APIEndpoint, userAgent string) (string, string, error) {
	//将认证信息进行封装
	modifiers := Headers(userAgent, nil)
	authTransport := transport.NewTransport(NewTransport(endpoint.TLSConfig), modifiers...)
	credentialAuthConfig := *authConfig
	creds := loginCredentialStore{
		authConfig: &credentialAuthConfig,
	}
	//重要，得到封装的登录client，后续会使用这个client向authZ server发送请求
	loginClient, foundV2, err := v2AuthHTTPClient(endpoint.URL, authTransport, modifiers, creds, nil)
	...
	endpointStr := strings.TrimRight(endpoint.URL.String(), "/") + "/v2/"
	req, err := http.NewRequest(http.MethodGet, endpointStr, nil)
	...
	//向authZ server发送授权请求
	resp, err := loginClient.Do(req)
	...
	//说明授权成功，返回authZ server生成的token
	if resp.StatusCode == http.StatusOK {
		return "Login Succeeded", credentialAuthConfig.IdentityToken, nil
	}
	...
	return "", "", err
}
```

上述代码主要做了两件事，一是调用`v2AuthHTTPClient`封装一个loginClient，二是使用这个client向**authZ server** 发送授权请求，即**步骤3**。此处，向**authZ server**请求，就要知道其地址。进入v2AuthHTTPClient：
```
func v2AuthHTTPClient(endpoint *url.URL, authTransport http.RoundTripper, modifiers []transport.RequestModifier, creds auth.CredentialStore, scopes []auth.Scope) (*http.Client, bool, error) {
	challengeManager, foundV2, err := PingV2Registry(endpoint, authTransport)
	...
	tokenHandlerOptions := auth.TokenHandlerOptions{
		Transport:     authTransport,
		Credentials:   creds,
		OfflineAccess: true,
		ClientID:      AuthClientID,
		Scopes:        scopes,
	}
	tokenHandler := auth.NewTokenHandlerWithOptions(tokenHandlerOptions)
	basicHandler := auth.NewBasicHandler(creds)
	modifiers = append(modifiers, auth.NewAuthorizer(challengeManager, tokenHandler, basicHandler))
	tr := transport.NewTransport(authTransport, modifiers...)
	return &http.Client{
		Transport: tr,
		Timeout:   15 * time.Second,
	}, foundV2, nil
}
```

可以看到上述代码调用了`PingV2Registry`生成一个`challengeManager`对象，并封装到标准的http.Client，这个`challengeManager`实现了接口Manager，

```
type Manager interface {
	// GetChallenges returns the challenges for the given
	// endpoint URL.
	GetChallenges(endpoint url.URL) ([]Challenge, error)

	// AddResponse adds the response to the challenge
	// manager. The challenges will be parsed out of
	// the WWW-Authenicate headers and added to the
	// URL which was produced the response. If the
	// response was authorized, any challenges for the
	// endpoint will be cleared.
	AddResponse(resp *http.Response) error
}
```

这个接口主要声明了两个方法，注意AddResponse，此方法向http的resp中添加`WWW-Authenicate`header，这个header项便是返回的**authZ server**的地址。因此我们猜测，`PingV2Registry`的逻辑实现了**步骤1、2**：

```
func PingV2Registry(endpoint *url.URL, transport http.RoundTripper) (challenge.Manager, bool, error) {
	var (
		foundV2   = false
		v2Version = auth.APIVersion{
			Type:    "registry",
			Version: "2.0",
		}
	)

	pingClient := &http.Client{
		Transport: transport,
		Timeout:   15 * time.Second,
	}
	endpointStr := strings.TrimRight(endpoint.String(), "/") + "/v2/"
	//向registry发送v2请求
	req, err := http.NewRequest(http.MethodGet, endpointStr, nil)
	...
	resp, err := pingClient.Do(req)
	...
	defer resp.Body.Close()
	//版本检查
	...
	//challengeManager封装
	challengeManager := challenge.NewSimpleManager()
	if err := challengeManager.AddResponse(resp); err != nil {
		return nil, foundV2, PingResponseError{
			Err: err,
		}
	}
	return challengeManager, foundV2, nil
}
```

上述代码向registry发送了一个简单的get请求，主要关注resp的处理，此段逻辑位于`AddResponse`内的`ResponseChallenges`:

```
func ResponseChallenges(resp *http.Response) []Challenge {
	if resp.StatusCode == http.StatusUnauthorized {
		//registry 返回410时，处理header
		return parseAuthHeader(resp.Header)
	}
	return nil
}
//解析WWW-Authenticate的header，即authZ server的地址
func parseAuthHeader(header http.Header) []Challenge {
	challenges := []Challenge{}
	for _, h := range header[http.CanonicalHeaderKey("WWW-Authenticate")] {
		v, p := parseValueAndParams(h)
		if v != "" {
			challenges = append(challenges, Challenge{Scheme: v, Parameters: p})
		}
	}
	return challenges
}
```

至此，便验证了**步骤2**。回到函数`v2AuthHTTPClient`，如果授权成功，该函数返回了authZ server生成的**IdentityToken**，即步骤**5**。函数逐一返回，最终直daemon的route定义函数`postAuth`：
```
func (s *systemRouter) postAuth(ctx context.Context, w http.ResponseWriter, r *http.Request, vars map[string]string) error {
	...
	status, token, err := s.backend.AuthenticateToRegistry(ctx, config)
	...
	return httputils.WriteJSON(w, http.StatusOK, &registry.AuthenticateOKBody{
		Status:        status,
		IdentityToken: token,
	})
}
```

再次回到docker client端的runLogin函数，看到当auth请求返回，且IdentityToken不为空，则对token进行保存。

```
func runLogin(dockerCli command.Cli, opts loginOptions) error { //nolint: gocyclo
	...
	if response.IdentityToken != "" {
		authConfig.Password = ""
		authConfig.IdentityToken = response.IdentityToken
	}
	creds := dockerCli.ConfigFile().GetCredentialsStore(serverAddress)
	store, isDefault := creds.(isFileStore)
	...
	if err := creds.Store(configtypes.AuthConfig(*authConfig)); err != nil {
		return errors.Errorf("Error saving credentials: %v", err)
	}
	...
}
```





