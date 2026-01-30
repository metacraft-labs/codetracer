
### Setup

### Set up the container options


* Eventually we needed to set up the lxd container as privileged to make it possible to run the `aufs` driver for docker
* Also it seems we need to do this https://stackoverflow.com/questions/46645910/docker-rootfs-linux-go-permission-denied-when-mounting-proc/46648124#46648124 to be able to change system limits for rr and codetracer

### Install docker

* Install docker from their apt repository:
  * Running commands from https://docs.docker.com/engine/install/ubuntu/ -> https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository

We use those commands:

```bash
sudo apt-get remove docker docker-engine docker.io containerd runc

sudo apt-get update

sudo apt-get install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update

sudo apt-get install -y docker-ce docker-ce-cli containerd.io # original command doesn't pass -y: sudo apt-get install -y docker-ce docker-ce-cli containerd.io
```

### Install `gitlab-runner`

* Install gitlab-runner from their apt repository:
  * Running commands from https://docs.gitlab.com/runner/install/linux-repository.html#installing-gitlab-runner

```bash
# needs sudo!
curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | sudo bash

sudo apt-get install -y gitlab-runner # original command doesn't pass -y : sudo apt-get install gitlab-runner
```

### Build `codetracer_base` docker image

* Copy `build` folder from a codetracer repo to the server:

```bash
scp -r build codetracer-hetzner:/home/codetracer/build
```

* `codetracer-hetzner` is in my ssh config file as a host section: you might need to replace it
* `rsync` might be a faster way to copy files, but `build` is a small folder. TODO: do we need to document usage of rsync?

* Make the image

```bash
sudo docker build -t codetracer_base .
```

### Configure linux limits/settings for rr/codetracer

* Enough file watches

```bash
echo fs.inotify.max_user_watches=700000 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p;
```

* Enable `perf_event_paranoid=1`

```bash
echo kernel.perf_event_paranoid=1 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p
```

### Configure `gitlab-runner`: copy `config.toml`

* Copy `config.toml` file from a codetracer repo to the server:

Locally:

```bash
scp config.toml codetracer-hetzner:/home/codetracer/config.toml
```

On server:
```bash
sudo cp /home/codetracer/config.toml /etc/gitlab-runner/config.toml
```

* `codetracer-hetzner` is in my ssh config file as a host section: you might need to replace it (see notes for building codetracer_base docker image: copying `build`)

* You can also use `gitlab-runner register` to dynamically fill such a section

* You might need to change docker volumes in config.toml

## Configuring GitLab runners: in the GitLab runners web interface and command line/config.toml

* You might need to get new or custom runner token from our/your gitlab repo's runner web interface:
  * Visit your repo's web interface
  * `Settings` > `CI/CD` > `Runners` > `Specific Runners`
  * It seems the url for our repo might be <https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/runners#js-runners-settings> or
      <https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/settings/ci_cd>
* Use the token and run on the server

```bash
export GITLAB_RUNNER_TOKEN=<insert token>

sudo gitlab-runner register \
  --non-interactive \
  --url https://gitlab.com \
  --registration-token $GITLAB_RUNNER_TOKEN \
  --executor docker \
  --docker-image codetracer_base:latest \
  --paused
# maybe remove the token or just use it directly in the command
```

* Copy the new added by gitlab token from /etc/gitlab-runner/config.toml and replace it in our copy from the repo's config.toml
* Copy this fixed version of the repo config.toml to /etc/gitlab-runner/config.toml
* Run `sudo gitlab-runner restart` (not sure if always required)
* Check for a new runner in the gitlab runners interface
* Make sure the setting for the runner's flag `Can run untagged jobs` is `Yes` in the gitlab runners interface
* Unpause the runner

(This GitLab token setup workflow was based on https://stackoverflow.com/questions/54658359/how-do-i-register-reregister-a-gitlab-runner-using-a-pre-made-config-toml)

* If other changes were needed in the repo config.toml file, change it and commit it

* To test: push a commit to the gitlab repo or start a job manually from gitlab web interface

### Notes

I use `fish`, so I install it with `sudo apt install fish`. Keep in mind some of those comm ands use syntax that requires `bash`.
