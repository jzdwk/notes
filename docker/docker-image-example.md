# httpbin
```json
{
  "architecture": "amd64",
  "config": {
    "Hostname": "",
    "Domainname": "",
    "User": "",
    "AttachStdin": false,
    "AttachStdout": false,
    "AttachStderr": false,
    "ExposedPorts": {
      "80/tcp": {}
    },
    "Tty": false,
    "OpenStdin": false,
    "StdinOnce": false,
    "Env": [
      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ],
    "Cmd": [
      "gunicorn",
      "-b",
      "0.0.0.0:80",
      "httpbin:app",
      "-k",
      "gevent"
    ],
    "ArgsEscaped": true,
    "Image": "sha256:e25b0979f9c82a4c73c810467514e1d5cdd3b1bb28bb26be88f8323039544fe8",
    "Volumes": null,
    "WorkingDir": "",
    "Entrypoint": null,
    "OnBuild": null,
    "Labels": {
      "description": "A simple HTTP service.",
      "name": "httpbin",
      "org.kennethreitz.vendor": "Kenneth Reitz",
      "version": "0.9.2"
    }
  },
  "container": "9bdbba8b79ee0fc70ff98e11e33fba34ab190922ad397a24f81dce099d15ff53",
  "container_config": {
    "Hostname": "9bdbba8b79ee",
    "Domainname": "",
    "User": "",
    "AttachStdin": false,
    "AttachStdout": false,
    "AttachStderr": false,
    "ExposedPorts": {
      "80/tcp": {}
    },
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
      "CMD [\"gunicorn\" \"-b\" \"0.0.0.0:80\" \"httpbin:app\" \"-k\" \"gevent\"]"
    ],
    "ArgsEscaped": true,
    "Image": "sha256:e25b0979f9c82a4c73c810467514e1d5cdd3b1bb28bb26be88f8323039544fe8",
    "Volumes": null,
    "WorkingDir": "",
    "Entrypoint": null,
    "OnBuild": null,
    "Labels": {
      "description": "A simple HTTP service.",
      "name": "httpbin",
      "org.kennethreitz.vendor": "Kenneth Reitz",
      "version": "0.9.2"
    }
  },
  "created": "2018-10-24T07:01:15.543000632Z",
  "docker_version": "18.03.1-ee-3",
  "history": [
    {
      "created": "2018-10-19T00:47:54.68590759Z",
      "created_by": "/bin/sh -c #(nop) ADD file:bcd068f67af2788dbd57729c0c8193f022ec5c37fefb8704390c59081152e6fc in / "
    },
    {
      "created": "2018-10-19T00:47:55.423310694Z",
      "created_by": "/bin/sh -c set -xe \t\t&& echo '#!/bin/sh' > /usr/sbin/policy-rc.d \t&& echo 'exit 101' >> /usr/sbin/policy-rc.d \t&& chmod +x /usr/sbin/policy-rc.d \t\t&& dpkg-divert --local --rename --add /sbin/initctl \t&& cp -a /usr/sbin/policy-rc.d /sbin/initctl \t&& sed -i 's/^exit.*/exit 0/' /sbin/initctl \t\t&& echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/docker-apt-speedup \t\t&& echo 'DPkg::Post-Invoke { \"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true\"; };' > /etc/apt/apt.conf.d/docker-clean \t&& echo 'APT::Update::Post-Invoke { \"rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb /var/cache/apt/*.bin || true\"; };' >> /etc/apt/apt.conf.d/docker-clean \t&& echo 'Dir::Cache::pkgcache \"\"; Dir::Cache::srcpkgcache \"\";' >> /etc/apt/apt.conf.d/docker-clean \t\t&& echo 'Acquire::Languages \"none\";' > /etc/apt/apt.conf.d/docker-no-languages \t\t&& echo 'Acquire::GzipIndexes \"true\"; Acquire::CompressionTypes::Order:: \"gz\";' > /etc/apt/apt.conf.d/docker-gzip-indexes \t\t&& echo 'Apt::AutoRemove::SuggestsImportant \"false\";' > /etc/apt/apt.conf.d/docker-autoremove-suggests"
    },
    {
      "created": "2018-10-19T00:47:56.094954537Z",
      "created_by": "/bin/sh -c rm -rf /var/lib/apt/lists/*"
    },
    {
      "created": "2018-10-19T00:47:56.775696561Z",
      "created_by": "/bin/sh -c mkdir -p /run/systemd && echo 'docker' > /run/systemd/container"
    },
    {
      "created": "2018-10-19T00:47:56.963343052Z",
      "created_by": "/bin/sh -c #(nop)  CMD [\"/bin/bash\"]",
      "empty_layer": true
    },
    {
      "created": "2018-10-24T06:57:03.838111649Z",
      "created_by": "/bin/sh -c #(nop)  LABEL name=httpbin",
      "empty_layer": true
    },
    {
      "created": "2018-10-24T06:57:04.156990538Z",
      "created_by": "/bin/sh -c #(nop)  LABEL version=0.9.2",
      "empty_layer": true
    },
    {
      "created": "2018-10-24T06:57:04.550879957Z",
      "created_by": "/bin/sh -c #(nop)  LABEL description=A simple HTTP service.",
      "empty_layer": true
    },
    {
      "created": "2018-10-24T06:57:04.930698469Z",
      "created_by": "/bin/sh -c #(nop)  LABEL org.kennethreitz.vendor=Kenneth Reitz",
      "empty_layer": true
    },
    {
      "created": "2018-10-24T07:00:29.587762361Z",
      "created_by": "/bin/sh -c apt update -y && apt install python3-pip -y"
    },
    {
      "created": "2018-10-24T07:00:30.993348878Z",
      "created_by": "/bin/sh -c #(nop)  EXPOSE 80",
      "empty_layer": true
    },
    {
      "created": "2018-10-24T07:00:31.49021665Z",
      "created_by": "/bin/sh -c #(nop) ADD dir:e515819df42cabc7f8fe307e9eff2af3fe449fe6e2408e3242949c32d3326564 in /httpbin "
    },
    {
      "created": "2018-10-24T07:01:15.102018078Z",
      "created_by": "/bin/sh -c pip3 install --no-cache-dir gunicorn /httpbin"
    },
    {
      "created": "2018-10-24T07:01:15.543000632Z",
      "created_by": "/bin/sh -c #(nop)  CMD [\"gunicorn\" \"-b\" \"0.0.0.0:80\" \"httpbin:app\" \"-k\" \"gevent\"]",
      "empty_layer": true
    }
  ],
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:102645f1cf722254bbfb7135b524db45fbbac400e79e4d54266c000a5f5bc400",
      "sha256:ae1f631f14b7667ca37dca207c631d64947c60d923995cf0d73ceb1b08c406bb",
      "sha256:2146d867acf390370d4d0c7b51951551e0e91fb600b69dbc8922d531b05b12bc",
      "sha256:76c033092e100f56899d7402823c5cb6ce345442b3382d7b240350ef4252187e",
      "sha256:e29f63869784e4e80a8d33f0589cc9da27f21f2f51c0058cd4ce6cd6879ed405",
      "sha256:4985a8f7528375e7dd163af52d94fb0295dd5c1151ba8157ad04b6920bb92590",
      "sha256:056d85f190d9a6abaf02b536d1ac921e29beea9300a56bf34bc4df21da7df79d"
    ]
  }
}
```