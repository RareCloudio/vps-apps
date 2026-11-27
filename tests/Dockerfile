FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bats shellcheck jq git ca-certificates curl openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY . /src
WORKDIR /src
CMD ["bash", "-c", "bats tests/ && scripts/lint.sh"]
