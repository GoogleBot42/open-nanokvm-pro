#!/usr/bin/env bash
openssl s_client -connect 127.0.0.1:8471 -servername 127.0.0.1 </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
