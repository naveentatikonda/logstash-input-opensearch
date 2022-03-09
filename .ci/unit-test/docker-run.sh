#!/bin/bash

# This is intended to be run inside the docker container as the command of the docker-compose.
set -ex

cd .ci/unit-test

docker-compose up --exit-code-from logstash
